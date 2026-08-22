create or replace function public.get_daily_report_value_summaries()
returns table(report_id uuid, unit_line_count bigint, actual_total numeric, adjusted_total numeric, visible_total numeric, has_adjustment boolean)
language plpgsql
stable security definer
set search_path to ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_profile_active boolean;
  v_role_permissions jsonb;
  v_can_see_actual boolean;
begin
  select p.company_id, lower(coalesce(p.role, '')), p.active, coalesce(p.role_permissions, '{}'::jsonb)
  into v_company_id, v_role, v_profile_active, v_role_permissions
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_profile_active is not true or
     v_role not in ('foreman', 'gf', 'superintendent', 'admin', 'owner') then
    raise exception using errcode = '42501',
      message = 'An active company production profile is required.';
  end if;

  v_can_see_actual := v_role in ('admin', 'owner', 'gf')
    or (v_role = 'superintendent' and coalesce((v_role_permissions->>'actual_contract_pricing')::boolean, true));

  return query
  select
    dr.id,
    count(line.id),
    case when v_can_see_actual then coalesce(sum(
      line.install_quantity * line.actual_install_price +
      line.retirement_quantity * line.actual_retirement_price
    ), 0) else null end,
    coalesce(sum(
      line.install_quantity * line.adjusted_install_price +
      line.retirement_quantity * line.adjusted_retirement_price
    ), 0),
    case when v_can_see_actual then coalesce(sum(
      line.install_quantity * line.actual_install_price +
      line.retirement_quantity * line.actual_retirement_price
    ), 0) else coalesce(sum(
      line.install_quantity * line.adjusted_install_price +
      line.retirement_quantity * line.adjusted_retirement_price
    ), 0) end,
    coalesce(bool_or(line.has_adjustment), false)
  from public.daily_reports dr
  left join public.daily_production_units line
    on line.daily_report_id = dr.id
   and line.company_id = dr.company_id
  where dr.company_id = v_company_id
    and (v_role in ('admin', 'owner', 'gf', 'superintendent') or dr.created_by = auth.uid())
  group by dr.id;
end;
$$;

create or replace function public.get_daily_report_authorization_summaries()
returns table(report_id uuid, unit_entry_count bigint, authorized_count bigint, pending_packet_count bigint, redline_count bigint)
language plpgsql
stable security definer
set search_path to ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_role_permissions jsonb;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active, coalesce(profile.role_permissions, '{}'::jsonb)
  into v_company_id, v_role, v_active, v_role_permissions
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin', 'owner', 'gf', 'superintendent') then
    raise exception using errcode = '42501',
      message = 'Only active company leadership can view production summaries.';
  end if;

  if v_role = 'superintendent'
     and coalesce((v_role_permissions->>'production_review')::boolean, true) is not true
     and coalesce((v_role_permissions->>'reporting')::boolean, true) is not true then
    raise exception using errcode = '42501',
      message = 'Production visibility is disabled for this Superintendent.';
  end if;

  return query
  select
    report.id,
    count(location.location_line_id),
    count(*) filter (where location.authorization_status = 'authorized'),
    count(*) filter (where location.authorization_status = 'pending_packet'),
    count(*) filter (where location.authorization_status = 'redline')
  from public.daily_reports report
  left join lateral public.get_daily_report_unit_locations(report.id) location
    on true
  where report.company_id = v_company_id
  group by report.id;
end;
$$;

