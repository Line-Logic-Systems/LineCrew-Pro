begin;

-- A successfully finalized smart import is the effective utility design.
-- Activating it also invokes the existing revision trigger, which closes the
-- prior active revision while preserving that revision for history/audit.
create or replace function public.activate_finalized_utility_packet_revision()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'imported' and old.status is distinct from new.status then
    update public.job_packages package
    set status = 'active', updated_at = now()
    where package.id = new.job_package_id
      and package.company_id = new.company_id
      and package.status is distinct from 'active';
  end if;
  return new;
end;
$$;

revoke all on function public.activate_finalized_utility_packet_revision() from public, anon, authenticated;
-- These pre-existing functions are trigger-only internals. Revoking direct
-- API execution does not prevent PostgreSQL from invoking their triggers.
revoke all on function public.assign_job_package_revision() from public, anon, authenticated;
revoke all on function public.supersede_prior_job_package() from public, anon, authenticated;

drop trigger if exists activate_finalized_utility_packet_revision_trigger
  on public.utility_packet_imports;
create trigger activate_finalized_utility_packet_revision_trigger
after update of status on public.utility_packet_imports
for each row execute function public.activate_finalized_utility_packet_revision();

-- Bring completed imports created before this trigger onto the same lifecycle.
-- Only the newest completed revision for each job is activated.
with latest_completed as (
  select distinct on (package.company_id, package.job_id)
    package.id
  from public.job_packages package
  where exists (
    select 1
    from public.utility_packet_imports packet_import
    where packet_import.job_package_id = package.id
      and packet_import.company_id = package.company_id
      and packet_import.status = 'imported'
  )
  order by package.company_id, package.job_id,
    package.revision_number desc, package.created_at desc
)
update public.job_packages package
set status = 'active', updated_at = now()
from latest_completed latest
where package.id = latest.id
  and package.status is distinct from 'active';

create or replace function public.get_job_progress_dashboard()
returns table (
  job_id uuid, package_count bigint, work_point_count bigint,
  authorized_value numeric, reported_value numeric, approved_value numeric,
  remaining_value numeric, reported_percent numeric, approved_percent numeric,
  report_count bigint, redline_count bigint, pending_packet_count bigint
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin', 'gf', 'owner', 'superintendent') then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin or General Foreman can view job progress.';
  end if;
  if v_role = 'superintendent' and
     not public.linecrew_has_capability('reporting') then
    raise exception using errcode = '42501',
      message = 'This Superintendent does not have reporting permission.';
  end if;

  return query
  with package_totals as (
    select
      package.job_id,
      count(distinct package.id)::bigint as package_count,
      count(distinct progress.work_point_id)::bigint as work_point_count,
      coalesce(sum(progress.authorized_value), 0)::numeric as authorized_value,
      coalesce(sum(progress.reported_value), 0)::numeric as reported_value,
      coalesce(sum(progress.approved_value), 0)::numeric as approved_value
    from public.job_packages package
    left join lateral public.get_job_package_work_points(package.id) progress on true
    where package.company_id = v_company_id
      and package.status = 'active'
    group by package.job_id
  ),
  report_totals as (
    select report.job_id, count(distinct report.id)::bigint as report_count
    from public.daily_reports report
    where report.company_id = v_company_id
      and report.archived is not true
    group by report.job_id
  ),
  exception_totals as (
    select report.job_id,
      count(*) filter (where location.authorization_status = 'redline')::bigint as redline_count,
      count(*) filter (where location.authorization_status = 'pending_packet')::bigint as pending_packet_count
    from public.daily_reports report
    cross join lateral public.get_daily_report_unit_locations(report.id) location
    where report.company_id = v_company_id
      and report.archived is not true
      and lower(coalesce(report.status, 'draft')) <> 'rejected'
    group by report.job_id
  )
  select job.id,
    coalesce(package.package_count, 0), coalesce(package.work_point_count, 0),
    coalesce(package.authorized_value, 0), coalesce(package.reported_value, 0),
    coalesce(package.approved_value, 0),
    greatest(coalesce(package.authorized_value, 0) - coalesce(package.reported_value, 0), 0),
    case when coalesce(package.authorized_value, 0) > 0
      then round(least(package.reported_value / package.authorized_value * 100, 100), 1)
      else 0 end,
    case when coalesce(package.authorized_value, 0) > 0
      then round(least(package.approved_value / package.authorized_value * 100, 100), 1)
      else 0 end,
    coalesce(report.report_count, 0), coalesce(exception.redline_count, 0),
    coalesce(exception.pending_packet_count, 0)
  from public.jobs job
  left join package_totals package on package.job_id = job.id
  left join report_totals report on report.job_id = job.id
  left join exception_totals exception on exception.job_id = job.id
  where job.company_id = v_company_id
  order by job.active desc, job.created_at desc;
end;
$$;

revoke all on function public.get_job_progress_dashboard() from public, anon;
grant execute on function public.get_job_progress_dashboard() to authenticated;

create or replace function public.get_daily_report_unit_locations(p_report_id uuid)
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
     v_role not in ('foreman', 'gf', 'superintendent', 'admin', 'owner') then
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

  v_can_see_actual := v_role in ('admin', 'gf', 'owner') or
    (v_role = 'superintendent' and public.linecrew_has_capability('actual_pricing'));

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
    round(location_line.install_quantity * aggregate_line.adjusted_install_price +
      location_line.retirement_quantity * aggregate_line.adjusted_retirement_price, 2),
    case when v_can_see_actual then round(
      location_line.install_quantity * aggregate_line.actual_install_price +
      location_line.retirement_quantity * aggregate_line.actual_retirement_price, 2
    ) else round(
      location_line.install_quantity * aggregate_line.adjusted_install_price +
      location_line.retirement_quantity * aggregate_line.adjusted_retirement_price, 2
    ) end,
    case
      when package_summary.package_count = 0 then 'pending_packet'
      when auth_summary.authorized_unit_count = 0 then 'redline'
      when production.reported_install > auth_summary.authorized_install or
           production.reported_retirement > auth_summary.authorized_retirement then 'redline'
      else 'authorized'
    end,
    case
      when package_summary.package_count = 0
        then 'No active utility job packet has been added yet. This entry will reconcile when a packet is imported.'
      when auth_summary.authorized_unit_count = 0
        then 'This unit is not authorized at this pole or work point in the active utility job packet.'
      when production.reported_install > auth_summary.authorized_install or
           production.reported_retirement > auth_summary.authorized_retirement
        then 'Reported quantity exceeds the active utility-authorized quantity at this pole or work point.'
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
    where package.company_id = v_company_id
      and package.job_id = v_report_job_id
      and package.status = 'active'
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
    where package.company_id = v_company_id
      and package.job_id = v_report_job_id
      and package.status = 'active'
      and public.normalize_work_point_key(point.work_point_code) =
          public.normalize_work_point_key(location_line.pole_location)
      and authorized.price_book_item_id = location_line.price_book_item_id
  ) auth_summary
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
