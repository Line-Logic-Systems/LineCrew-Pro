begin;

create or replace function public.update_my_profile_name(p_full_name text)
returns table(id uuid, full_name text, role text, company_id uuid)
language plpgsql security definer set search_path = ''
as $function$
declare
  v_name text := btrim(coalesce(p_full_name, ''));
begin
  if auth.uid() is null then
    raise exception using errcode='42501', message='Authentication required.';
  end if;
  if length(v_name) < 2 or length(v_name) > 120 then
    raise exception using errcode='22023',
      message='Display name must be between 2 and 120 characters.';
  end if;

  perform set_config('linecrew.profile_name_sync', auth.uid()::text, true);

  return query
  update public.profiles profile
     set full_name = v_name
   where profile.id = auth.uid() and profile.active is true
  returning profile.id, profile.full_name, profile.role, profile.company_id;
end;
$function$;

revoke all on function public.update_my_profile_name(text) from public, anon;
grant execute on function public.update_my_profile_name(text) to authenticated, service_role;

create or replace function public.validate_timekeeping_employee_assignment()
returns trigger
language plpgsql security definer set search_path = ''
as $function$
declare
  v_actor_company uuid;
  v_actor_role text;
  v_trusted_profile_sync boolean := false;
begin
  if auth.uid() is null then
    if new.assigned_foreman_id is not null and not exists (
      select 1 from public.profiles foreman
       where foreman.id = new.assigned_foreman_id
         and foreman.company_id = new.company_id
         and foreman.active is true
         and lower(coalesce(foreman.role, '')) = 'foreman'
    ) then
      raise exception using errcode='23514',
        message='The assigned Foreman must be an active Foreman in this company.';
    end if;
    new.updated_at := now();
    return new;
  end if;

  select p.company_id, lower(coalesce(p.role, ''))
    into v_actor_company, v_actor_role
    from public.profiles p
   where p.id = auth.uid() and p.active is true;

  v_trusted_profile_sync :=
    current_setting('linecrew.profile_name_sync', true) = auth.uid()::text
    and v_actor_company is not null
    and new.company_id = v_actor_company
    and new.linked_profile_id = auth.uid()
    and (new.assigned_foreman_id is null or new.assigned_foreman_id = auth.uid());

  -- BEFORE INSERT fires before ON CONFLICT resolves, so permit both stages of
  -- the automatic self-roster sync only inside update_my_profile_name.
  if v_trusted_profile_sync and (
    tg_op = 'INSERT'
    or (
      tg_op = 'UPDATE'
      and old.company_id = new.company_id
      and old.linked_profile_id = auth.uid()
    )
  ) then
    new.updated_at := now();
    return new;
  end if;

  if v_actor_company is null
     or v_actor_company <> new.company_id
     or v_actor_role not in ('owner', 'admin', 'gf') then
    raise exception using errcode='42501',
      message='Only an active Owner, Admin, or General Foreman can manage field employees.';
  end if;

  if new.assigned_foreman_id is not null and not exists (
    select 1 from public.profiles foreman
     where foreman.id = new.assigned_foreman_id
       and foreman.company_id = new.company_id
       and foreman.active is true
       and lower(coalesce(foreman.role, '')) = 'foreman'
  ) then
    raise exception using errcode='23514',
      message='The assigned Foreman must be an active Foreman in this company.';
  end if;

  if tg_op = 'INSERT'
     or new.assigned_foreman_id is distinct from old.assigned_foreman_id then
    new.assigned_by := case when new.assigned_foreman_id is null then null else auth.uid() end;
    new.assigned_at := case when new.assigned_foreman_id is null then null else now() end;
  end if;

  new.updated_at := now();
  return new;
end;
$function$;

create or replace function public.create_standalone_jsa(
  p_job_id uuid,
  p_work_date date,
  p_crew_name text,
  p_job_briefing text,
  p_hazards text,
  p_controls text,
  p_ppe text,
  p_emergency_plan text,
  p_crew_members text,
  p_weather_conditions text default null,
  p_special_equipment text default null,
  p_foreman_acknowledged boolean default false
)
returns uuid
language plpgsql security definer set search_path = ''
as $function$
declare
  v_company_id uuid;
  v_role text;
  v_jsa_id uuid;
begin
  select p.company_id, lower(coalesce(p.role, ''))
    into v_company_id, v_role
    from public.profiles p
   where p.id = auth.uid() and p.active is true;

  if v_company_id is null
     or v_role not in ('foreman','gf','admin','owner','superintendent') then
    raise exception using errcode='42501',
      message='You are not allowed to complete a JSA.';
  end if;

  if v_role = 'superintendent'
     and not public.linecrew_has_capability('safety_records') then
    raise exception using errcode='42501',
      message='This Superintendent does not have safety records permission.';
  end if;

  if not exists (
    select 1 from public.jobs j
     where j.id = p_job_id
       and j.company_id = v_company_id
       and coalesce(j.active, true) is true
       and (
         v_role <> 'foreman'
         or public.linecrew_foreman_has_job_assignment(j.id)
       )
  ) then
    raise exception using errcode='P0002',
      message='An active assigned job was not found for your company.';
  end if;

  if p_work_date is null
     or length(trim(coalesce(p_crew_name,''))) = 0
     or length(trim(coalesce(p_job_briefing,''))) = 0
     or length(trim(coalesce(p_hazards,''))) = 0
     or length(trim(coalesce(p_controls,''))) = 0
     or length(trim(coalesce(p_ppe,''))) = 0
     or length(trim(coalesce(p_emergency_plan,''))) = 0
     or length(trim(coalesce(p_crew_members,''))) = 0 then
    raise exception using errcode='22023',
      message='All required JSA fields must be completed.';
  end if;

  if not coalesce(p_foreman_acknowledged, false) then
    raise exception using errcode='22023',
      message='The Foreman must acknowledge the crew safety briefing.';
  end if;

  insert into public.daily_report_jsas (
    company_id, daily_report_id, job_id, created_by, work_date, crew_name,
    job_briefing, hazards, controls, ppe, emergency_plan, weather_conditions,
    special_equipment, crew_members, foreman_acknowledged, acknowledged_at,
    updated_at
  ) values (
    v_company_id, null, p_job_id, auth.uid(), p_work_date, trim(p_crew_name),
    trim(p_job_briefing), trim(p_hazards), trim(p_controls), trim(p_ppe),
    trim(p_emergency_plan),
    nullif(trim(coalesce(p_weather_conditions,'')), ''),
    nullif(trim(coalesce(p_special_equipment,'')), ''),
    trim(p_crew_members), true, now(), now()
  )
  returning id into v_jsa_id;

  return v_jsa_id;
end;
$function$;

revoke all on function public.create_standalone_jsa(
  uuid,date,text,text,text,text,text,text,text,text,text,boolean
) from public, anon;
grant execute on function public.create_standalone_jsa(
  uuid,date,text,text,text,text,text,text,text,text,text,boolean
) to authenticated, service_role;

commit;
