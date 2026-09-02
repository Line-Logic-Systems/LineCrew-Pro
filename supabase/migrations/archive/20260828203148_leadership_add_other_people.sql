begin;

-- Admins and General Foremen can enter the same payroll-ready time for other
-- active employees in their company. The existing My Time function remains
-- self-only for Superintendent, Owner, Admin, and General Foreman.
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
  v_actor_role text;
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

  select lower(coalesce(profile.role,''))
    into v_actor_role
  from public.profiles profile
  where profile.id = auth.uid()
    and profile.company_id = p_company_id
    and coalesce(profile.active,true) is true;

  if v_actor_role is null or not exists (
    select 1 from public.timekeeping_employees employee
    where employee.id = p_employee_id
      and employee.company_id = p_company_id
      and employee.active is true
      and (
        v_actor_role in ('gf','admin')
        or (
          v_actor_role in ('gf','superintendent','admin','owner')
          and employee.linked_profile_id = auth.uid()
        )
      )
  ) then
    raise exception using errcode = '42501', message = 'You cannot recalculate time for this employee.';
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

create or replace function public.upsert_leadership_employee_time(
  p_employee_id uuid,
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

  if v_company_id is null or v_active is not true or v_role not in ('gf','admin') then
    raise exception using errcode = '42501', message = 'Only an active General Foreman or Admin can enter time for another employee.';
  end if;

  if not exists (
    select 1 from public.timekeeping_employees employee
    where employee.id = p_employee_id
      and employee.company_id = v_company_id
      and employee.active is true
  ) then
    raise exception using errcode = 'P0002', message = 'Choose an active employee from your company.';
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
      and entry.employee_id = p_employee_id
      and entry.entry_kind = 'leadership_self'
      and entry.daily_report_id is null;

    if v_entry_id is null then
      raise exception using errcode = 'P0002', message = 'The employee time entry was not found.';
    end if;
  else
    select entry.id, entry.work_date
      into v_entry_id, v_old_work_date
    from public.timekeeping_entries entry
    where entry.company_id = v_company_id
      and entry.employee_id = p_employee_id
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
      v_company_id, p_employee_id, null, p_job_id, p_work_date, null,
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
    perform private.recalculate_leadership_week(v_company_id,p_employee_id,v_old_work_date,auth.uid());
  end if;
  perform private.recalculate_leadership_week(v_company_id,p_employee_id,p_work_date,auth.uid());

  return query
    select entry.id, entry.regular_hours, entry.overtime_hours
    from public.timekeeping_entries entry
    where entry.id = v_entry_id;
end;
$$;

revoke all on function public.upsert_leadership_employee_time(uuid,uuid,date,time without time zone,time without time zone,integer,uuid,text,boolean,text,boolean,text)
  from public, anon;
grant execute on function public.upsert_leadership_employee_time(uuid,uuid,date,time without time zone,time without time zone,integer,uuid,text,boolean,text,boolean,text)
  to authenticated;

commit;
