create or replace function public.get_job_billing_reconciliation_v2(p_job_id uuid)
returns table(
  job_id uuid,
  authorized_progress_value numeric,
  approved_authorized_progress_value numeric,
  approved_redline_value numeric,
  approved_billable_value numeric,
  remaining_authorized_value numeric,
  billed_value numeric,
  credit_value numeric,
  net_billed_value numeric,
  approved_unbilled_value numeric,
  awaiting_review_count bigint,
  draft_report_count bigint,
  pending_packet_count bigint,
  redline_count bigint,
  active_batch_count bigint,
  final_bill_count bigint
)
language plpgsql stable security definer set search_path = ''
as $$
declare v_company_id uuid; v_role text; v_active boolean;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
    into v_company_id, v_role, v_active
  from public.profiles profile where profile.id = auth.uid();
  if v_company_id is null or not v_active or
     v_role not in ('owner', 'admin', 'manager', 'superintendent') then
    raise exception using errcode = '42501', message = 'Billing access is required.';
  end if;
  if v_role = 'superintendent' and
     (not public.linecrew_has_capability('reporting') or
      not public.linecrew_has_capability('actual_pricing')) then
    raise exception using errcode = '42501',
      message = 'Reporting and Actual Pricing permissions are required.';
  end if;
  if not exists (
    select 1 from public.jobs job
    where job.id = p_job_id and job.company_id = v_company_id
  ) then
    raise exception using errcode = 'P0002', message = 'Job was not found in your company.';
  end if;

  return query
  with progress as (
    select * from public.get_job_progress_dashboard() dashboard
    where dashboard.job_id = p_job_id
  ), eligible as (
    select location.location_line_id production_location_id,
      location.authorization_status,
      location.install_quantity, location.transfer_quantity, location.retirement_quantity,
      location.actual_install_price, unit.actual_transfer_price,
      location.actual_retirement_price
    from public.daily_reports report
    cross join lateral public.get_daily_report_unit_locations_v2(report.id) location
    join public.daily_production_unit_locations source
      on source.id = location.location_line_id and source.company_id = report.company_id
    join public.daily_production_units unit
      on unit.id = source.daily_production_unit_id and unit.company_id = source.company_id
    where report.company_id = v_company_id and report.job_id = p_job_id
      and lower(coalesce(report.status, '')) = 'approved'
      and location.authorization_status in ('authorized', 'redline')
  ), actions as (
    select eligible.production_location_id, eligible.authorization_status,
      'INSTALL'::text work_type,
      round(eligible.install_quantity * coalesce(eligible.actual_install_price, 0), 2) value
    from eligible where eligible.install_quantity > 0
    union all
    select eligible.production_location_id, eligible.authorization_status, 'TRANSFER'::text,
      round(eligible.transfer_quantity * coalesce(eligible.actual_transfer_price, 0), 2)
    from eligible where eligible.transfer_quantity > 0
    union all
    select eligible.production_location_id, eligible.authorization_status, 'REMOVE'::text,
      round(eligible.retirement_quantity * coalesce(eligible.actual_retirement_price, 0), 2)
    from eligible where eligible.retirement_quantity > 0
  ), approved as (
    select
      coalesce(sum(action.value) filter (where action.authorization_status = 'authorized'), 0) authorized_total,
      coalesce(sum(action.value) filter (where action.authorization_status = 'redline'), 0) redline_total,
      coalesce(sum(action.value), 0) billable_total,
      coalesce(sum(action.value) filter (where not exists (
        select 1 from public.billing_export_lines line
        where line.company_id = v_company_id
          and line.production_location_id = action.production_location_id
          and line.work_type = action.work_type and line.active
      )), 0) approved_unbilled
    from actions action
  ), batches as (
    select coalesce(sum(case
        when batch.status not in ('void', 'draft') and batch.billing_type <> 'credit'
        then batch.total_value else 0 end), 0) billed,
      coalesce(sum(case
        when batch.status not in ('void', 'draft') and batch.billing_type = 'credit'
        then batch.total_value else 0 end), 0) credits,
      count(*) filter (where batch.status not in ('void', 'draft')) active_batches,
      count(*) filter (where batch.status not in ('void', 'draft')
        and batch.billing_type = 'final') finals
    from public.billing_export_batches batch
    where batch.company_id = v_company_id and batch.job_id = p_job_id
  ), reports as (
    select count(*) filter (where lower(coalesce(report.status, '')) = 'submitted') awaiting,
      count(*) filter (where lower(coalesce(report.status, '')) in ('draft', 'returned')) drafts
    from public.daily_reports report
    where report.company_id = v_company_id and report.job_id = p_job_id and not report.archived
  )
  select p_job_id, coalesce(progress.authorized_value, 0),
    coalesce(progress.approved_value, 0), approved.redline_total,
    approved.billable_total, greatest(coalesce(progress.remaining_value, 0), 0),
    batches.billed, abs(batches.credits), batches.billed + batches.credits,
    approved.approved_unbilled, reports.awaiting, reports.drafts,
    coalesce(progress.pending_packet_count, 0), coalesce(progress.redline_count, 0),
    batches.active_batches, batches.finals
  from progress cross join approved cross join batches cross join reports;
end;
$$;

revoke all on function public.get_job_billing_reconciliation_v2(uuid) from public, anon;
grant execute on function public.get_job_billing_reconciliation_v2(uuid) to authenticated, service_role;
comment on function public.get_job_billing_reconciliation_v2(uuid) is
  'Separates authorized progress from approved redline value while retaining the combined approved billable total.';
