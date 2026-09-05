create table if not exists public.gf_foreman_assignments (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  gf_id uuid not null references public.profiles(id) on delete cascade,
  foreman_id uuid not null references public.profiles(id) on delete cascade,
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint gf_foreman_assignments_one_primary_gf unique (company_id, foreman_id)
);

create index if not exists gf_foreman_assignments_gf_idx
  on public.gf_foreman_assignments(company_id, gf_id);

alter table public.gf_foreman_assignments enable row level security;
revoke all on public.gf_foreman_assignments from anon, authenticated;

create or replace function public.get_gf_crew_assignment_roster()
returns table(foreman_id uuid, foreman_name text, gf_id uuid, gf_name text)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  select p.company_id, lower(coalesce(p.role,'')), p.active
    into v_company_id, v_role, v_active
  from public.profiles p where p.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin','owner','gf','superintendent') then
    raise exception using errcode='42501', message='Company leadership access is required.';
  end if;

  return query
  select f.id,
         coalesce(nullif(trim(f.full_name),''),'Foreman'),
         a.gf_id,
         coalesce(nullif(trim(g.full_name),''),'General Foreman')
  from public.profiles f
  left join public.gf_foreman_assignments a
    on a.company_id = v_company_id and a.foreman_id = f.id
  left join public.profiles g
    on g.id = a.gf_id and g.company_id = v_company_id
  where f.company_id = v_company_id
    and f.active is true
    and lower(coalesce(f.role,'')) = 'foreman'
  order by coalesce(nullif(trim(f.full_name),''),'Foreman');
end;
$$;

create or replace function public.get_company_general_foremen()
returns table(id uuid, full_name text)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  select p.company_id, lower(coalesce(p.role,'')), p.active
    into v_company_id, v_role, v_active
  from public.profiles p where p.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin','owner','gf','superintendent') then
    raise exception using errcode='42501', message='Company leadership access is required.';
  end if;

  return query
  select p.id, coalesce(nullif(trim(p.full_name),''),'General Foreman')
  from public.profiles p
  where p.company_id = v_company_id
    and p.active is true
    and lower(coalesce(p.role,'')) = 'gf'
  order by coalesce(nullif(trim(p.full_name),''),'General Foreman');
end;
$$;

create or replace function public.set_gf_crew_assignment(p_foreman_id uuid, p_gf_id uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_foreman_ok boolean;
  v_gf_ok boolean;
begin
  select p.company_id, lower(coalesce(p.role,'')), p.active
    into v_company_id, v_role, v_active
  from public.profiles p where p.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role not in ('admin','owner') then
    raise exception using errcode='42501', message='Only an Owner or Admin can assign Foreman crews to General Foremen.';
  end if;

  select exists(
    select 1 from public.profiles p
    where p.id = p_foreman_id
      and p.company_id = v_company_id
      and p.active is true
      and lower(coalesce(p.role,'')) = 'foreman'
  ) into v_foreman_ok;

  if not v_foreman_ok then
    raise exception using errcode='22023', message='The selected Foreman is not an active Foreman in your company.';
  end if;

  if p_gf_id is null then
    delete from public.gf_foreman_assignments a
    where a.company_id = v_company_id and a.foreman_id = p_foreman_id;
    return;
  end if;

  select exists(
    select 1 from public.profiles p
    where p.id = p_gf_id
      and p.company_id = v_company_id
      and p.active is true
      and lower(coalesce(p.role,'')) = 'gf'
  ) into v_gf_ok;

  if not v_gf_ok then
    raise exception using errcode='22023', message='The selected General Foreman is not active in your company.';
  end if;

  insert into public.gf_foreman_assignments(company_id,gf_id,foreman_id,created_by,updated_at)
  values(v_company_id,p_gf_id,p_foreman_id,auth.uid(),now())
  on conflict (company_id,foreman_id)
  do update set gf_id=excluded.gf_id, updated_at=now();
end;
$$;

create or replace function public.get_company_jsas_scoped(p_show_all boolean default false)
returns table(
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
  created_at timestamptz,
  foreman_id uuid
)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_has_assignments boolean := false;
begin
  select p.company_id, lower(coalesce(p.role,'')), p.active
    into v_company_id, v_role, v_active
  from public.profiles p where p.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('foreman','gf','admin','owner','superintendent') then
    raise exception using errcode='42501', message='You are not allowed to view JSAs.';
  end if;

  if v_role = 'superintendent' and not public.linecrew_has_capability('safety_records') then
    raise exception using errcode='42501', message='This Superintendent does not have safety records permission.';
  end if;

  if v_role = 'gf' then
    select exists(
      select 1 from public.gf_foreman_assignments a
      where a.company_id = v_company_id and a.gf_id = auth.uid()
    ) into v_has_assignments;
  end if;

  return query
  select safety.id,
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
         coalesce(nullif(trim(profile.full_name),''),'Foreman'),
         safety.acknowledged_at,
         safety.created_at,
         safety.created_by
  from public.daily_report_jsas safety
  join public.jobs job
    on job.id = safety.job_id and job.company_id = safety.company_id
  left join public.profiles profile
    on profile.id = safety.created_by and profile.company_id = safety.company_id
  where safety.company_id = v_company_id
    and (
      (v_role = 'foreman' and safety.created_by = auth.uid())
      or v_role in ('admin','owner','superintendent')
      or (
        v_role = 'gf' and (
          coalesce(p_show_all,false)
          or not v_has_assignments
          or exists(
            select 1 from public.gf_foreman_assignments a
            where a.company_id = v_company_id
              and a.gf_id = auth.uid()
              and a.foreman_id = safety.created_by
          )
        )
      )
    )
  order by safety.work_date desc, safety.created_at desc;
end;
$$;

revoke all on function public.get_gf_crew_assignment_roster() from public, anon;
revoke all on function public.get_company_general_foremen() from public, anon;
revoke all on function public.set_gf_crew_assignment(uuid,uuid) from public, anon;
revoke all on function public.get_company_jsas_scoped(boolean) from public, anon;

grant execute on function public.get_gf_crew_assignment_roster() to authenticated, service_role;
grant execute on function public.get_company_general_foremen() to authenticated, service_role;
grant execute on function public.set_gf_crew_assignment(uuid,uuid) to authenticated, service_role;
grant execute on function public.get_company_jsas_scoped(boolean) to authenticated, service_role;
