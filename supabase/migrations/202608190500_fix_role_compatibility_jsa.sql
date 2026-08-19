-- Compatibility correction: jobs uses the `active` boolean, not a `status` column.
-- Keep Owner support and gate Superintendent access with safety_records.

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
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_jsa_id uuid;
begin
  select p.company_id, lower(coalesce(p.role, '')), p.active
    into v_company_id, v_role, v_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('foreman', 'gf', 'admin', 'owner', 'superintendent') then
    raise exception using errcode = '42501',
      message = 'You are not allowed to complete a JSA.';
  end if;

  if v_role = 'superintendent' and
     not public.linecrew_has_capability('safety_records') then
    raise exception using errcode = '42501',
      message = 'This Superintendent does not have safety records permission.';
  end if;

  if not exists (
    select 1
    from public.jobs j
    where j.id = p_job_id
      and j.company_id = v_company_id
      and coalesce(j.active, true) = true
  ) then
    raise exception using errcode = 'P0002',
      message = 'An active job was not found for your company.';
  end if;

  if p_work_date is null
    or length(trim(coalesce(p_crew_name, ''))) = 0
    or length(trim(coalesce(p_job_briefing, ''))) = 0
    or length(trim(coalesce(p_hazards, ''))) = 0
    or length(trim(coalesce(p_controls, ''))) = 0
    or length(trim(coalesce(p_ppe, ''))) = 0
    or length(trim(coalesce(p_emergency_plan, ''))) = 0
    or length(trim(coalesce(p_crew_members, ''))) = 0 then
    raise exception using errcode = '22023',
      message = 'All required JSA fields must be completed.';
  end if;

  if not coalesce(p_foreman_acknowledged, false) then
    raise exception using errcode = '22023',
      message = 'The Foreman must acknowledge the crew safety briefing.';
  end if;

  insert into public.daily_report_jsas (
    company_id,
    daily_report_id,
    job_id,
    created_by,
    work_date,
    crew_name,
    job_briefing,
    hazards,
    controls,
    ppe,
    emergency_plan,
    weather_conditions,
    special_equipment,
    crew_members,
    foreman_acknowledged,
    acknowledged_at,
    updated_at
  ) values (
    v_company_id,
    null,
    p_job_id,
    auth.uid(),
    p_work_date,
    trim(p_crew_name),
    trim(p_job_briefing),
    trim(p_hazards),
    trim(p_controls),
    trim(p_ppe),
    trim(p_emergency_plan),
    nullif(trim(coalesce(p_weather_conditions, '')), ''),
    nullif(trim(coalesce(p_special_equipment, '')), ''),
    trim(p_crew_members),
    true,
    now(),
    now()
  )
  returning id into v_jsa_id;

  return v_jsa_id;
end;
$$;

revoke all on function public.create_standalone_jsa(uuid,date,text,text,text,text,text,text,text,text,text,boolean) from public;
revoke all on function public.create_standalone_jsa(uuid,date,text,text,text,text,text,text,text,text,text,boolean) from anon;
grant execute on function public.create_standalone_jsa(uuid,date,text,text,text,text,text,text,text,text,text,boolean) to authenticated;
