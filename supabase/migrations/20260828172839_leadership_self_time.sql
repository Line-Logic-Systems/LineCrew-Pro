begin;

-- Leadership users need a payroll-ready way to record their own time even when
-- the day is company overhead rather than work charged to a field job.
alter table public.timekeeping_entries
  alter column job_id drop not null,
  add column if not exists entry_kind text not null default 'crew',
  add column if not exists labor_code text;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'timekeeping_entries_entry_kind_check'
      and conrelid = 'public.timekeeping_entries'::regclass
  ) then
    alter table public.timekeeping_entries
      add constraint timekeeping_entries_entry_kind_check
      check (entry_kind in ('crew','leadership_self'));
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'timekeeping_entries_charge_check'
      and conrelid = 'public.timekeeping_entries'::regclass
  ) then
    alter table public.timekeeping_entries
      add constraint timekeeping_entries_charge_check
      check (
        (entry_kind = 'crew' and job_id is not null)
        or
        (entry_kind = 'leadership_self' and (
          job_id is not null or nullif(btrim(coalesce(labor_code,'')),'') is not null
        ))
      );
  end if;
end
$$;

create unique index if not exists timekeeping_entries_leadership_overhead_uidx
  on public.timekeeping_entries(company_id, employee_id, work_date, lower(labor_code))
  where entry_kind = 'leadership_self' and job_id is null;

create index if not exists timekeeping_entries_kind_company_date_idx
  on public.timekeeping_entries(entry_kind, company_id, work_date desc);

-- A profile-backed employee record makes leadership time flow through the
-- existing payroll, overtime, pay-period, and export pipeline.
create or replace function public.sync_foreman_timekeeping_employee()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role text := lower(coalesce(new.role,''));
  v_classification text;
  v_assigned_foreman_id uuid;
begin
  v_classification := case v_role
    when 'foreman' then 'Foreman'
    when 'gf' then 'General Foreman'
    when 'superintendent' then 'Superintendent'
    when 'admin' then 'Admin'
    when 'owner' then 'Owner'
    else null
  end;
  v_assigned_foreman_id := case when v_role = 'foreman' then new.id else null end;

  if v_classification is not null
     and coalesce(new.active,true) is true
     and new.company_id is not null then
    insert into public.timekeeping_employees(
      company_id, full_name, classification, active, assigned_foreman_id,
      linked_profile_id, created_by, updated_at
    ) values (
      new.company_id,
      coalesce(nullif(btrim(new.full_name),''),v_classification),
      v_classification,
      true,
      v_assigned_foreman_id,
      new.id,
      new.id,
      now()
    )
    on conflict (linked_profile_id) where linked_profile_id is not null
    do update set
      company_id = excluded.company_id,
      full_name = excluded.full_name,
      classification = excluded.classification,
      active = true,
      assigned_foreman_id = excluded.assigned_foreman_id,
      updated_at = now();
  elsif new.id is not null then
    update public.timekeeping_employees
       set active = false, updated_at = now()
     where linked_profile_id = new.id;
  end if;

  return new;
end;
$$;

revoke all on function public.sync_foreman_timekeeping_employee()
  from public, anon, authenticated;

insert into public.timekeeping_employees(
  company_id, full_name, classification, active, assigned_foreman_id,
  linked_profile_id, created_by, updated_at
)
select
  p.company_id,
  coalesce(nullif(btrim(p.full_name),''), case lower(p.role)
    when 'foreman' then 'Foreman'
    when 'gf' then 'General Foreman'
    when 'superintendent' then 'Superintendent'
    when 'admin' then 'Admin'
    when 'owner' then 'Owner'
  end),
  case lower(p.role)
    when 'foreman' then 'Foreman'
    when 'gf' then 'General Foreman'
    when 'superintendent' then 'Superintendent'
    when 'admin' then 'Admin'
    when 'owner' then 'Owner'
  end,
  true,
  case when lower(p.role) = 'foreman' then p.id else null end,
  p.id,
  p.id,
  now()
from public.profiles p
where lower(coalesce(p.role,'')) in ('foreman','gf','superintendent','admin','owner')
  and coalesce(p.active,true) is true
  and p.company_id is not null
