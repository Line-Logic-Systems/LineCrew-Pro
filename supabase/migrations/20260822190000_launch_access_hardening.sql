begin;

-- These columns already exist in Production. Keeping the declarations here
-- makes the hardening migration self-contained for older Test environments.
alter table public.companies
  add column if not exists subscription_status text not null default 'trial',
  add column if not exists subscription_expires_at timestamptz;

alter table public.companies drop constraint if exists companies_subscription_status_supported;
alter table public.companies add constraint companies_subscription_status_supported
  check (subscription_status in ('trial','active','internal','past_due','suspended','cancelled'));

-- Keep the roster usable for Foremen assigning/borrowing crew members, while
-- limiting payroll-hour visibility to their own crew and their own entries.
drop policy if exists timekeeping_employees_select_company on public.timekeeping_employees;
create policy timekeeping_employees_select_company
on public.timekeeping_employees for select
to authenticated
using (
  timekeeping_employees.company_id = (select p.company_id from public.profiles p where p.id = auth.uid())
  and (
    lower(coalesce((select p.role from public.profiles p where p.id = auth.uid()), '')) in ('gf','admin','owner')
    or (
      lower(coalesce((select p.role from public.profiles p where p.id = auth.uid()), '')) = 'foreman'
      and (
        timekeeping_employees.assigned_foreman_id is null
        or timekeeping_employees.assigned_foreman_id = auth.uid()
        or exists (
          select 1 from public.timekeeping_entries te
          where te.employee_id = timekeeping_employees.id
            and te.company_id = timekeeping_employees.company_id
            and te.created_by = auth.uid()
        )
      )
    )
  )
);

drop policy if exists timekeeping_employees_manage_leaders on public.timekeeping_employees;
create policy timekeeping_employees_manage_leaders
on public.timekeeping_employees for all
to authenticated
using (
  timekeeping_employees.company_id = (select p.company_id from public.profiles p where p.id = auth.uid())
  and lower(coalesce((select p.role from public.profiles p where p.id = auth.uid()), '')) in ('gf','admin','owner')
)
with check (
  timekeeping_employees.company_id = (select p.company_id from public.profiles p where p.id = auth.uid())
  and lower(coalesce((select p.role from public.profiles p where p.id = auth.uid()), '')) in ('gf','admin','owner')
);

drop policy if exists timekeeping_entries_select_company on public.timekeeping_entries;
create policy timekeeping_entries_select_company
on public.timekeeping_entries for select
to authenticated
using (
  timekeeping_entries.company_id = (select p.company_id from public.profiles p where p.id = auth.uid())
  and (
    lower(coalesce((select p.role from public.profiles p where p.id = auth.uid()), '')) in ('gf','admin','owner')
    or (
      lower(coalesce((select p.role from public.profiles p where p.id = auth.uid()), '')) = 'foreman'
      and (
        timekeeping_entries.created_by = auth.uid()
        or exists (
          select 1 from public.timekeeping_employees te
          where te.id = timekeeping_entries.employee_id
            and te.company_id = timekeeping_entries.company_id
            and te.assigned_foreman_id = auth.uid()
        )
      )
    )
  )
);

drop policy if exists timekeeping_entry_history_select_company on public.timekeeping_entry_history;
create policy timekeeping_entry_history_select_company
on public.timekeeping_entry_history for select
to authenticated
using (
  timekeeping_entry_history.company_id = (select p.company_id from public.profiles p where p.id = auth.uid())
  and (
    lower(coalesce((select p.role from public.profiles p where p.id = auth.uid()), '')) in ('gf','admin','owner')
    or (
      lower(coalesce((select p.role from public.profiles p where p.id = auth.uid()), '')) = 'foreman'
      and (
        timekeeping_entry_history.created_by = auth.uid()
        or exists (
          select 1 from public.timekeeping_employees te
          where te.id = timekeeping_entry_history.employee_id
            and te.company_id = timekeeping_entry_history.company_id
            and te.assigned_foreman_id = auth.uid()
        )
      )
    )
  )
);

