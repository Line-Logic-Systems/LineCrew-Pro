create or replace function public.get_company_jsas_scoped(p_show_all boolean default false)
returns table(id uuid, daily_report_id uuid, job_id uuid, job_number text, job_name text, work_date date, crew_name text, weather_conditions text, job_briefing text, hazards text, controls text, ppe text, emergency_plan text, crew_members text, special_equipment text, foreman_name text, acknowledged_at timestamp with time zone, created_at timestamp with time zone, foreman_id uuid, details jsonb)
language plpgsql
stable security definer
set search_path to ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_has_assignments boolean := false;
begin
  select p.company_id,lower(coalesce(p.role,'')),p.active
  into v_company_id,v_role,v_active
  from public.profiles p
  where p.id=(select auth.uid());

  if v_company_id is null or v_active is not true or
     v_role not in ('foreman','gf','admin','manager','owner','superintendent','safety') then
    raise exception using errcode='42501', message='You are not allowed to view JSAs.';
  end if;

  if v_role='superintendent' and not public.linecrew_has_capability('safety_records') then
    raise exception using errcode='42501', message='This Superintendent does not have safety records permission.';
  end if;

  if v_role='gf' then
    select exists(
      select 1 from public.gf_foreman_assignments a
      where a.company_id=v_company_id and a.gf_id=(select auth.uid())
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
         safety.created_by,
         coalesce(safety.details,'{}'::jsonb)
  from public.daily_report_jsas safety
  join public.jobs job
    on job.id=safety.job_id and job.company_id=safety.company_id
  left join public.profiles profile
    on profile.id=safety.created_by and profile.company_id=safety.company_id
  where safety.company_id=v_company_id
    and coalesce(safety.jsa_source,'digital')='digital'
    and (
      (v_role='foreman' and safety.created_by=(select auth.uid()))
      or v_role in ('admin','manager','owner','superintendent','safety')
      or (
        v_role='gf' and (
          coalesce(p_show_all,false)
          or not v_has_assignments
          or exists(
            select 1 from public.gf_foreman_assignments a
            where a.company_id=v_company_id
              and a.gf_id=(select auth.uid())
              and a.foreman_id=safety.created_by
          )
        )
      )
    )
  order by safety.work_date desc,safety.created_at desc;
end;
$$;

revoke all on function public.get_company_jsas_scoped(boolean) from public, anon;
grant execute on function public.get_company_jsas_scoped(boolean) to authenticated, service_role;