on conflict (linked_profile_id) where linked_profile_id is not null
do update set
  company_id = excluded.company_id,
  full_name = excluded.full_name,
  classification = excluded.classification,
  active = true,
  assigned_foreman_id = excluded.assigned_foreman_id,
  updated_at = now();

-- Keep the existing role-scoped policies intact and add narrowly-scoped access
-- for a leadership user to their own linked employee and self-time rows.
drop policy if exists timekeeping_employees_select_own_profile on public.timekeeping_employees;
create policy timekeeping_employees_select_own_profile
on public.timekeeping_employees for select to authenticated
using (
  company_id = (select public.my_company_id())
  and linked_profile_id = (select auth.uid())
  and (select public.current_user_has_active_profile())
);

drop policy if exists timekeeping_entries_select_own_leadership on public.timekeeping_entries;
create policy timekeeping_entries_select_own_leadership
on public.timekeeping_entries for select to authenticated
using (
  company_id = (select public.my_company_id())
  and entry_kind = 'leadership_self'
  and exists (
    select 1 from public.timekeeping_employees employee
    where employee.id = timekeeping_entries.employee_id
      and employee.company_id = timekeeping_entries.company_id
      and employee.linked_profile_id = (select auth.uid())
  )
);

drop policy if exists timekeeping_entries_insert_own_leadership on public.timekeeping_entries;
create policy timekeeping_entries_insert_own_leadership
on public.timekeeping_entries for insert to authenticated
with check (
  company_id = (select public.my_company_id())
  and (select public.current_user_has_active_profile())
  and lower(coalesce((select public.my_role()),'')) in ('gf','superintendent','admin','owner')
  and entry_kind = 'leadership_self'
  and daily_report_id is null
  and created_by = (select auth.uid())
  and updated_by = (select auth.uid())
  and exists (
    select 1 from public.timekeeping_employees employee
    where employee.id = timekeeping_entries.employee_id
      and employee.company_id = timekeeping_entries.company_id
      and employee.linked_profile_id = (select auth.uid())
      and employee.active is true
  )
);

drop policy if exists timekeeping_entries_update_own_leadership on public.timekeeping_entries;
create policy timekeeping_entries_update_own_leadership
on public.timekeeping_entries for update to authenticated
using (
  company_id = (select public.my_company_id())
  and entry_kind = 'leadership_self'
  and exists (
    select 1 from public.timekeeping_employees employee
    where employee.id = timekeeping_entries.employee_id
      and employee.company_id = timekeeping_entries.company_id
      and employee.linked_profile_id = (select auth.uid())
  )
)
with check (
  company_id = (select public.my_company_id())
  and (select public.current_user_has_active_profile())
  and lower(coalesce((select public.my_role()),'')) in ('gf','superintendent','admin','owner')
  and entry_kind = 'leadership_self'
  and daily_report_id is null
  and updated_by = (select auth.uid())
  and exists (
    select 1 from public.timekeeping_employees employee
    where employee.id = timekeeping_entries.employee_id
      and employee.company_id = timekeeping_entries.company_id
      and employee.linked_profile_id = (select auth.uid())
      and employee.active is true
  )
);

drop policy if exists timekeeping_entries_delete_own_leadership on public.timekeeping_entries;
create policy timekeeping_entries_delete_own_leadership
on public.timekeeping_entries for delete to authenticated
using (
  company_id = (select public.my_company_id())
  and entry_kind = 'leadership_self'
  and exists (
    select 1 from public.timekeeping_employees employee
    where employee.id = timekeeping_entries.employee_id
      and employee.company_id = timekeeping_entries.company_id
      and employee.linked_profile_id = (select auth.uid())
  )
);

-- This helper needs to update the full week, including a rare crew entry for
-- the same person. It lives outside the exposed API schema and verifies the
-- caller, company, role, and profile-linked employee before bypassing RLS.
create schema if not exists private;
revoke all on schema private from public, anon;
grant usage on schema private to authenticated;