drop policy if exists timekeeping_entries_update_company on public.timekeeping_entries;
create policy timekeeping_entries_update_company
on public.timekeeping_entries for update
to authenticated
using (
  timekeeping_entries.company_id = (select p.company_id from public.profiles p where p.id = auth.uid())
  and (
    timekeeping_entries.created_by = auth.uid()
    or lower(coalesce((select p.role from public.profiles p where p.id = auth.uid()), '')) in ('gf','admin','owner')
  )
)
with check (
  timekeeping_entries.company_id = (select p.company_id from public.profiles p where p.id = auth.uid())
  and exists (
    select 1 from public.timekeeping_employees e
    where e.id = timekeeping_entries.employee_id
      and e.company_id = timekeeping_entries.company_id
  )
);

drop policy if exists timekeeping_entries_delete_company on public.timekeeping_entries;
create policy timekeeping_entries_delete_company
on public.timekeeping_entries for delete
to authenticated
using (
  timekeeping_entries.company_id = (select p.company_id from public.profiles p where p.id = auth.uid())
  and (
    timekeeping_entries.created_by = auth.uid()
    or lower(coalesce((select p.role from public.profiles p where p.id = auth.uid()), '')) in ('gf','admin','owner')
  )
);

create or replace function public.admin_import_timekeeping_roster(p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_row jsonb;
  v_employee_number text;
  v_full_name text;
  v_classification text;
  v_default_crew text;
  v_existing_id uuid;
  v_inserted integer := 0;
  v_updated integer := 0;
begin
  select p.company_id, lower(coalesce(p.role, '')) into v_company_id, v_role
  from public.profiles p where p.id = auth.uid();

  if v_company_id is null or v_role not in ('admin','owner') then
    raise exception using errcode='42501', message='Only a company Owner or Admin can import the employee roster.';
  end if;
  if jsonb_typeof(p_rows) <> 'array' then
    raise exception using errcode='22023', message='Roster rows must be an array.';
  end if;

  for v_row in select value from jsonb_array_elements(p_rows)
  loop
    v_employee_number := nullif(btrim(coalesce(v_row->>'employee_number','')), '');
    v_full_name := nullif(btrim(coalesce(v_row->>'full_name','')), '');
    v_classification := nullif(btrim(coalesce(v_row->>'classification','')), '');
    v_default_crew := nullif(btrim(coalesce(v_row->>'default_crew_name','')), '');
    if v_full_name is null then continue; end if;

    v_existing_id := null;
    if v_employee_number is not null then
      select e.id into v_existing_id from public.timekeeping_employees e
      where e.company_id = v_company_id
        and lower(coalesce(e.employee_number,'')) = lower(v_employee_number)
      limit 1;
    end if;
    if v_existing_id is null then
      select e.id into v_existing_id from public.timekeeping_employees e
      where e.company_id = v_company_id and lower(e.full_name) = lower(v_full_name)
      limit 1;
    end if;

    if v_existing_id is null then
      insert into public.timekeeping_employees(
        company_id, employee_number, full_name, classification, default_crew_name, active, created_by
      ) values (
        v_company_id, v_employee_number, v_full_name, v_classification, v_default_crew, true, auth.uid()
      );
      v_inserted := v_inserted + 1;
    else
      update public.timekeeping_employees
      set employee_number = coalesce(v_employee_number, employee_number), full_name = v_full_name,
          classification = coalesce(v_classification, classification),
          default_crew_name = coalesce(v_default_crew, default_crew_name), active = true, updated_at = now()
      where id = v_existing_id;
      v_updated := v_updated + 1;
    end if;
  end loop;
  return jsonb_build_object('inserted', v_inserted, 'updated', v_updated);
end;
$$;

revoke all on function public.admin_import_timekeeping_roster(jsonb) from public, anon;
grant execute on function public.admin_import_timekeeping_roster(jsonb) to authenticated;

create or replace function public.timekeeping_report_rows(
  p_from date, p_through date, p_employee uuid default null, p_job uuid default null
)
returns table(
  employee_id uuid, daily_report_id uuid, job_id uuid, work_date date, crew_name text,
  regular_hours numeric, overtime_hours numeric, storm_work boolean, notes text, segment_source text
)
language sql
security definer
set search_path = ''
as $$
  with viewer as (
    select p.id, p.company_id, lower(coalesce(p.role,'')) as role
    from public.profiles p where p.id = auth.uid() and coalesce(p.active,true) is true
  ), all_rows as (
    select e.employee_id,e.daily_report_id,e.job_id,e.work_date,e.crew_name,e.regular_hours,e.overtime_hours,e.storm_work,e.notes,
           'current'::text segment_source,e.company_id,e.created_by
    from public.timekeeping_entries e
    union all
    select h.employee_id,h.daily_report_id,h.job_id,h.work_date,h.crew_name,h.regular_hours,h.overtime_hours,h.storm_work,h.notes,
           'history'::text,h.company_id,h.created_by
    from public.timekeeping_entry_history h
  )
  select r.employee_id,r.daily_report_id,r.job_id,r.work_date,r.crew_name,r.regular_hours,r.overtime_hours,r.storm_work,r.notes,r.segment_source
  from all_rows r
  join viewer v on v.company_id = r.company_id
  where r.work_date between p_from and p_through
    and (p_employee is null or r.employee_id = p_employee)
    and (p_job is null or r.job_id = p_job)
    and (
      v.role in ('gf','admin','owner')
      or (v.role = 'foreman' and (
        r.created_by = v.id
        or exists (
          select 1 from public.timekeeping_employees te
          where te.id = r.employee_id and te.company_id = r.company_id and te.assigned_foreman_id = v.id
        )
      ))
    )
  order by r.work_date desc, r.employee_id;
$$;

revoke all on function public.timekeeping_report_rows(date,date,uuid,uuid) from public, anon;
grant execute on function public.timekeeping_report_rows(date,date,uuid,uuid) to authenticated;

-- Trigger functions should never be directly callable through the API. The
-- existence checks keep this migration safe on environments with older schema
-- histories while still locking every function present in Production.
do $$
declare
  v_signature text;
begin
  foreach v_signature in array array[
    'public.archive_timekeeping_segment_on_report_change()',
    'public.guard_timekeeping_locked_period()',
    'public.sync_daily_report_hours_from_timekeeping()',
    'public.audit_returned_unit_change()'
  ] loop
    if to_regprocedure(v_signature) is not null then
      execute format('revoke all on function %s from public, anon, authenticated', v_signature);
    end if;
  end loop;
end;
$$;

-- Training is available to active paid accounts, valid trials, and the internal tenant.
create or replace function public.current_training_access()
returns table(company_id uuid, role text, subscription_status text, can_train boolean)
language sql stable security definer set search_path = ''
as $$
  select p.company_id, lower(coalesce(p.role,'')), c.subscription_status,
    (coalesce(p.active,true) is true and (
      c.subscription_status = 'internal'
      or (c.subscription_status in ('trial','active')
          and (c.subscription_expires_at is null or c.subscription_expires_at > now()))
    ))
  from public.profiles p
  join public.companies c on c.id = p.company_id
  where p.id = auth.uid();
$$;
revoke all on function public.current_training_access() from public, anon;
grant execute on function public.current_training_access() to authenticated;

-- Enforce tenant access for every authenticated PostgREST request. This mirrors
-- the client gate but cannot be bypassed by calling the Data API directly.
create or replace function public.enforce_linecrew_company_access()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_active boolean;
  v_status text;
  v_expires timestamptz;
begin
  if auth.uid() is null then return; end if;

  select coalesce(p.active,true), lower(coalesce(c.subscription_status,'trial')), c.subscription_expires_at
    into v_active, v_status, v_expires
  from public.profiles p
  join public.companies c on c.id = p.company_id
  where p.id = auth.uid();

  -- Permit brand-new users without a profile to complete onboarding.
  if not found then return; end if;
  if v_active is not true then
    raise exception using errcode='42501', message='LineCrew profile access is inactive.';
  end if;
  if v_status in ('suspended','cancelled')
     or (v_status = 'trial' and v_expires is not null and v_expires <= now()) then
    raise exception using errcode='42501', message='LineCrew company access is inactive.';
  end if;
end;
$$;
revoke all on function public.enforce_linecrew_company_access() from public, anon;
grant execute on function public.enforce_linecrew_company_access() to authenticated, service_role;

alter role authenticator set pgrst.db_pre_request = 'public.enforce_linecrew_company_access';
notify pgrst, 'reload config';

commit;
