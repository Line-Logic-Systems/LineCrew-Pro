create or replace function public.guard_approved_daily_report_timekeeping()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_report_id uuid := coalesce(new.daily_report_id, old.daily_report_id);
  v_status text;
begin
  if v_report_id is null then
    return coalesce(new, old);
  end if;

  select lower(coalesce(r.status,'draft')) into v_status
  from public.daily_reports r
  where r.id = v_report_id;

  if v_status <> 'approved' then
    return coalesce(new, old);
  end if;

  if tg_op in ('INSERT','DELETE') then
    raise exception using errcode='23514',
      message='Approved Daily Report crew time is read-only. Reopen or return the report before changing time.';
  end if;

  if tg_op = 'UPDATE' and (
    new.daily_report_id is distinct from old.daily_report_id or
    new.employee_id is distinct from old.employee_id or
    new.job_id is distinct from old.job_id or
    new.work_date is distinct from old.work_date or
    new.regular_hours is distinct from old.regular_hours or
    new.overtime_hours is distinct from old.overtime_hours or
    new.start_time is distinct from old.start_time or
    new.stop_time is distinct from old.stop_time or
    new.lunch_minutes is distinct from old.lunch_minutes or
    new.per_diem is distinct from old.per_diem or
    new.equipment_used is distinct from old.equipment_used or
    new.equipment_not_used is distinct from old.equipment_not_used or
    new.storm_work is distinct from old.storm_work
  ) then
    raise exception using errcode='23514',
      message='Approved Daily Report crew time is read-only. Reopen or return the report before changing time.';
  end if;

  return coalesce(new, old);
end;
$$;

drop trigger if exists guard_approved_daily_report_timekeeping on public.timekeeping_entries;
create trigger guard_approved_daily_report_timekeeping
before insert or update or delete on public.timekeeping_entries
for each row execute function public.guard_approved_daily_report_timekeeping();

create or replace function public.guard_approved_daily_report_hours()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  if lower(coalesce(old.status,'draft'))='approved'
     and lower(coalesce(new.status,'draft'))='approved'
     and (
       new.regular_hours is distinct from old.regular_hours or
       new.overtime_hours is distinct from old.overtime_hours or
       new.hours is distinct from old.hours
     ) then
    raise exception using errcode='23514',
      message='Approved Daily Report hours are read-only. Return or reopen the report before changing certified hours.';
  end if;
  return new;
end;
$$;

drop trigger if exists guard_approved_daily_report_hours on public.daily_reports;
create trigger guard_approved_daily_report_hours
before update of regular_hours,overtime_hours,hours,status on public.daily_reports
for each row execute function public.guard_approved_daily_report_hours();

do $$
declare
  v_oid oid := to_regprocedure('public.recalculate_timekeeping_employee_week(uuid,uuid)');
  v_def text;
begin
  if v_oid is null then raise exception 'recalculate_timekeeping_employee_week is missing'; end if;
  select pg_get_functiondef(v_oid) into v_def;
  if strpos(v_def, 'v_role not in (''foreman'',''gf'',''admin'',''manager'',''owner'',''superintendent'')') = 0 then
    if strpos(v_def, 'v_role not in (''foreman'',''gf'',''admin'',''owner'',''superintendent'')') = 0 then
      raise exception 'Expected timekeeping role allow-list was not found.';
    end if;
    execute replace(v_def,
      'v_role not in (''foreman'',''gf'',''admin'',''owner'',''superintendent'')',
      'v_role not in (''foreman'',''gf'',''admin'',''manager'',''owner'',''superintendent'')');
  end if;
end $$;
