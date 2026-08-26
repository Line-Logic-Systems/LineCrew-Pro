begin;

alter table public.timekeeping_employees
  add column if not exists default_equipment text;

alter table public.timekeeping_entries
  add column if not exists start_time time without time zone,
  add column if not exists stop_time time without time zone,
  add column if not exists lunch_minutes integer not null default 0,
  add column if not exists per_diem boolean not null default false,
  add column if not exists equipment_used text,
  add column if not exists equipment_not_used boolean not null default false;

alter table public.timekeeping_entry_history
  add column if not exists start_time time without time zone,
  add column if not exists stop_time time without time zone,
  add column if not exists lunch_minutes integer not null default 0,
  add column if not exists per_diem boolean not null default false,
  add column if not exists equipment_used text,
  add column if not exists equipment_not_used boolean not null default false;

do $$ begin
  if not exists (select 1 from pg_constraint where conname='timekeeping_entries_lunch_minutes_check') then
    alter table public.timekeeping_entries add constraint timekeeping_entries_lunch_minutes_check check (lunch_minutes between 0 and 720);
  end if;
  if not exists (select 1 from pg_constraint where conname='timekeeping_entry_history_lunch_minutes_check') then
    alter table public.timekeeping_entry_history add constraint timekeeping_entry_history_lunch_minutes_check check (lunch_minutes between 0 and 720);
  end if;
end $$;

create or replace function public.archive_timekeeping_segment_on_report_change()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  if old.daily_report_id is distinct from new.daily_report_id
     and old.company_id = new.company_id
     and old.employee_id = new.employee_id
     and old.work_date = new.work_date
     and old.job_id = new.job_id then
    insert into public.timekeeping_entry_history(
      source_entry_id,company_id,employee_id,daily_report_id,job_id,work_date,crew_name,
      regular_hours,overtime_hours,storm_work,notes,created_by,updated_by,created_at,updated_at,
      start_time,stop_time,lunch_minutes,per_diem,equipment_used,equipment_not_used
    ) values (
      old.id,old.company_id,old.employee_id,old.daily_report_id,old.job_id,old.work_date,old.crew_name,
      old.regular_hours,old.overtime_hours,old.storm_work,old.notes,old.created_by,old.updated_by,old.created_at,old.updated_at,
      old.start_time,old.stop_time,old.lunch_minutes,old.per_diem,old.equipment_used,old.equipment_not_used
    );
  end if;
  return new;
end;
$$;

create or replace function public.timekeeping_report_rows(
  p_from date,
  p_through date,
  p_employee uuid default null,
  p_job uuid default null
)
returns table(
  employee_id uuid, daily_report_id uuid, job_id uuid, work_date date, crew_name text,
  regular_hours numeric, overtime_hours numeric, storm_work boolean, notes text, segment_source text
)
language sql
security definer
set search_path to ''
as $$
  with viewer as (
    select p.id, p.company_id, lower(coalesce(p.role,'')) as role
    from public.profiles p
    where p.id = auth.uid() and coalesce(p.active,true) is true
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
      or (v.role='superintendent' and public.linecrew_has_capability('reporting'))
      or (v.role='foreman' and (
        r.created_by=v.id
        or exists (
          select 1 from public.timekeeping_employees te
          where te.id=r.employee_id and te.company_id=r.company_id and te.assigned_foreman_id=v.id
        )
      ))
    )
  order by r.work_date desc, r.employee_id;
$$;

