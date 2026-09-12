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
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_active is not true
     or v_role not in ('foreman','gf','admin','manager','owner','superintendent') then
    raise exception using errcode='42501', message='An active company timekeeping role is required.';
  end if;

  if v_role='superintendent' and not public.linecrew_has_capability('production_review') then
    raise exception using errcode='42501', message='This Superintendent does not have production review permission.';
  end if;

  select r.company_id, r.foreman_id, r.work_date
    into v_report_company_id, v_report_foreman_id, v_work_date
  from public.daily_reports r
  where r.id=p_report_id;

  if v_report_company_id is null or v_report_company_id<>v_company_id then
    raise exception using errcode='P0002', message='Daily report was not found in your company.';
  end if;

  if v_role='foreman' and v_report_foreman_id is distinct from auth.uid() then
    raise exception using errcode='42501', message='Foremen can recalculate time only on their own reports.';
  end if;

  if not exists (
    select 1 from public.timekeeping_employees e
    where e.id=p_employee_id and e.company_id=v_company_id and e.active is true
  ) then
    raise exception using errcode='P0002', message='Employee was not found in your company.';
  end if;

  select coalesce(c.week_start_day,1)
    into v_week_start_day
  from public.companies c
  where c.id=v_company_id;

  v_week_start := v_work_date - (((extract(dow from v_work_date)::int-v_week_start_day+7)%7));
  v_week_end := v_week_start+6;

  -- Certified entries are immutable. Reserve their existing regular-hour
  -- allocation, then distribute only the remaining weekly regular allowance
  -- across editable entries. This keeps the 40-hour ceiling without rewriting
  -- an approved Daily Report when earlier time is entered later.
  select coalesce(sum(e.regular_hours),0)
    into v_running
  from public.timekeeping_entries e
  join public.daily_reports r on r.id=e.daily_report_id
  where e.company_id=v_company_id
    and e.employee_id=p_employee_id
    and e.work_date between v_week_start and v_week_end
    and lower(coalesce(r.status,'draft'))='approved';

  for rec in
    select e.id, e.daily_report_id, e.work_date,
           (coalesce(e.regular_hours,0)+coalesce(e.overtime_hours,0)) as total_hours
    from public.timekeeping_entries e
    left join public.daily_reports r on r.id=e.daily_report_id
    where e.company_id=v_company_id
      and e.employee_id=p_employee_id
      and e.work_date between v_week_start and v_week_end
      and lower(coalesce(r.status,'draft'))<>'approved'
    order by e.work_date,e.created_at,e.id
    for update of e
  loop
    v_total := greatest(0,least(24,coalesce(rec.total_hours,0)));
    v_regular := least(v_total,greatest(0,40-v_running));
    v_overtime := greatest(0,v_total-v_regular);

    update public.timekeeping_entries
       set regular_hours=v_regular,
           overtime_hours=v_overtime,
           updated_at=now()
     where id=rec.id;

    v_running := v_running+v_regular;
  end loop;

  update public.daily_reports r
     set regular_hours=totals.regular_hours,
         overtime_hours=totals.overtime_hours,
         updated_at=now()
  from (
    select e.daily_report_id,
           coalesce(sum(e.regular_hours),0) regular_hours,
           coalesce(sum(e.overtime_hours),0) overtime_hours
    from public.timekeeping_entries e
    join public.daily_reports source_report on source_report.id=e.daily_report_id
    where e.company_id=v_company_id
      and e.work_date between v_week_start and v_week_end
      and e.daily_report_id is not null
      and lower(coalesce(source_report.status,'draft'))<>'approved'
    group by e.daily_report_id
  ) totals
  where r.id=totals.daily_report_id
    and r.company_id=v_company_id
    and lower(coalesce(r.status,'draft'))<>'approved';
end;
$$;

create or replace function public.save_daily_report_crew_time(
  p_report_id uuid,
  p_rows jsonb
)
returns table(employee_id uuid, regular_hours numeric, overtime_hours numeric)
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_report public.daily_reports%rowtype;
  v_employee_ids uuid[];
  v_row_count integer;
  v_distinct_count integer;
  rec record;
