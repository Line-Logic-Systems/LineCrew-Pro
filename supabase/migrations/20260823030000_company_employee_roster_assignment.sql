begin;

-- Regular field employees are roster records, not login accounts. Company
-- leaders assign them to a home Foreman. That crew auto-loads on Daily Reports,
-- while a Foreman may also enter time for an extra active company employee on
-- a job assigned to that Foreman.
alter table public.timekeeping_employees
  add column if not exists assigned_by uuid references public.profiles(id) on delete set null,
  add column if not exists assigned_at timestamptz;

create or replace function public.validate_timekeeping_employee_assignment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_company uuid;
  v_actor_role text;
begin
  if auth.uid() is null then
    if new.assigned_foreman_id is not null and not exists (
      select 1 from public.profiles foreman
      where foreman.id = new.assigned_foreman_id
        and foreman.company_id = new.company_id
        and foreman.active is true
        and lower(coalesce(foreman.role, '')) = 'foreman'
    ) then
      raise exception using errcode='23514', message='The assigned Foreman must be an active Foreman in this company.';
    end if;
    new.updated_at := now();
    return new;
  end if;

  select p.company_id, lower(coalesce(p.role, ''))
    into v_actor_company, v_actor_role
  from public.profiles p
  where p.id = auth.uid()
    and p.active is true;

  if v_actor_company is null
     or v_actor_company <> new.company_id
     or v_actor_role not in ('owner', 'admin', 'gf') then
    raise exception using errcode='42501', message='Only an active Owner, Admin, or General Foreman can manage field employees.';
  end if;

  if new.assigned_foreman_id is not null and not exists (
    select 1
    from public.profiles foreman
    where foreman.id = new.assigned_foreman_id
      and foreman.company_id = new.company_id
      and foreman.active is true
      and lower(coalesce(foreman.role, '')) = 'foreman'
  ) then
    raise exception using errcode='23514', message='The assigned Foreman must be an active Foreman in this company.';
  end if;

  if tg_op = 'INSERT'
     or new.assigned_foreman_id is distinct from old.assigned_foreman_id then
    new.assigned_by := case when new.assigned_foreman_id is null then null else auth.uid() end;
    new.assigned_at := case when new.assigned_foreman_id is null then null else now() end;
  end if;

  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists validate_timekeeping_employee_assignment
  on public.timekeeping_employees;
create trigger validate_timekeeping_employee_assignment
before insert or update on public.timekeeping_employees
for each row execute function public.validate_timekeeping_employee_assignment();

drop policy if exists timekeeping_employees_select_company
  on public.timekeeping_employees;
drop policy if exists timekeeping_employees_role_scoped_select
  on public.timekeeping_employees;
create policy timekeeping_employees_role_scoped_select
on public.timekeeping_employees
for select
to authenticated
using (
  company_id = (select public.my_company_id())
  and (select public.current_user_has_active_profile())
  and (
    lower(coalesce((select public.my_role()), '')) in ('owner', 'admin', 'gf')
    or (lower(coalesce((select public.my_role()), '')) = 'foreman' and active is true)
  )
);

drop policy if exists timekeeping_employees_manage_leaders
  on public.timekeeping_employees;
create policy timekeeping_employees_manage_leaders
on public.timekeeping_employees
for all
to authenticated
using (
  company_id = (select public.my_company_id())
  and (select public.current_user_has_active_profile())
  and lower(coalesce((select public.my_role()), '')) in ('owner', 'admin', 'gf')
)
with check (
  company_id = (select public.my_company_id())
  and (select public.current_user_has_active_profile())
  and lower(coalesce((select public.my_role()), '')) in ('owner', 'admin', 'gf')
);

drop policy if exists timekeeping_entries_insert_company
  on public.timekeeping_entries;
drop policy if exists timekeeping_entries_role_scoped_insert
  on public.timekeeping_entries;
create policy timekeeping_entries_role_scoped_insert
on public.timekeeping_entries
for insert
to authenticated
with check (
  company_id = (select public.my_company_id())
  and (select public.current_user_has_active_profile())
  and created_by = auth.uid()
  and updated_by = auth.uid()
  and exists (
    select 1
    from public.timekeeping_employees employee
    where employee.id = timekeeping_entries.employee_id
      and employee.company_id = timekeeping_entries.company_id
      and employee.active is true
      and (
        lower(coalesce((select public.my_role()), '')) in ('owner', 'admin', 'gf')
        or (
          lower(coalesce((select public.my_role()), '')) = 'foreman'
          and (select public.linecrew_foreman_has_job_assignment(timekeeping_entries.job_id))
        )
      )
  )
);

drop policy if exists timekeeping_entries_update_company
  on public.timekeeping_entries;
drop policy if exists timekeeping_entries_role_scoped_update
  on public.timekeeping_entries;
create policy timekeeping_entries_role_scoped_update
on public.timekeeping_entries
for update
to authenticated
using (
  company_id = (select public.my_company_id())
  and (select public.current_user_has_active_profile())
  and (
    lower(coalesce((select public.my_role()), '')) in ('owner', 'admin', 'gf')
    or created_by = auth.uid()
  )
)
with check (
  company_id = (select public.my_company_id())
  and updated_by = auth.uid()
  and exists (
    select 1
    from public.timekeeping_employees employee
    where employee.id = timekeeping_entries.employee_id
      and employee.company_id = timekeeping_entries.company_id
      and employee.active is true
      and (
        lower(coalesce((select public.my_role()), '')) in ('owner', 'admin', 'gf')
        or (
          lower(coalesce((select public.my_role()), '')) = 'foreman'
          and (select public.linecrew_foreman_has_job_assignment(timekeeping_entries.job_id))
        )
      )
  )
);

-- Foremen can no longer claim unassigned employees for themselves. Assignment
-- is a leadership action through the roster screen.
drop function if exists public.set_my_timekeeping_crew(uuid[]);

revoke all on function public.validate_timekeeping_employee_assignment()
  from public, anon, authenticated;

commit;