create or replace function public.timekeeping_report_rows_v2(
  p_from date,
  p_through date,
  p_employee uuid default null,
  p_job uuid default null
)
returns table(
  employee_id uuid, daily_report_id uuid, job_id uuid, work_date date, crew_name text,
  regular_hours numeric, overtime_hours numeric, storm_work boolean, notes text, segment_source text,
  start_time time without time zone, stop_time time without time zone, lunch_minutes integer,
  per_diem boolean, equipment_used text, equipment_not_used boolean
)
language sql
security definer
set search_path to ''
as $$
  with viewer as (
    select p.id, p.company_id, lower(coalesce(p.role,'')) as role
    from public.profiles p
    where p.id=auth.uid() and coalesce(p.active,true) is true
  ), all_rows as (
    select e.employee_id,e.daily_report_id,e.job_id,e.work_date,e.crew_name,e.regular_hours,e.overtime_hours,e.storm_work,e.notes,
           'current'::text segment_source,e.company_id,e.created_by,e.start_time,e.stop_time,e.lunch_minutes,e.per_diem,e.equipment_used,e.equipment_not_used
    from public.timekeeping_entries e
    union all
    select h.employee_id,h.daily_report_id,h.job_id,h.work_date,h.crew_name,h.regular_hours,h.overtime_hours,h.storm_work,h.notes,
           'history'::text,h.company_id,h.created_by,h.start_time,h.stop_time,h.lunch_minutes,h.per_diem,h.equipment_used,h.equipment_not_used
    from public.timekeeping_entry_history h
  )
  select r.employee_id,r.daily_report_id,r.job_id,r.work_date,r.crew_name,r.regular_hours,r.overtime_hours,r.storm_work,r.notes,r.segment_source,
         r.start_time,r.stop_time,r.lunch_minutes,r.per_diem,r.equipment_used,r.equipment_not_used
  from all_rows r
  join viewer v on v.company_id=r.company_id
  where r.work_date between p_from and p_through
    and (p_employee is null or r.employee_id=p_employee)
    and (p_job is null or r.job_id=p_job)
    and (
      v.role in ('gf','admin','owner')
      or (v.role='superintendent' and public.linecrew_has_capability('reporting'))
      or (v.role='foreman' and (
        r.created_by=v.id
        or exists (
          select 1 from public.timekeeping_employees te
          where te.id=r.employee_id and te.company_id=r.company_id and te.assigned_foreman_id=v.id
        )
      ))
    )
  order by r.work_date desc,r.employee_id;
$$;

revoke all on function public.timekeeping_report_rows_v2(date,date,uuid,uuid) from public,anon;
grant execute on function public.timekeeping_report_rows_v2(date,date,uuid,uuid) to authenticated;

drop policy if exists timekeeping_employees_role_scoped_select on public.timekeeping_employees;
create policy timekeeping_employees_role_scoped_select
on public.timekeeping_employees for select to authenticated
using (
  company_id=(select public.my_company_id())
  and (select public.current_user_has_active_profile())
  and (
    lower(coalesce((select public.my_role()),'')) in ('owner','admin','gf')
    or (lower(coalesce((select public.my_role()),''))='superintendent' and (select public.linecrew_has_capability('reporting')))
    or (lower(coalesce((select public.my_role()),''))='foreman' and active is true)
  )
);

drop policy if exists timekeeping_entries_select_company on public.timekeeping_entries;
create policy timekeeping_entries_select_company
on public.timekeeping_entries for select to authenticated
using (
  company_id=(select public.my_company_id())
  and (
    lower(coalesce((select public.my_role()),'')) in ('gf','admin','owner')
    or (lower(coalesce((select public.my_role()),''))='superintendent' and (select public.linecrew_has_capability('reporting')))
    or (lower(coalesce((select public.my_role()),''))='foreman' and (
      created_by=(select auth.uid())
      or exists (
        select 1 from public.timekeeping_employees te
        where te.id=timekeeping_entries.employee_id
          and te.company_id=timekeeping_entries.company_id
          and te.assigned_foreman_id=(select auth.uid())
      )
    ))
  )
);

drop policy if exists timekeeping_entry_history_select_company on public.timekeeping_entry_history;
create policy timekeeping_entry_history_select_company
on public.timekeeping_entry_history for select to authenticated
using (
  company_id=(select public.my_company_id())
  and (
    lower(coalesce((select public.my_role()),'')) in ('gf','admin','owner')
    or (lower(coalesce((select public.my_role()),''))='superintendent' and (select public.linecrew_has_capability('reporting')))
    or (lower(coalesce((select public.my_role()),''))='foreman' and (
      created_by=(select auth.uid())
      or exists (
        select 1 from public.timekeeping_employees te
        where te.id=timekeeping_entry_history.employee_id
          and te.company_id=timekeeping_entry_history.company_id
          and te.assigned_foreman_id=(select auth.uid())
      )
    ))
  )
);

commit;
