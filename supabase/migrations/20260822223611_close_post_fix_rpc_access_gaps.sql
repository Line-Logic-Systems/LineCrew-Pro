begin;

-- Keep the Contracts screen aligned with the frontend customers_contracts
-- capability. Owner/Admin always have access; Superintendent access remains
-- explicitly capability-gated and every result is company-scoped.
create or replace function public.get_contract_field_settings()
returns table (
  contract_id uuid,
  field_value_percent numeric
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_profile_active boolean;
begin
  select p.company_id, lower(coalesce(p.role, '')), p.active
  into v_company_id, v_role, v_profile_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_profile_active is not true or not (
    v_role in ('admin', 'owner')
    or (
      v_role = 'superintendent'
      and public.linecrew_has_capability('customers_contracts')
    )
  ) then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to view Field Value settings.';
  end if;

  return query
  select s.contract_id, s.field_value_percent
  from public.contract_field_settings s
  where s.company_id = v_company_id;
end;
$$;

revoke all on function public.get_contract_field_settings() from public, anon, authenticated;
grant execute on function public.get_contract_field_settings() to authenticated;

-- This RPC currently has no frontend caller, but keeping it makes the API
-- consistent with daily_report_jsas_role_scoped_select. It remains company-
-- scoped, rejects suspended profiles, and requires safety_records for a
-- Superintendent.
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
stable
security definer
set search_path = ''
as $$
  select j.id, j.daily_report_id, j.job_briefing, j.hazards, j.controls,
         j.ppe, j.emergency_plan, j.crew_members, j.special_equipment,
         j.foreman_acknowledged, j.acknowledged_at, j.updated_at
  from public.daily_report_jsas j
  join public.profiles p
    on p.id = auth.uid()
   and p.active is true
   and p.company_id = j.company_id
  join public.daily_reports dr
    on dr.id = j.daily_report_id
   and dr.company_id = j.company_id
  where j.daily_report_id = p_report_id
    and (
      lower(coalesce(p.role, '')) in ('admin', 'gf', 'owner')
      or (
        lower(coalesce(p.role, '')) = 'superintendent'
        and public.linecrew_has_capability('safety_records')
      )
      or dr.created_by = auth.uid()
    );
$$;

revoke all on function public.get_daily_report_jsa(uuid) from public, anon, authenticated;
grant execute on function public.get_daily_report_jsa(uuid) to authenticated;

do $$
declare
  v_contract_settings_definition text;
  v_jsa_definition text;
begin
  select pg_get_functiondef('public.get_contract_field_settings()'::regprocedure)
  into v_contract_settings_definition;

  select pg_get_functiondef('public.get_daily_report_jsa(uuid)'::regprocedure)
  into v_jsa_definition;

  if v_contract_settings_definition not like '%customers_contracts%' or
     v_contract_settings_definition not like '%superintendent%' then
    raise exception 'Contract Field Value access compatibility was not installed.';
  end if;

  if v_jsa_definition not like '%safety_records%' or
     v_jsa_definition not like '%p.active is true%' then
    raise exception 'Daily-report JSA access compatibility was not installed.';
  end if;

  if has_function_privilege('anon', 'public.get_contract_field_settings()', 'execute') or
     has_function_privilege('anon', 'public.get_daily_report_jsa(uuid)', 'execute') then
    raise exception 'Anonymous RPC execution must remain disabled.';
  end if;
end;
$$;

notify pgrst, 'reload schema';

commit;
