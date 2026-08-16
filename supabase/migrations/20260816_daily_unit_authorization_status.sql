begin;

-- Calculate authorization when viewed so production entered before a utility
-- packet arrives reconciles automatically after the packet is imported.
drop function if exists public.get_daily_report_unit_locations(uuid);

create function public.get_daily_report_unit_locations(p_report_id uuid)
returns table (
  location_line_id uuid, price_book_item_id uuid, item_code text,
  item_name text, description text, unit_of_measure text, category text,
  pole_location text, install_price numeric, retirement_price numeric,
  actual_install_price numeric, actual_retirement_price numeric,
  adjusted_install_price numeric, adjusted_retirement_price numeric,
  has_adjustment boolean, install_quantity numeric,
  retirement_quantity numeric, actual_line_value numeric,
  adjusted_line_value numeric, visible_line_value numeric,
  authorization_status text, authorization_note text
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
  v_report_job_id uuid;
  v_can_see_actual boolean;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_profile_active
  from public.profiles profile where profile.id = auth.uid();

  if v_company_id is null or v_profile_active is not true or
     v_role not in ('foreman', 'gf', 'admin') then
    raise exception using errcode = '42501',
      message = 'An active Foreman, General Foreman or Admin profile is required.';
  end if;

  select report.company_id, report.created_by, report.job_id
  into v_report_company_id, v_report_creator, v_report_job_id
  from public.daily_reports report where report.id = p_report_id;

  if v_report_company_id is null or v_report_company_id <> v_company_id then
    raise exception using errcode = 'P0002',
      message = 'Daily report was not found in your company.';
  end if;

  if v_role = 'foreman' and v_report_creator is distinct from auth.uid() then
    raise exception using errcode = '42501',
      message = 'Foremen can view unit production only on their own reports.';
  end if;

  v_can_see_actual := v_role in ('admin', 'gf');

  return query
  select
    location_line.id, aggregate_line.price_book_item_id,
    aggregate_line.item_code, aggregate_line.item_name,
    aggregate_line.description, aggregate_line.unit_of_measure,
    aggregate_line.category, location_line.pole_location,
    case when v_can_see_actual then aggregate_line.actual_install_price
      else aggregate_line.adjusted_install_price end,
    case when v_can_see_actual then aggregate_line.actual_retirement_price
      else aggregate_line.adjusted_retirement_price end,
    case when v_can_see_actual then aggregate_line.actual_install_price else null end,
    case when v_can_see_actual then aggregate_line.actual_retirement_price else null end,
    aggregate_line.adjusted_install_price,
    aggregate_line.adjusted_retirement_price, aggregate_line.has_adjustment,
    location_line.install_quantity, location_line.retirement_quantity,
    case when v_can_see_actual then round(
      location_line.install_quantity * aggregate_line.actual_install_price +
      location_line.retirement_quantity * aggregate_line.actual_retirement_price, 2
    ) else null end,
    round(
      location_line.install_quantity * aggregate_line.adjusted_install_price +
      location_line.retirement_quantity * aggregate_line.adjusted_retirement_price, 2
    ),
    case when v_can_see_actual then round(
      location_line.install_quantity * aggregate_line.actual_install_price +
      location_line.retirement_quantity * aggregate_line.actual_retirement_price, 2
    ) else round(
      location_line.install_quantity * aggregate_line.adjusted_install_price +
      location_line.retirement_quantity * aggregate_line.adjusted_retirement_price, 2
    ) end,
    case
      when package_summary.package_count = 0 then 'pending_packet'
      when authorization.authorized_unit_count = 0 then 'redline'
      when production.reported_install > authorization.authorized_install or
           production.reported_retirement > authorization.authorized_retirement
        then 'redline'
      else 'authorized'
    end,
    case
      when package_summary.package_count = 0
        then 'No utility job packet has been added yet. This entry will reconcile when a packet is imported.'
      when authorization.authorized_unit_count = 0
        then 'This unit is not authorized at this pole or work point in the utility job packet.'
      when production.reported_install > authorization.authorized_install or
           production.reported_retirement > authorization.authorized_retirement
        then 'Reported quantity exceeds the utility-authorized quantity at this pole or work point.'
      else null
    end
  from public.daily_production_unit_locations location_line
  join public.daily_production_units aggregate_line
    on aggregate_line.id = location_line.daily_production_unit_id
   and aggregate_line.company_id = location_line.company_id
   and aggregate_line.daily_report_id = location_line.daily_report_id
   and aggregate_line.price_book_item_id = location_line.price_book_item_id
  cross join lateral (
    select count(*)::integer as package_count
    from public.job_packages package
    where package.company_id = v_company_id and package.job_id = v_report_job_id
  ) package_summary
  cross join lateral (
    select count(authorized.id)::integer as authorized_unit_count,
      coalesce(sum(authorized.authorized_install_quantity), 0) as authorized_install,
      coalesce(sum(authorized.authorized_retirement_quantity), 0) as authorized_retirement
    from public.job_packages package
    join public.job_package_work_points point
      on point.job_package_id = package.id and point.company_id = package.company_id
    join public.job_package_authorized_units authorized
      on authorized.work_point_id = point.id and authorized.company_id = point.company_id
    where package.company_id = v_company_id and package.job_id = v_report_job_id
      and public.normalize_work_point_key(point.work_point_code) =
          public.normalize_work_point_key(location_line.pole_location)
      and authorized.price_book_item_id = location_line.price_book_item_id
  ) authorization
  cross join lateral (
    select coalesce(sum(other_location.install_quantity), 0) as reported_install,
      coalesce(sum(other_location.retirement_quantity), 0) as reported_retirement
    from public.daily_production_unit_locations other_location
    join public.daily_reports other_report
      on other_report.id = other_location.daily_report_id
     and other_report.company_id = other_location.company_id
    where other_location.company_id = v_company_id
      and other_report.job_id = v_report_job_id
      and lower(coalesce(other_report.status, '')) <> 'rejected'
      and other_location.price_book_item_id = location_line.price_book_item_id
      and public.normalize_work_point_key(other_location.pole_location) =
          public.normalize_work_point_key(location_line.pole_location)
  ) production
  where location_line.daily_report_id = p_report_id
    and location_line.company_id = v_company_id
  order by location_line.pole_location_key, aggregate_line.item_code;
end;
$$;

revoke all on function public.get_daily_report_unit_locations(uuid) from public, anon;
grant execute on function public.get_daily_report_unit_locations(uuid) to authenticated;

commit;
