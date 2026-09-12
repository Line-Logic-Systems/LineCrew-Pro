create or replace function public.set_daily_report_storm_context(p_report_id uuid)
returns void language plpgsql security definer set search_path=''
as $$
declare
  v_company_id uuid; v_role text; v_report_created_by uuid;
  v_context_set_at timestamptz; v_work_date date;
  v_enabled boolean; v_event_name text; v_assigned boolean;
  v_started_date date; v_ended_date date; v_timezone text; v_storm boolean;
begin
  select p.company_id,lower(coalesce(p.role,'')) into v_company_id,v_role
  from public.profiles p where p.id=auth.uid() and coalesce(p.active,true);
  if v_company_id is null or v_role not in ('foreman','gf','admin','manager','owner','superintendent') then
    raise exception using errcode='42501',message='You are not allowed to update this daily report.';
  end if;
  if v_role='superintendent' and not public.linecrew_has_capability('storm_mode') then
    raise exception using errcode='42501',message='This Superintendent does not have storm mode permission.';
  end if;

  select report.created_by,report.storm_context_set_at,report.work_date
    into v_report_created_by,v_context_set_at,v_work_date
  from public.daily_reports report
  where report.id=p_report_id and report.company_id=v_company_id
  for update;
  if v_report_created_by is null then
    raise exception using errcode='P0002',message='Daily report was not found for your company.';
  end if;
  if v_role='foreman' and v_report_created_by<>auth.uid() then
    raise exception using errcode='42501',message='Foremen may only update their own daily reports.';
  end if;
  if v_context_set_at is not null then return; end if;

  select company.storm_mode_enabled,company.storm_event_name,
    coalesce(nullif(company.timezone,''),'America/Chicago'),
    (company.storm_started_at at time zone coalesce(nullif(company.timezone,''),'America/Chicago'))::date,
    (company.storm_ended_at at time zone coalesce(nullif(company.timezone,''),'America/Chicago'))::date,
    exists(select 1 from public.storm_mode_assignments assignment
      where assignment.company_id=v_company_id and assignment.user_id=v_report_created_by)
  into v_enabled,v_event_name,v_timezone,v_started_date,v_ended_date,v_assigned
  from public.companies company where company.id=v_company_id;

  v_storm:=coalesce(v_enabled,false) and coalesce(v_assigned,false)
    and v_started_date is not null and v_work_date>=v_started_date
    and (v_ended_date is null or v_work_date<=v_ended_date);

  update public.daily_reports
  set storm_mode=v_storm,
      storm_event_name=case when v_storm then v_event_name else null end,
      storm_context_set_at=now()
  where id=p_report_id and company_id=v_company_id and storm_context_set_at is null;

  update public.timekeeping_entries entry set storm_work=v_storm,updated_at=now()
  where entry.company_id=v_company_id and entry.daily_report_id=p_report_id
    and entry.storm_work is distinct from v_storm;
end;
$$;

create or replace function public.reclassify_daily_report_storm_context(
  p_report_id uuid,p_storm_mode boolean,p_reason text,p_event_name text default null
)
returns void language plpgsql security definer set search_path=''
as $$
declare v_company_id uuid; v_role text; v_active boolean; v_report public.daily_reports%rowtype;
  v_reason text:=nullif(btrim(coalesce(p_reason,'')),''); v_event_name text;
begin
  select profile.company_id,lower(coalesce(profile.role,'')),profile.active
    into v_company_id,v_role,v_active from public.profiles profile where profile.id=auth.uid();
  if v_company_id is null or not v_active or v_role not in ('owner','admin','manager') then
    raise exception using errcode='42501',message='Company leadership access is required to reclassify Storm work.';
  end if;
  if v_reason is null then
    raise exception using errcode='22023',message='Enter a reason for changing the Storm classification.';
  end if;
  select report.* into v_report from public.daily_reports report
  where report.id=p_report_id and report.company_id=v_company_id for update;
  if not found then raise exception using errcode='P0002',message='Daily report was not found in your company.'; end if;
  select coalesce(nullif(btrim(p_event_name),''),nullif(btrim(company.storm_event_name),''),'Storm Event')
    into v_event_name from public.companies company where company.id=v_company_id;

  update public.daily_reports set storm_mode=coalesce(p_storm_mode,false),
    storm_event_name=case when coalesce(p_storm_mode,false) then v_event_name else null end,
    storm_context_set_at=now(),updated_at=now()
  where id=p_report_id and company_id=v_company_id;
  perform set_config('linecrew.allow_storm_reclassification','on',true);
  update public.timekeeping_entries entry set storm_work=coalesce(p_storm_mode,false),updated_at=now()
  where entry.company_id=v_company_id and entry.daily_report_id=p_report_id;

  insert into public.audit_log(company_id,user_id,action,table_name,record_id,old_data,new_data)
  values(v_company_id,auth.uid(),'daily_report_storm_reclassified','daily_reports',p_report_id,
    jsonb_build_object('storm_mode',v_report.storm_mode,'storm_event_name',v_report.storm_event_name),
    jsonb_build_object('storm_mode',coalesce(p_storm_mode,false),'storm_event_name',case when coalesce(p_storm_mode,false) then v_event_name else null end,'reason',v_reason));
end;
$$;

create or replace function public.guard_approved_daily_report_timekeeping()
returns trigger language plpgsql security definer set search_path=''
as $$
declare v_report_id uuid:=coalesce(new.daily_report_id,old.daily_report_id); v_status text;
begin
  if v_report_id is null then return coalesce(new,old); end if;
  select lower(coalesce(report.status,'draft')) into v_status
  from public.daily_reports report where report.id=v_report_id;
  if v_status<>'approved' then return coalesce(new,old); end if;
  if tg_op in ('INSERT','DELETE') then
    raise exception using errcode='23514',message='Approved Daily Report crew time is read-only. Reopen or return the report before changing time.';
  end if;
  if tg_op='UPDATE' and (
    new.daily_report_id is distinct from old.daily_report_id or new.employee_id is distinct from old.employee_id or
    new.job_id is distinct from old.job_id or new.work_date is distinct from old.work_date or
    new.regular_hours is distinct from old.regular_hours or new.overtime_hours is distinct from old.overtime_hours or
    new.start_time is distinct from old.start_time or new.stop_time is distinct from old.stop_time or
    new.lunch_minutes is distinct from old.lunch_minutes or new.per_diem is distinct from old.per_diem or
    new.equipment_used is distinct from old.equipment_used or new.equipment_not_used is distinct from old.equipment_not_used or
    (new.storm_work is distinct from old.storm_work and
      coalesce(current_setting('linecrew.allow_storm_reclassification',true),'')<>'on')
  ) then
    raise exception using errcode='23514',message='Approved Daily Report crew time is read-only. Reopen or return the report before changing time.';
  end if;
  return coalesce(new,old);
end;
$$;

revoke all on function public.set_daily_report_storm_context(uuid) from public,anon;
grant execute on function public.set_daily_report_storm_context(uuid) to authenticated,service_role;
revoke all on function public.reclassify_daily_report_storm_context(uuid,boolean,text,text) from public,anon;
grant execute on function public.reclassify_daily_report_storm_context(uuid,boolean,text,text) to authenticated,service_role;

comment on function public.reclassify_daily_report_storm_context(uuid,boolean,text,text) is
  'Owner/Admin/Manager audited correction path for an already-latched Daily Report Storm classification.';
