begin;

-- Morning JSAs are separate from end-of-day production reports.
-- Existing report-linked JSAs remain intact for historical reference.
alter table public.daily_report_jsas
  alter column daily_report_id drop not null;

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
  v_jsa_id uuid;
begin
  select p.company_id, lower(coalesce(p.role, ''))
    into v_company_id, v_role
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_role not in ('foreman', 'gf', 'admin') then
    raise exception using errcode = '42501',
      message = 'You are not allowed to complete a JSA.';
  end if;

  if not exists (
    select 1
    from public.jobs j
    where j.id = p_job_id
      and j.company_id = v_company_id
      and lower(coalesce(j.status, 'active')) = 'active'
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

create or replace function public.get_company_jsas()
returns table (
  id uuid,
  daily_report_id uuid,
  job_id uuid,
  job_number text,
  job_name text,
  work_date date,
  crew_name text,
  weather_conditions text,
  job_briefing text,
  hazards text,
  controls text,
  ppe text,
  emergency_plan text,
  crew_members text,
  special_equipment text,
  foreman_name text,
  acknowledged_at timestamptz,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = ''
stable
as $$
declare
  v_company_id uuid;
  v_role text;
begin
  select p.company_id, lower(coalesce(p.role, ''))
    into v_company_id, v_role
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_role not in ('foreman', 'gf', 'admin') then
    raise exception using errcode = '42501',
      message = 'You are not allowed to view JSAs.';
  end if;

  return query
  select
    safety.id,
    safety.daily_report_id,
    safety.job_id,
    job.job_number,
    job.job_name,
    safety.work_date,
    safety.crew_name,
    safety.weather_conditions,
    safety.job_briefing,
    safety.hazards,
    safety.controls,
    safety.ppe,
    safety.emergency_plan,
    safety.crew_members,
    safety.special_equipment,
    coalesce(nullif(trim(profile.full_name), ''), 'Foreman') as foreman_name,
    safety.acknowledged_at,
    safety.created_at
  from public.daily_report_jsas safety
  join public.jobs job
    on job.id = safety.job_id
   and job.company_id = safety.company_id
  left join public.profiles profile
    on profile.id = safety.created_by
   and profile.company_id = safety.company_id
  where safety.company_id = v_company_id
    and (
      v_role in ('gf', 'admin')
      or safety.created_by = auth.uid()
    )
  order by safety.work_date desc, safety.created_at desc;
end;
$$;

revoke all on function public.create_standalone_jsa(
  uuid, date, text, text, text, text, text, text, text, text, text, boolean
) from public, anon;
revoke all on function public.get_company_jsas() from public, anon;

grant execute on function public.create_standalone_jsa(
  uuid, date, text, text, text, text, text, text, text, text, text, boolean
) to authenticated;
grant execute on function public.get_company_jsas() to authenticated;

commit;
