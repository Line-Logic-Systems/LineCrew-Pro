create or replace function public.get_job_progress_dashboard_v2(p_job_id uuid default null)
returns table(
  job_id uuid,
  package_count bigint,
  work_point_count bigint,
  authorized_value numeric,
  reported_value numeric,
  approved_value numeric,
  remaining_value numeric,
  reported_percent numeric,
  approved_percent numeric,
  report_count bigint,
  redline_count bigint,
  pending_packet_count bigint
)
language plpgsql stable security definer set search_path=''
as $$
declare v_company_id uuid; v_role text; v_active boolean;
begin
  select profile.company_id,lower(coalesce(profile.role,'')),profile.active
    into v_company_id,v_role,v_active
  from public.profiles profile where profile.id=auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin','manager','gf','owner','superintendent') then
    raise exception using errcode='42501',message='Only active company leadership can view job progress.';
  end if;
  if v_role='superintendent' and not public.linecrew_has_capability('reporting') then
    raise exception using errcode='42501',message='This Superintendent does not have reporting permission.';
  end if;
  if p_job_id is not null and not exists(
    select 1 from public.jobs job where job.id=p_job_id and job.company_id=v_company_id
  ) then
    raise exception using errcode='P0002',message='Job was not found in your company.';
  end if;

  return query
  with selected_jobs as (
    select job.id,job.active,job.created_at
    from public.jobs job
    where job.company_id=v_company_id and (p_job_id is null or job.id=p_job_id)
  ), package_totals as (
    select package.job_id,count(distinct package.id)::bigint package_count,
      count(distinct point.id)::bigint work_point_count
    from public.job_packages package
    left join public.job_package_work_points point
      on point.job_package_id=package.id and point.company_id=package.company_id
    join selected_jobs job on job.id=package.job_id
    where package.company_id=v_company_id and package.status='active'
    group by package.job_id
  ), authorized_scope as (
    select package.job_id,authorized.price_book_item_id,
      public.normalize_work_point_key(point.work_point_code) location_key,
      sum(authorized.authorized_install_quantity)::numeric authorized_install,
      sum(authorized.authorized_transfer_quantity)::numeric authorized_transfer,
      sum(authorized.authorized_retirement_quantity)::numeric authorized_retirement,
      max(item.install_price)::numeric install_price,
      max(item.transfer_price)::numeric transfer_price,
      max(item.retirement_price)::numeric retirement_price
    from public.job_packages package
    join selected_jobs job on job.id=package.job_id
    join public.job_package_work_points point
      on point.job_package_id=package.id and point.company_id=package.company_id
    join public.job_package_authorized_units authorized
      on authorized.work_point_id=point.id and authorized.company_id=point.company_id
    join public.price_book_items item
      on item.id=authorized.price_book_item_id and item.company_id=authorized.company_id
    where package.company_id=v_company_id and package.status='active'
    group by package.job_id,authorized.price_book_item_id,
      public.normalize_work_point_key(point.work_point_code)
  ), counted_locations as (
    select report.job_id,report.id report_id,lower(coalesce(report.status,'')) report_status,
      location.id location_id,location.price_book_item_id,
      location.normalized_pole_location_key location_key,
      location.install_quantity,location.transfer_quantity,location.retirement_quantity
    from public.daily_reports report
    join selected_jobs job on job.id=report.job_id
    join public.daily_production_unit_locations location
      on location.daily_report_id=report.id and location.company_id=report.company_id
    where report.company_id=v_company_id and public.linecrew_report_counts_toward_progress(
      report.status,report.reviewed_at,report.review_notes,report.archived
    )
  ), production_totals as (
    select location.job_id,location.price_book_item_id,location.location_key,
      sum(location.install_quantity)::numeric reported_install,
      sum(location.transfer_quantity)::numeric reported_transfer,
      sum(location.retirement_quantity)::numeric reported_retirement,
      coalesce(sum(location.install_quantity) filter(where location.report_status='approved'),0)::numeric approved_install,
      coalesce(sum(location.transfer_quantity) filter(where location.report_status='approved'),0)::numeric approved_transfer,
      coalesce(sum(location.retirement_quantity) filter(where location.report_status='approved'),0)::numeric approved_retirement
    from counted_locations location
    group by location.job_id,location.price_book_item_id,location.location_key
  ), progress_totals as (
    select scope.job_id,
      coalesce(sum(scope.authorized_install*scope.install_price+
        scope.authorized_transfer*scope.transfer_price+
        scope.authorized_retirement*scope.retirement_price),0)::numeric authorized_value,
      coalesce(sum(least(coalesce(production.reported_install,0),scope.authorized_install)*scope.install_price+
        least(coalesce(production.reported_transfer,0),scope.authorized_transfer)*scope.transfer_price+
        least(coalesce(production.reported_retirement,0),scope.authorized_retirement)*scope.retirement_price),0)::numeric reported_value,
      coalesce(sum(least(coalesce(production.approved_install,0),scope.authorized_install)*scope.install_price+
        least(coalesce(production.approved_transfer,0),scope.authorized_transfer)*scope.transfer_price+
        least(coalesce(production.approved_retirement,0),scope.authorized_retirement)*scope.retirement_price),0)::numeric approved_value
    from authorized_scope scope
    left join production_totals production on production.job_id=scope.job_id
      and production.price_book_item_id=scope.price_book_item_id and production.location_key=scope.location_key
    group by scope.job_id
  ), report_totals as (
    select report.job_id,count(distinct report.id)::bigint report_count
    from public.daily_reports report join selected_jobs job on job.id=report.job_id
    where report.company_id=v_company_id and public.linecrew_report_counts_toward_progress(
      report.status,report.reviewed_at,report.review_notes,report.archived
    ) group by report.job_id
  ), exception_totals as (
    select location.job_id,
      count(*) filter(where coalesce(package.package_count,0)>0 and (scope.job_id is null or
        production.reported_install>scope.authorized_install or
        production.reported_transfer>scope.authorized_transfer or
        production.reported_retirement>scope.authorized_retirement))::bigint redline_count,
      count(*) filter(where coalesce(package.package_count,0)=0)::bigint pending_packet_count
    from counted_locations location
    left join package_totals package on package.job_id=location.job_id
    left join authorized_scope scope on scope.job_id=location.job_id
      and scope.price_book_item_id=location.price_book_item_id and scope.location_key=location.location_key
    left join production_totals production on production.job_id=location.job_id
      and production.price_book_item_id=location.price_book_item_id and production.location_key=location.location_key
    group by location.job_id
  )
  select job.id,coalesce(package.package_count,0),coalesce(package.work_point_count,0),
    coalesce(progress.authorized_value,0),coalesce(progress.reported_value,0),coalesce(progress.approved_value,0),
    greatest(coalesce(progress.authorized_value,0)-coalesce(progress.reported_value,0),0),
    case when coalesce(progress.authorized_value,0)>0 then round(least(progress.reported_value/progress.authorized_value*100,100),1) else 0 end,
    case when coalesce(progress.authorized_value,0)>0 then round(least(progress.approved_value/progress.authorized_value*100,100),1) else 0 end,
    coalesce(report.report_count,0),coalesce(exception.redline_count,0),coalesce(exception.pending_packet_count,0)
  from selected_jobs job
  left join package_totals package on package.job_id=job.id
  left join progress_totals progress on progress.job_id=job.id
  left join report_totals report on report.job_id=job.id
  left join exception_totals exception on exception.job_id=job.id
  order by job.active desc,job.created_at desc;
end;
$$;

revoke all on function public.get_job_progress_dashboard_v2(uuid) from public,anon;
grant execute on function public.get_job_progress_dashboard_v2(uuid) to authenticated,service_role;

do $$
declare v_oid oid; v_definition text; v_updated text;
begin
  v_oid:=to_regprocedure('public.get_job_billing_reconciliation_v3(uuid)');
  if v_oid is null then raise exception 'Billing reconciliation v3 is missing.'; end if;
  select pg_get_functiondef(v_oid) into v_definition;
  v_updated:=replace(v_definition,
    'public.get_job_progress_dashboard() dashboard where dashboard.job_id=p_job_id',
    'public.get_job_progress_dashboard_v2(p_job_id) dashboard');
  if v_updated=v_definition then raise exception 'The full-company dashboard call was not found in reconciliation v3.'; end if;
  execute v_updated;
end $$;

comment on function public.get_job_progress_dashboard_v2(uuid) is
  'Set-based job progress. A non-null job ID pushes scope into every aggregate for billing and closeout; null returns the company list.';
