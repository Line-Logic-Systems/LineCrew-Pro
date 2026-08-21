create or replace function public.support_list_pilot_command_center()
returns table(
  company_id uuid,
  company_name text,
  company_active boolean,
  subscription_status text,
  subscription_expires_at timestamptz,
  company_created_at timestamptz,
  active_users bigint,
  setup_completed integer,
  setup_total integer,
  setup_missing text[],
  open_feedback bigint,
  recent_errors bigint,
  latest_error_area text,
  latest_error_code text,
  pending_support_approvals bigint
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not public.is_platform_support() then
    raise exception using errcode = '42501', message = 'Platform support access required.';
  end if;

  return query
  with profile_counts as (
    select p.company_id,
      count(*) filter (where p.active is true)::bigint as active_users
    from public.profiles p
    group by p.company_id
  ), customer_counts as (
    select x.company_id, count(*)::bigint as active_customers
    from public.customers x
    where x.active is true
    group by x.company_id
  ), contract_counts as (
    select x.company_id, count(*)::bigint as active_contracts
    from public.contracts x
    where x.active is true
    group by x.company_id
  ), price_book_counts as (
    select x.company_id, count(*)::bigint as active_price_books
    from public.price_books x
    where x.active is true
    group by x.company_id
  ), job_counts as (
    select x.company_id, count(*)::bigint as active_jobs
    from public.jobs x
    where x.active is true
    group by x.company_id
  ), report_counts as (
    select x.company_id, count(*)::bigint as reports
    from public.daily_reports x
    group by x.company_id
  ), feedback_counts as (
    select x.company_id,
      count(*) filter (where x.resolved_at is null)::bigint as open_feedback
    from public.pilot_feedback x
    group by x.company_id
  ), support_counts as (
    select x.company_id,
      count(*) filter (where x.status = 'pending')::bigint as pending_approvals
    from public.support_access_requests x
    group by x.company_id
  ), error_counts as (
    select x.company_id, count(*)::bigint as recent_errors
    from public.app_error_events x
    where x.created_at >= now() - interval '24 hours'
    group by x.company_id
  ), latest_errors as (
    select distinct on (x.company_id)
      x.company_id, x.area, x.error_code
    from public.app_error_events x
    where x.created_at >= now() - interval '24 hours'
    order by x.company_id, x.created_at desc
  ), readiness as (
    select c.*,
      (nullif(trim(c.name), '') is not null
        and nullif(trim(c.contact_email), '') is not null
        and nullif(trim(c.contact_phone), '') is not null
        and nullif(trim(c.timezone), '') is not null) as contact_ready,
      coalesce(pc.active_users, 0) > 1 as team_ready,
      coalesce(cc.active_customers, 0) > 0 as customer_ready,
      coalesce(ct.active_contracts, 0) > 0 as contract_ready,
      coalesce(pb.active_price_books, 0) > 0 as price_book_ready,
      coalesce(jc.active_jobs, 0) > 0 as job_ready,
      coalesce(rc.reports, 0) > 0 as report_ready,
      coalesce(pc.active_users, 0) as active_user_count,
      coalesce(fc.open_feedback, 0) as open_feedback_count,
      coalesce(ec.recent_errors, 0) as recent_error_count,
      le.area as latest_area,
      le.error_code as latest_code,
      coalesce(sc.pending_approvals, 0) as pending_approval_count
    from public.companies c
    left join profile_counts pc on pc.company_id = c.id
    left join customer_counts cc on cc.company_id = c.id
    left join contract_counts ct on ct.company_id = c.id
    left join price_book_counts pb on pb.company_id = c.id
    left join job_counts jc on jc.company_id = c.id
    left join report_counts rc on rc.company_id = c.id
    left join feedback_counts fc on fc.company_id = c.id
    left join support_counts sc on sc.company_id = c.id
    left join error_counts ec on ec.company_id = c.id
    left join latest_errors le on le.company_id = c.id
  )
  select
    r.id,
    r.name,
    r.active,
    r.subscription_status,
    r.subscription_expires_at,
    r.created_at,
    r.active_user_count,
    (r.contact_ready::integer + r.team_ready::integer +
      r.customer_ready::integer + r.contract_ready::integer +
      r.price_book_ready::integer + r.job_ready::integer +
      r.report_ready::integer)::integer,
    7,
    array_remove(array[
      case when not r.contact_ready then 'Company contact' end,
      case when not r.team_ready then 'Team member' end,
      case when not r.customer_ready then 'Customer or utility' end,
      case when not r.contract_ready then 'Active contract' end,
      case when not r.price_book_ready then 'Active Price Book' end,
      case when not r.job_ready then 'Active job' end,
      case when not r.report_ready then 'First daily report' end
    ], null)::text[],
    r.open_feedback_count,
    r.recent_error_count,
    r.latest_area,
    r.latest_code,
    r.pending_approval_count
  from readiness r
  order by
    case
      when r.active is not true then 0
      when r.subscription_status in ('suspended', 'cancelled') then 0
      when r.subscription_status = 'trial'
        and r.subscription_expires_at is not null
        and r.subscription_expires_at <= now() then 0
      when r.pending_approval_count > 0 or r.recent_error_count > 0 then 1
      else 2
    end,
    r.created_at desc;
end;
$$;

revoke all on function public.support_list_pilot_command_center()
  from public, anon, authenticated;
grant execute on function public.support_list_pilot_command_center()
  to authenticated;