create or replace function private.recalculate_leadership_week(
  p_company_id uuid,
  p_employee_id uuid,
  p_work_date date,
  p_actor_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_week_start_day integer;
  v_week_start date;
  v_week_end date;
  v_running numeric := 0;
  v_total numeric;
  v_regular numeric;
  v_overtime numeric;
  rec record;
begin
  if auth.uid() is null or auth.uid() is distinct from p_actor_id then
    raise exception using errcode = '42501', message = 'Not authenticated.';
  end if;

  if not exists (
    select 1 from public.profiles profile
    where profile.id = auth.uid()
      and profile.company_id = p_company_id
      and coalesce(profile.active,true) is true
      and lower(coalesce(profile.role,'')) in ('gf','superintendent','admin','owner')
  ) or not exists (
    select 1 from public.timekeeping_employees employee
    where employee.id = p_employee_id
      and employee.company_id = p_company_id
      and employee.linked_profile_id = auth.uid()
      and employee.active is true
  ) then
    raise exception using errcode = '42501', message = 'You can recalculate only your own leadership time.';
  end if;

  select coalesce(company.week_start_day,1)
    into v_week_start_day
  from public.companies company
  where company.id = p_company_id;

  v_week_start := p_work_date - (((extract(dow from p_work_date)::integer - v_week_start_day + 7) % 7));
  v_week_end := v_week_start + 6;

  for rec in
    select entry.id,
           greatest(0, least(24, coalesce(entry.regular_hours,0) + coalesce(entry.overtime_hours,0))) as total_hours
    from public.timekeeping_entries entry
    where entry.company_id = p_company_id
      and entry.employee_id = p_employee_id
      and entry.work_date between v_week_start and v_week_end
    order by entry.work_date, entry.created_at, entry.id
    for update
  loop
    v_total := rec.total_hours;
    v_regular := least(v_total, greatest(0, 40 - v_running));
    v_overtime := greatest(0, v_total - v_regular);

    update public.timekeeping_entries
       set regular_hours = v_regular,
           overtime_hours = v_overtime,
           updated_by = p_actor_id,
           updated_at = now()
     where id = rec.id;

    v_running := v_running + v_total;
  end loop;

  update public.daily_reports report
     set regular_hours = totals.regular_hours,
         overtime_hours = totals.overtime_hours,
         hours = totals.regular_hours + totals.overtime_hours,
         updated_at = now()
  from (
    select entry.daily_report_id,
           coalesce(sum(entry.regular_hours),0) as regular_hours,
           coalesce(sum(entry.overtime_hours),0) as overtime_hours
    from public.timekeeping_entries entry
    where entry.company_id = p_company_id
      and entry.work_date between v_week_start and v_week_end
      and entry.daily_report_id is not null
    group by entry.daily_report_id
  ) totals
  where report.id = totals.daily_report_id
    and report.company_id = p_company_id;
end;
$$;

revoke all on function private.recalculate_leadership_week(uuid,uuid,date,uuid)
  from public, anon;
grant execute on function private.recalculate_leadership_week(uuid,uuid,date,uuid)
  to authenticated;

create or replace function public.upsert_my_leadership_time(
  p_entry_id uuid default null,
  p_work_date date default null,
  p_start_time time without time zone default null,
  p_stop_time time without time zone default null,
  p_lunch_minutes integer default 0,
  p_job_id uuid default null,
  p_labor_code text default null,
  p_per_diem boolean default false,
  p_equipment_used text default null,
  p_equipment_not_used boolean default false,
  p_notes text default null
)
returns table(entry_id uuid, regular_hours numeric, overtime_hours numeric)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_employee_id uuid;
  v_entry_id uuid;
  v_old_work_date date;
  v_labor_code text;
  v_start_at timestamp without time zone;
  v_stop_at timestamp without time zone;
  v_worked numeric;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Not authenticated.';
  end if;

  select profile.company_id, lower(coalesce(profile.role,'')), coalesce(profile.active,true)
    into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true
     or v_role not in ('gf','superintendent','admin','owner') then
    raise exception using errcode = '42501', message = 'Only an active General Foreman, Superintendent, Admin, or Owner can submit My Time.';
  end if;

  select employee.id into v_employee_id
  from public.timekeeping_employees employee
  where employee.company_id = v_company_id
    and employee.linked_profile_id = auth.uid()
    and employee.active is true;

  if v_employee_id is null then
    raise exception using errcode = 'P0002', message = 'Your payroll employee record is not ready. Ask an Admin to refresh your profile.';
  end if;

  if p_work_date is null or p_start_time is null or p_stop_time is null then
    raise exception using errcode = '22023', message = 'Work Date, Start, and Stop are required.';
  end if;

  if coalesce(p_lunch_minutes,0) < 0 or coalesce(p_lunch_minutes,0) > 720 then
    raise exception using errcode = '22023', message = 'Lunch must be between 0 and 720 minutes.';
  end if;

  v_start_at := p_work_date + p_start_time;
  v_stop_at := p_work_date + p_stop_time;
  if v_stop_at <= v_start_at then
    v_stop_at := v_stop_at + interval '1 day';
  end if;
  v_worked := round(((extract(epoch from (v_stop_at - v_start_at)) / 3600.0) - (coalesce(p_lunch_minutes,0) / 60.0))::numeric,2);

  if v_worked <= 0 or v_worked > 24 then
    raise exception using errcode = '22023', message = 'Start, Stop, and Lunch must produce a shift greater than 0 and no more than 24 hours.';
  end if;

  if p_job_id is not null then
    if not exists (
      select 1 from public.jobs job
      where job.id = p_job_id and job.company_id = v_company_id and job.active is true
    ) then
      raise exception using errcode = 'P0002', message = 'Choose an active job from your company.';
    end if;
    v_labor_code := null;
  else
    v_labor_code := nullif(btrim(coalesce(p_labor_code,'')),'');
    if v_labor_code not in ('Company Overhead','Administration','Travel','Training','Other') then
      raise exception using errcode = '22023', message = 'Choose a valid overhead labor code.';
    end if;
  end if;

  if p_entry_id is not null then
    select entry.id, entry.work_date
      into v_entry_id, v_old_work_date
    from public.timekeeping_entries entry
    where entry.id = p_entry_id
      and entry.company_id = v_company_id
      and entry.employee_id = v_employee_id
      and entry.entry_kind = 'leadership_self'
      and entry.daily_report_id is null;

    if v_entry_id is null then
      raise exception using errcode = 'P0002', message = 'My Time entry was not found.';
    end if;
  else
    select entry.id, entry.work_date
      into v_entry_id, v_old_work_date
    from public.timekeeping_entries entry
    where entry.company_id = v_company_id
      and entry.employee_id = v_employee_id
      and entry.work_date = p_work_date
      and entry.entry_kind = 'leadership_self'
      and entry.daily_report_id is null
      and (
        (p_job_id is not null and entry.job_id = p_job_id)
        or
        (p_job_id is null and entry.job_id is null and lower(entry.labor_code) = lower(v_labor_code))
      )
    limit 1;
  end if;

  if v_entry_id is null then
    insert into public.timekeeping_entries(
      company_id, employee_id, daily_report_id, job_id, work_date, crew_name,
      regular_hours, overtime_hours, storm_work, notes, created_by, updated_by,
      start_time, stop_time, lunch_minutes, per_diem, equipment_used,
      equipment_not_used, entry_kind, labor_code
    ) values (
      v_company_id, v_employee_id, null, p_job_id, p_work_date, null,
      v_worked, 0, false, nullif(btrim(coalesce(p_notes,'')),''), auth.uid(), auth.uid(),
      p_start_time, p_stop_time, coalesce(p_lunch_minutes,0), coalesce(p_per_diem,false),
      case when coalesce(p_equipment_not_used,false) then null else nullif(btrim(coalesce(p_equipment_used,'')),'') end,
      coalesce(p_equipment_not_used,false), 'leadership_self', v_labor_code
    )
    returning id into v_entry_id;
  else
    update public.timekeeping_entries entry
       set job_id = p_job_id,
           work_date = p_work_date,
           crew_name = null,
           regular_hours = v_worked,
           overtime_hours = 0,
           storm_work = false,
           notes = nullif(btrim(coalesce(p_notes,'')),''),
           updated_by = auth.uid(),
           updated_at = now(),
           start_time = p_start_time,
           stop_time = p_stop_time,
           lunch_minutes = coalesce(p_lunch_minutes,0),
           per_diem = coalesce(p_per_diem,false),
           equipment_used = case when coalesce(p_equipment_not_used,false) then null else nullif(btrim(coalesce(p_equipment_used,'')),'') end,
           equipment_not_used = coalesce(p_equipment_not_used,false),
           labor_code = v_labor_code
     where entry.id = v_entry_id;
  end if;

  if v_old_work_date is not null and v_old_work_date is distinct from p_work_date then
    perform private.recalculate_leadership_week(v_company_id,v_employee_id,v_old_work_date,auth.uid());
  end if;
  perform private.recalculate_leadership_week(v_company_id,v_employee_id,p_work_date,auth.uid());

  return query
    select entry.id, entry.regular_hours, entry.overtime_hours
    from public.timekeeping_entries entry
    where entry.id = v_entry_id;
end;
$$;

revoke all on function public.upsert_my_leadership_time(uuid,date,time without time zone,time without time zone,integer,uuid,text,boolean,text,boolean,text)
  from public, anon;
grant execute on function public.upsert_my_leadership_time(uuid,date,time without time zone,time without time zone,integer,uuid,text,boolean,text,boolean,text)
  to authenticated;

-- Version 3 adds the source kind and overhead labor code while preserving the
-- split-day history behavior used by every payroll and export surface.
create or replace function public.timekeeping_report_rows_v3(
  p_from date,
  p_through date,
  p_employee uuid default null,
  p_job uuid default null
)
returns table(
  entry_id uuid, employee_id uuid, daily_report_id uuid, job_id uuid, work_date date,
  crew_name text, regular_hours numeric, overtime_hours numeric, storm_work boolean,
  notes text, segment_source text, start_time time without time zone,
  stop_time time without time zone, lunch_minutes integer, per_diem boolean,
  equipment_used text, equipment_not_used boolean, entry_kind text, labor_code text
)
language sql
security invoker
set search_path = ''
as $$
  with viewer as (
    select profile.id, profile.company_id, lower(coalesce(profile.role,'')) as role
    from public.profiles profile
    where profile.id = auth.uid() and coalesce(profile.active,true) is true
  ), all_rows as (
    select entry.id as entry_id, entry.employee_id, entry.daily_report_id, entry.job_id,
           entry.work_date, entry.crew_name, entry.regular_hours, entry.overtime_hours,
           entry.storm_work, entry.notes, 'current'::text as segment_source,
           entry.company_id, entry.created_by, entry.start_time, entry.stop_time,
           entry.lunch_minutes, entry.per_diem, entry.equipment_used,
           entry.equipment_not_used, entry.entry_kind, entry.labor_code
    from public.timekeeping_entries entry
    union all
    select history.id as entry_id, history.employee_id, history.daily_report_id,
           history.job_id, history.work_date, history.crew_name, history.regular_hours,
           history.overtime_hours, history.storm_work, history.notes,
           'history'::text as segment_source, history.company_id, history.created_by,
           history.start_time, history.stop_time, history.lunch_minutes,
           history.per_diem, history.equipment_used, history.equipment_not_used,
           'crew'::text as entry_kind, null::text as labor_code
    from public.timekeeping_entry_history history
  )
  select row.entry_id, row.employee_id, row.daily_report_id, row.job_id, row.work_date,
         row.crew_name, row.regular_hours, row.overtime_hours, row.storm_work,
         row.notes, row.segment_source, row.start_time, row.stop_time,
         row.lunch_minutes, row.per_diem, row.equipment_used,
         row.equipment_not_used, row.entry_kind, row.labor_code
  from all_rows row
  join viewer on viewer.company_id = row.company_id
  where row.work_date between p_from and p_through
    and (p_employee is null or row.employee_id = p_employee)
    and (p_job is null or row.job_id = p_job)
    and (
      viewer.role in ('gf','admin','owner')
      or (viewer.role = 'superintendent' and public.linecrew_has_capability('reporting'))
      or (row.entry_kind = 'leadership_self' and exists (
        select 1 from public.timekeeping_employees employee
        where employee.id = row.employee_id
          and employee.company_id = row.company_id
          and employee.linked_profile_id = viewer.id
      ))
      or (viewer.role = 'foreman' and (
        row.created_by = viewer.id
        or exists (
          select 1 from public.timekeeping_employees employee
          where employee.id = row.employee_id
            and employee.company_id = row.company_id
            and employee.assigned_foreman_id = viewer.id
        )
      ))
    )
  order by row.work_date desc, row.employee_id;
$$;

revoke all on function public.timekeeping_report_rows_v3(date,date,uuid,uuid)
  from public, anon;
grant execute on function public.timekeeping_report_rows_v3(date,date,uuid,uuid)
  to authenticated;

commit;
