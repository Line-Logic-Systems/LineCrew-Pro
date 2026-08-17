begin;

alter table public.companies
  add column if not exists storm_mode_enabled boolean not null default false,
  add column if not exists storm_event_name text,
  add column if not exists storm_started_at timestamptz,
  add column if not exists storm_ended_at timestamptz;

alter table public.daily_reports
  add column if not exists storm_mode boolean not null default false,
  add column if not exists storm_event_name text;

create table if not exists public.daily_report_jsas (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  daily_report_id uuid not null unique references public.daily_reports(id) on delete cascade,
  job_id uuid not null references public.jobs(id) on delete cascade,
  created_by uuid not null references auth.users(id) on delete restrict,
  work_date date not null,
  crew_name text,
  job_briefing text not null,
  hazards text not null,
  controls text not null,
  ppe text not null,
  emergency_plan text not null,
  weather_conditions text,
  special_equipment text,
  crew_members text not null,
  foreman_acknowledged boolean not null default false,
  acknowledged_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint daily_report_jsas_job_briefing_not_blank check (length(trim(job_briefing)) > 0),
  constraint daily_report_jsas_hazards_not_blank check (length(trim(hazards)) > 0),
  constraint daily_report_jsas_controls_not_blank check (length(trim(controls)) > 0),
  constraint daily_report_jsas_ppe_not_blank check (length(trim(ppe)) > 0),
  constraint daily_report_jsas_emergency_plan_not_blank check (length(trim(emergency_plan)) > 0),
  constraint daily_report_jsas_crew_members_not_blank check (length(trim(crew_members)) > 0)
);

create index if not exists daily_report_jsas_company_work_date_idx
  on public.daily_report_jsas(company_id, work_date desc);

alter table public.daily_report_jsas enable row level security;

drop policy if exists daily_report_jsas_same_company_select on public.daily_report_jsas;
create policy daily_report_jsas_same_company_select
on public.daily_report_jsas
for select
to authenticated
using (
  company_id = (
    select p.company_id
    from public.profiles p
    where p.id = auth.uid()
  )
);

revoke all on table public.daily_report_jsas from public, anon;
grant select on table public.daily_report_jsas to authenticated;

