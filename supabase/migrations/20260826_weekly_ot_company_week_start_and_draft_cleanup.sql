alter table public.companies
  add column if not exists week_start_day smallint not null default 1;

do $$ begin
  alter table public.companies
    add constraint companies_week_start_day_check check (week_start_day between 0 and 6);
exception when duplicate_object then null;
end $$;

create or replace function public.enforce_active_job_for_daily_unit_mutation()
returns trigger
language plpgsql
set search_path to ''
as $$
declare
  v_report_id uuid;
begin
  v_report_id := case when tg_op = 'DELETE' then old.daily_report_id else new.daily_report_id end;

  if tg_op = 'DELETE'
     and current_setting('linecrew.allow_never_submitted_draft_cleanup', true) = 'on'
     and exists (
       select 1 from public.daily_reports r
       where r.id = v_report_id
         and lower(coalesce(r.status, 'draft')) = 'draft'
         and r.submitted_at is null
         and r.reviewed_at is null
     ) then
    return old;
  end if;

  if not exists (
    select 1
    from public.daily_reports r
    join public.jobs j on j.id = r.job_id and j.company_id = r.company_id
    where r.id = v_report_id
      and j.active is true
  ) then
    raise exception using errcode = '23514',
      message = 'Units cannot be changed after the parent job is closed.';
  end if;

  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

create or replace function public.delete_draft_daily_report(p_report_id uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Not authenticated.';
  end if;

  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true then
    raise exception using errcode = '42501', message = 'An active company profile is required.';
  end if;

  if v_role = 'superintendent' and not public.linecrew_has_capability('production_review') then
    raise exception using errcode = '42501', message = 'This Superintendent does not have production review permission.';
  end if;

  if v_role not in ('owner', 'admin', 'superintendent', 'foreman') then
    raise exception using errcode = '42501', message = 'You do not have permission to delete draft Daily Reports.';
  end if;

  if not exists (
    select 1 from public.daily_reports report
    where report.id = p_report_id
      and report.company_id = v_company_id
      and lower(coalesce(report.status, 'draft')) = 'draft'
      and report.submitted_at is null
      and report.reviewed_at is null
      and (v_role in ('owner', 'admin', 'superintendent')
        or (v_role = 'foreman' and report.foreman_id = auth.uid()))
  ) then
    raise exception using errcode = 'P0002', message = 'Only a never-submitted draft can be deleted.';
  end if;

  perform set_config('linecrew.allow_never_submitted_draft_cleanup', 'on', true);

  delete from public.timekeeping_entries entry
  where entry.daily_report_id = p_report_id and entry.company_id = v_company_id;

  delete from public.daily_reports report
  where report.id = p_report_id
    and report.company_id = v_company_id
    and lower(coalesce(report.status, 'draft')) = 'draft'
    and report.submitted_at is null
    and report.reviewed_at is null;
end;
$$;

create or replace function public.update_company_week_start(p_week_start_day smallint)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  if p_week_start_day is null or p_week_start_day < 0 or p_week_start_day > 6 then
    raise exception using errcode = '22023', message = 'Week start day must be Sunday through Saturday.';
  end if;

  select p.company_id, lower(coalesce(p.role,'')), p.active
  into v_company_id, v_role, v_active
  from public.profiles p where p.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role not in ('owner','admin') then
    raise exception using errcode = '42501', message = 'Only an Owner or Admin can change the company workweek.';
  end if;

  update public.companies
  set week_start_day = p_week_start_day, updated_at = now()
  where id = v_company_id;
end;
$$;

create or replace function public.recalculate_timekeeping_employee_week(
  p_report_id uuid,
  p_employee_id uuid
)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_report_company_id uuid;
  v_report_foreman_id uuid;
  v_work_date date;
  v_week_start_day int;
  v_week_start date;
  v_week_end date;
  v_running numeric := 0;
  v_total numeric;
  v_regular numeric;
  v_overtime numeric;
  rec record;
begin
  select p.company_id, lower(coalesce(p.role,'')), p.active
  into v_company_id, v_role, v_active
  from public.profiles p where p.id = auth.uid();

  if v_company_id is null or v_active is not true
     or v_role not in ('foreman','gf','admin','owner','superintendent') then
    raise exception using errcode = '42501', message = 'An active company timekeeping role is required.';
  end if;

  if v_role = 'superintendent' and not public.linecrew_has_capability('production_review') then
    raise exception using errcode = '42501', message = 'This Superintendent does not have production review permission.';
  end if;

  select r.company_id, r.foreman_id, r.work_date
  into v_report_company_id, v_report_foreman_id, v_work_date
  from public.daily_reports r where r.id = p_report_id;

  if v_report_company_id is null or v_report_company_id <> v_company_id then
    raise exception using errcode = 'P0002', message = 'Daily report was not found in your company.';
  end if;

  if v_role = 'foreman' and v_report_foreman_id is distinct from auth.uid() then
    raise exception using errcode = '42501', message = 'Foremen can recalculate time only on their own reports.';
  end if;

  if not exists (
    select 1 from public.timekeeping_employees e
    where e.id = p_employee_id and e.company_id = v_company_id and e.active is true
  ) then
    raise exception using errcode = 'P0002', message = 'Employee was not found in your company.';
  end if;

  select coalesce(c.week_start_day,1) into v_week_start_day
  from public.companies c where c.id = v_company_id;

  v_week_start := v_work_date - (((extract(dow from v_work_date)::int - v_week_start_day + 7) % 7));
  v_week_end := v_week_start + 6;

  for rec in
    select e.id, e.daily_report_id, e.work_date,
           (coalesce(e.regular_hours,0) + coalesce(e.overtime_hours,0)) as total_hours
    from public.timekeeping_entries e
    where e.company_id = v_company_id
      and e.employee_id = p_employee_id
      and e.work_date between v_week_start and v_week_end
    order by e.work_date, e.created_at, e.id
    for update
  loop
    v_total := greatest(0, least(24, coalesce(rec.total_hours,0)));
    v_regular := least(v_total, greatest(0, 40 - v_running));
    v_overtime := greatest(0, v_total - v_regular);

    update public.timekeeping_entries
    set regular_hours = v_regular,
        overtime_hours = v_overtime,
        updated_at = now()
    where id = rec.id;

    v_running := v_running + v_total;
  end loop;

  update public.daily_reports r
  set regular_hours = totals.regular_hours,
      overtime_hours = totals.overtime_hours,
      updated_at = now()
  from (
    select e.daily_report_id,
           coalesce(sum(e.regular_hours),0) as regular_hours,
           coalesce(sum(e.overtime_hours),0) as overtime_hours
    from public.timekeeping_entries e
    where e.company_id = v_company_id
      and e.work_date between v_week_start and v_week_end
      and e.daily_report_id is not null
    group by e.daily_report_id
  ) totals
  where r.id = totals.daily_report_id
    and r.company_id = v_company_id;
end;
$$;

revoke all on function public.update_company_week_start(smallint) from public, anon;
grant execute on function public.update_company_week_start(smallint) to authenticated;
revoke all on function public.recalculate_timekeeping_employee_week(uuid,uuid) from public, anon;
grant execute on function public.recalculate_timekeeping_employee_week(uuid,uuid) to authenticated;