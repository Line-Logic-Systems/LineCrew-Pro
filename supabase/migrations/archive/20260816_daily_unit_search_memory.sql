begin;

create or replace function public.get_daily_unit_usage_memory(
  p_report_id uuid
)
returns table (
  item_code text,
  use_count bigint,
  last_used timestamptz
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
  v_report_company_id uuid;
  v_report_creator uuid;
  v_contract_id uuid;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_profile_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_profile_active is not true or
     v_role not in ('foreman', 'gf', 'admin') then
    raise exception using
      errcode = '42501',
      message = 'An active Foreman, General Foreman or Admin profile is required.';
  end if;

  select report.company_id, report.created_by, job.contract_id
  into v_report_company_id, v_report_creator, v_contract_id
  from public.daily_reports report
  join public.jobs job
    on job.id = report.job_id
   and job.company_id = report.company_id
  where report.id = p_report_id;

  if v_report_company_id is null or v_report_company_id <> v_company_id then
    raise exception using
      errcode = 'P0002',
      message = 'Daily report was not found in your company.';
  end if;

  if v_role = 'foreman' and v_report_creator is distinct from auth.uid() then
    raise exception using
      errcode = '42501',
      message = 'Foremen can access search memory only for their own reports.';
  end if;

  if v_contract_id is null then
    return;
  end if;

  return query
  select
    min(aggregate_line.item_code),
    count(location_line.id),
    max(location_line.updated_at)
  from public.daily_production_unit_locations location_line
  join public.daily_production_units aggregate_line
    on aggregate_line.id = location_line.daily_production_unit_id
   and aggregate_line.company_id = location_line.company_id
   and aggregate_line.daily_report_id = location_line.daily_report_id
  join public.daily_reports historical_report
    on historical_report.id = location_line.daily_report_id
   and historical_report.company_id = location_line.company_id
  join public.jobs historical_job
    on historical_job.id = historical_report.job_id
   and historical_job.company_id = historical_report.company_id
  where location_line.company_id = v_company_id
    and location_line.created_by = auth.uid()
    and historical_job.contract_id = v_contract_id
  group by lower(btrim(aggregate_line.item_code));
end;
$$;

revoke all on function public.get_daily_unit_usage_memory(uuid) from public;
revoke all on function public.get_daily_unit_usage_memory(uuid) from anon;
grant execute on function public.get_daily_unit_usage_memory(uuid)
to authenticated;

commit;
