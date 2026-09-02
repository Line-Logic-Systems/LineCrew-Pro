begin;

create or replace function public.get_job_progress_dashboard()
returns table (
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
     v_role not in ('admin', 'gf') then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin or General Foreman can view job progress.';
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
    left join lateral public.get_job_package_work_points(package.id) progress
      on true
    where package.company_id = v_company_id
    group by package.job_id
  ),
  report_totals as (
    select
      report.job_id,
      count(distinct report.id)::bigint as report_count
    from public.daily_reports report
    where report.company_id = v_company_id
      and report.archived is not true
    group by report.job_id
  ),
  exception_totals as (
    select
      report.job_id,
      count(*) filter (
        where location.authorization_status = 'redline'
      )::bigint as redline_count,
      count(*) filter (
        where location.authorization_status = 'pending_packet'
      )::bigint as pending_packet_count
    from public.daily_reports report
    cross join lateral public.get_daily_report_unit_locations(report.id) location
    where report.company_id = v_company_id
      and report.archived is not true
      and lower(coalesce(report.status, 'draft')) <> 'rejected'
    group by report.job_id
  )
  select
    job.id,
    coalesce(package.package_count, 0),
    coalesce(package.work_point_count, 0),
    coalesce(package.authorized_value, 0),
    coalesce(package.reported_value, 0),
    coalesce(package.approved_value, 0),
    greatest(coalesce(package.authorized_value, 0) - coalesce(package.reported_value, 0), 0),
    case when coalesce(package.authorized_value, 0) > 0 then
      round(least(package.reported_value / package.authorized_value * 100, 100), 1)
    else 0 end,
    case when coalesce(package.authorized_value, 0) > 0 then
      round(least(package.approved_value / package.authorized_value * 100, 100), 1)
    else 0 end,
    coalesce(report.report_count, 0),
    coalesce(exception.redline_count, 0),
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

commit;