begin
  if v_user_id is null then
    raise exception using errcode='42501', message='Sign in before saving Crew Time.';
  end if;

  select p.company_id,lower(coalesce(p.role,'')),p.active
    into v_company_id,v_role,v_active
  from public.profiles p
  where p.id=v_user_id;

  if v_company_id is null or v_active is not true
     or v_role not in ('foreman','gf','admin','manager','owner','superintendent') then
    raise exception using errcode='42501', message='An active company timekeeping role is required.';
  end if;

  if v_role='superintendent' and not public.linecrew_has_capability('production_review') then
    raise exception using errcode='42501', message='This Superintendent does not have production review permission.';
  end if;

  select r.* into v_report
  from public.daily_reports r
  where r.id=p_report_id
  for update;

  if not found or v_report.company_id<>v_company_id then
    raise exception using errcode='P0002', message='Daily report was not found in your company.';
  end if;
  if v_report.archived is true then
    raise exception using errcode='23514', message='Archived Daily Report time is read-only.';
  end if;
  if lower(coalesce(v_report.status,'draft'))='approved' then
    raise exception using errcode='23514', message='Approved Daily Report crew time is read-only. Reopen or return the report before changing time.';
  end if;
  if v_role='foreman' and v_report.foreman_id is distinct from v_user_id then
    raise exception using errcode='42501', message='Foremen can save Crew Time only on their own reports.';
  end if;
  if jsonb_typeof(p_rows)<>'array' or jsonb_array_length(p_rows)=0 then
    raise exception using errcode='22023', message='Crew Time did not load. Existing time was not changed.';
  end if;

  with parsed as (
    select nullif(btrim(row_data->>'employee_id'),'')::uuid employee_id
    from jsonb_array_elements(p_rows) row_data
  )
  select count(*),count(distinct parsed.employee_id),array_agg(parsed.employee_id)
    into v_row_count,v_distinct_count,v_employee_ids
  from parsed;

  if v_row_count<>v_distinct_count or array_position(v_employee_ids,null) is not null then
    raise exception using errcode='22023', message='Select each employee once before saving Crew Time.';
  end if;
  if exists (
    select 1 from unnest(v_employee_ids) requested(employee_id)
    left join public.timekeeping_employees e
      on e.id=requested.employee_id and e.company_id=v_company_id and e.active is true
    where e.id is null
  ) then
    raise exception using errcode='P0002', message='One or more employees are unavailable in your company.';
  end if;
  if exists (
    select 1
    from jsonb_array_elements(p_rows) row_data
    where coalesce((row_data->>'regular_hours')::numeric,0)<0
       or coalesce((row_data->>'overtime_hours')::numeric,0)<0
       or coalesce((row_data->>'regular_hours')::numeric,0)+coalesce((row_data->>'overtime_hours')::numeric,0)>24
       or coalesce((row_data->>'lunch_minutes')::integer,0) not between 0 and 720
  ) then
    raise exception using errcode='22023', message='Crew Time values are outside the allowed range.';
  end if;
  if exists (
    select 1 from public.timekeeping_entries e
    where e.company_id=v_company_id
      and e.employee_id=any(v_employee_ids)
      and e.work_date=v_report.work_date
      and e.job_id=v_report.job_id
      and e.daily_report_id is distinct from p_report_id
  ) then
    raise exception using errcode='23505', message='An employee is already recorded on another crew report for this job and date.';
  end if;

  for rec in select row_data from jsonb_array_elements(p_rows) row_data
  loop
    insert into public.timekeeping_entries(
      company_id,employee_id,daily_report_id,job_id,work_date,crew_name,
      regular_hours,overtime_hours,start_time,stop_time,lunch_minutes,per_diem,
      equipment_used,equipment_not_used,entry_kind,created_by,updated_by,updated_at
    ) values (
      v_company_id,(rec.row_data->>'employee_id')::uuid,p_report_id,v_report.job_id,v_report.work_date,
      nullif(btrim(coalesce(rec.row_data->>'crew_name','')),''),
      coalesce((rec.row_data->>'regular_hours')::numeric,0),coalesce((rec.row_data->>'overtime_hours')::numeric,0),
      nullif(rec.row_data->>'start_time','')::time,nullif(rec.row_data->>'stop_time','')::time,
      coalesce((rec.row_data->>'lunch_minutes')::integer,0),coalesce((rec.row_data->>'per_diem')::boolean,false),
      case when coalesce((rec.row_data->>'equipment_not_used')::boolean,false) then null else nullif(btrim(coalesce(rec.row_data->>'equipment_used','')),'') end,
      coalesce((rec.row_data->>'equipment_not_used')::boolean,false),'crew',v_user_id,v_user_id,now()
    )
    on conflict on constraint timekeeping_entries_employee_day_job_unique do update set
      daily_report_id=excluded.daily_report_id,
      crew_name=excluded.crew_name,
      regular_hours=excluded.regular_hours,
      overtime_hours=excluded.overtime_hours,
      start_time=excluded.start_time,
      stop_time=excluded.stop_time,
      lunch_minutes=excluded.lunch_minutes,
      per_diem=excluded.per_diem,
      equipment_used=excluded.equipment_used,
      equipment_not_used=excluded.equipment_not_used,
      entry_kind='crew',
      updated_by=v_user_id,
      updated_at=now();
  end loop;

  delete from public.timekeeping_entries e
  where e.daily_report_id=p_report_id
    and not (e.employee_id=any(v_employee_ids));

  for rec in select unnest(v_employee_ids) employee_id
  loop
    perform public.recalculate_timekeeping_employee_week(p_report_id,rec.employee_id);
  end loop;

  return query
  select e.employee_id,e.regular_hours,e.overtime_hours
  from public.timekeeping_entries e
  where e.daily_report_id=p_report_id
  order by e.created_at,e.id;
end;
$$;

revoke all on function public.save_daily_report_crew_time(uuid,jsonb) from public,anon;
grant execute on function public.save_daily_report_crew_time(uuid,jsonb) to authenticated,service_role;
