begin;

create or replace function public.admin_update_timekeeping_entry(
  p_daily_report_id uuid,
  p_employee_id uuid,
  p_start_time time without time zone,
  p_stop_time time without time zone,
  p_lunch_minutes integer,
  p_regular_hours numeric,
  p_overtime_hours numeric,
  p_per_diem boolean,
  p_equipment_used text,
  p_equipment_not_used boolean,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_profile public.profiles%rowtype;
  v_entry public.timekeeping_entries%rowtype;
  v_before jsonb;
  v_after jsonb;
  v_elapsed_minutes numeric;
  v_worked_hours numeric;
begin
  if auth.uid() is null then
    raise exception using errcode='42501', message='Not authenticated.';
  end if;

  select * into v_profile
  from public.profiles p
  where p.id = auth.uid();

  if v_profile.id is null or coalesce(v_profile.active,true) is not true
     or lower(coalesce(v_profile.role,'')) not in ('owner','admin') then
    raise exception using errcode='42501', message='Only an active Owner or Admin can edit submitted time.';
  end if;

  if p_lunch_minutes is null or p_lunch_minutes < 0 or p_lunch_minutes > 720 then
    raise exception using errcode='22023', message='Lunch must be between 0 and 720 minutes.';
  end if;

  if (p_start_time is null) <> (p_stop_time is null) then
    raise exception using errcode='22023', message='Enter both Start and Stop, or leave both blank.';
  end if;

  select e.* into v_entry
  from public.timekeeping_entries e
  join public.daily_reports r on r.id=e.daily_report_id and r.company_id=e.company_id
  where e.company_id=v_profile.company_id
    and e.daily_report_id=p_daily_report_id
    and e.employee_id=p_employee_id
  for update;

  if v_entry.id is null then
    raise exception using errcode='P0002', message='Time entry was not found in your company.';
  end if;

  if p_start_time is not null then
    v_elapsed_minutes := extract(epoch from (p_stop_time - p_start_time)) / 60.0;
    if v_elapsed_minutes < 0 then
      v_elapsed_minutes := v_elapsed_minutes + 1440;
    end if;
    v_elapsed_minutes := v_elapsed_minutes - p_lunch_minutes;
    if v_elapsed_minutes < 0 then
      raise exception using errcode='22023', message='Lunch cannot exceed the elapsed shift time.';
    end if;
    v_worked_hours := round((v_elapsed_minutes / 60.0)::numeric, 2);
  else
    v_worked_hours := greatest(0, least(24, coalesce(p_regular_hours,0) + coalesce(p_overtime_hours,0)));
  end if;

  if v_worked_hours > 24 then
    raise exception using errcode='22023', message='Worked hours cannot exceed 24 hours.';
  end if;

  v_before := jsonb_build_object(
    'start_time',v_entry.start_time,'stop_time',v_entry.stop_time,'lunch_minutes',v_entry.lunch_minutes,
    'regular_hours',v_entry.regular_hours,'overtime_hours',v_entry.overtime_hours,'per_diem',v_entry.per_diem,
    'equipment_used',v_entry.equipment_used,'equipment_not_used',v_entry.equipment_not_used
  );

  update public.timekeeping_entries e
  set start_time=p_start_time,
      stop_time=p_stop_time,
      lunch_minutes=p_lunch_minutes,
      regular_hours=v_worked_hours,
      overtime_hours=0,
      per_diem=coalesce(p_per_diem,false),
      equipment_used=case when coalesce(p_equipment_not_used,false) then null else nullif(btrim(coalesce(p_equipment_used,'')),'') end,
      equipment_not_used=coalesce(p_equipment_not_used,false),
      updated_by=auth.uid(),
      updated_at=now()
  where e.id=v_entry.id;

  perform public.recalculate_timekeeping_employee_week(p_daily_report_id,p_employee_id);

  select e.* into v_entry from public.timekeeping_entries e where e.id=v_entry.id;
  v_after := jsonb_build_object(
    'start_time',v_entry.start_time,'stop_time',v_entry.stop_time,'lunch_minutes',v_entry.lunch_minutes,
    'regular_hours',v_entry.regular_hours,'overtime_hours',v_entry.overtime_hours,'per_diem',v_entry.per_diem,
    'equipment_used',v_entry.equipment_used,'equipment_not_used',v_entry.equipment_not_used
  );

  insert into public.timekeeping_edit_audit(
    company_id,timekeeping_entry_id,daily_report_id,employee_id,work_date,edited_by,reason,before_values,after_values
  ) values (
    v_entry.company_id,v_entry.id,v_entry.daily_report_id,v_entry.employee_id,v_entry.work_date,auth.uid(),nullif(btrim(coalesce(p_reason,'')),''),v_before,v_after
  );
end;
$$;

revoke all on function public.admin_update_timekeeping_entry(uuid,uuid,time without time zone,time without time zone,integer,numeric,numeric,boolean,text,boolean,text) from public, anon;
grant execute on function public.admin_update_timekeeping_entry(uuid,uuid,time without time zone,time without time zone,integer,numeric,numeric,boolean,text,boolean,text) to authenticated;

commit;