create or replace function public.set_company_storm_mode(
  p_enabled boolean,
  p_event_name text default null
)
returns table (
  storm_mode_enabled boolean,
  storm_event_name text,
  storm_started_at timestamptz,
  storm_ended_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
begin
  select p.company_id, lower(coalesce(p.role, ''))
    into v_company_id, v_role
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_role <> 'admin' then
    raise exception using errcode = '42501',
      message = 'Only a company Admin can change Storm Mode.';
  end if;

  if coalesce(p_enabled, false) and length(trim(coalesce(p_event_name, ''))) = 0 then
    raise exception using errcode = '22023',
      message = 'A storm or event name is required when Storm Mode is enabled.';
  end if;

  update public.companies c
  set storm_mode_enabled = coalesce(p_enabled, false),
      storm_event_name = case when coalesce(p_enabled, false)
        then trim(p_event_name) else null end,
      storm_started_at = case
        when coalesce(p_enabled, false) and not c.storm_mode_enabled then now()
        when coalesce(p_enabled, false) then c.storm_started_at
        else c.storm_started_at end,
      storm_ended_at = case
        when not coalesce(p_enabled, false) and c.storm_mode_enabled then now()
        when coalesce(p_enabled, false) then null
        else c.storm_ended_at end
  where c.id = v_company_id;

  return query
  select c.storm_mode_enabled, c.storm_event_name,
         c.storm_started_at, c.storm_ended_at
  from public.companies c
  where c.id = v_company_id;
end;
$$;

create or replace function public.set_daily_report_storm_context(
  p_report_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_report_created_by uuid;
  v_enabled boolean;
  v_event_name text;
begin
  select p.company_id, lower(coalesce(p.role, ''))
    into v_company_id, v_role
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_role not in ('foreman','gf','admin') then
    raise exception using errcode = '42501',
      message = 'You are not allowed to update this daily report.';
  end if;

  select dr.created_by
    into v_report_created_by
  from public.daily_reports dr
  where dr.id = p_report_id
    and dr.company_id = v_company_id;

  if v_report_created_by is null then
    raise exception using errcode = 'P0002',
      message = 'Daily report was not found for your company.';
  end if;

  if v_role = 'foreman' and v_report_created_by <> auth.uid() then
    raise exception using errcode = '42501',
      message = 'Foremen may only update their own daily reports.';
  end if;

  select c.storm_mode_enabled, c.storm_event_name
    into v_enabled, v_event_name
  from public.companies c
  where c.id = v_company_id;

  update public.daily_reports
  set storm_mode = coalesce(v_enabled, false),
      storm_event_name = case when coalesce(v_enabled, false)
        then v_event_name else null end
  where id = p_report_id
    and company_id = v_company_id;
end;
$$;

create or replace function public.save_daily_report_jsa(
  p_report_id uuid,
  p_job_briefing text,
  p_hazards text,
  p_controls text,
  p_ppe text,
  p_emergency_plan text,
  p_crew_members text,
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
  v_job_id uuid;
  v_created_by uuid;
  v_work_date date;
  v_crew_name text;
  v_weather text;
  v_jsa_id uuid;
begin
  select p.company_id, lower(coalesce(p.role, ''))
    into v_company_id, v_role
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_role not in ('foreman','gf','admin') then
    raise exception using errcode = '42501',
      message = 'You are not allowed to save a JSA.';
  end if;

  select dr.job_id, dr.created_by, dr.work_date, dr.crew_name, dr.weather_conditions
    into v_job_id, v_created_by, v_work_date, v_crew_name, v_weather
  from public.daily_reports dr
  where dr.id = p_report_id
    and dr.company_id = v_company_id
    and lower(coalesce(dr.status, 'draft')) = 'draft';

  if v_job_id is null then
    raise exception using errcode = 'P0002',
      message = 'An editable daily report was not found for your company.';
  end if;

  if v_role = 'foreman' and v_created_by <> auth.uid() then
    raise exception using errcode = '42501',
      message = 'Foremen may only save a JSA for their own daily reports.';
  end if;

  if length(trim(coalesce(p_job_briefing, ''))) = 0
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
    company_id, daily_report_id, job_id, created_by, work_date, crew_name,
    job_briefing, hazards, controls, ppe, emergency_plan, weather_conditions,
    special_equipment, crew_members, foreman_acknowledged, acknowledged_at,
    updated_at
  ) values (
    v_company_id, p_report_id, v_job_id, auth.uid(), v_work_date, v_crew_name,
    trim(p_job_briefing), trim(p_hazards), trim(p_controls), trim(p_ppe),
    trim(p_emergency_plan), v_weather, nullif(trim(coalesce(p_special_equipment,'')), ''),
    trim(p_crew_members), true, now(), now()
  )
  on conflict (daily_report_id) do update set
    job_id = excluded.job_id,
    work_date = excluded.work_date,
    crew_name = excluded.crew_name,
    job_briefing = excluded.job_briefing,
    hazards = excluded.hazards,
    controls = excluded.controls,
    ppe = excluded.ppe,
    emergency_plan = excluded.emergency_plan,
    weather_conditions = excluded.weather_conditions,
    special_equipment = excluded.special_equipment,
    crew_members = excluded.crew_members,
    foreman_acknowledged = excluded.foreman_acknowledged,
    acknowledged_at = now(),
    updated_at = now()
  returning id into v_jsa_id;

  return v_jsa_id;
end;
$$;

create or replace function public.get_daily_report_jsa(
  p_report_id uuid
)
returns table (
  id uuid,
  daily_report_id uuid,
  job_briefing text,
  hazards text,
  controls text,
  ppe text,
  emergency_plan text,
  crew_members text,
  special_equipment text,
  foreman_acknowledged boolean,
  acknowledged_at timestamptz,
  updated_at timestamptz
)
language sql
security definer
set search_path = ''
stable
as $$
  select j.id, j.daily_report_id, j.job_briefing, j.hazards, j.controls,
         j.ppe, j.emergency_plan, j.crew_members, j.special_equipment,
         j.foreman_acknowledged, j.acknowledged_at, j.updated_at
  from public.daily_report_jsas j
  join public.profiles p
    on p.id = auth.uid()
   and p.company_id = j.company_id
  join public.daily_reports dr
    on dr.id = j.daily_report_id
   and dr.company_id = j.company_id
  where j.daily_report_id = p_report_id
    and (
      lower(coalesce(p.role,'')) in ('admin','gf')
      or dr.created_by = auth.uid()
    );
$$;

revoke all on function public.set_company_storm_mode(boolean, text) from public, anon;
revoke all on function public.set_daily_report_storm_context(uuid) from public, anon;
revoke all on function public.save_daily_report_jsa(uuid, text, text, text, text, text, text, text, boolean) from public, anon;
revoke all on function public.get_daily_report_jsa(uuid) from public, anon;

grant execute on function public.set_company_storm_mode(boolean, text) to authenticated;
grant execute on function public.set_daily_report_storm_context(uuid) to authenticated;
grant execute on function public.save_daily_report_jsa(uuid, text, text, text, text, text, text, text, boolean) to authenticated;
grant execute on function public.get_daily_report_jsa(uuid) to authenticated;

commit;
