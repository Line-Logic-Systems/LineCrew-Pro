begin;

create or replace function public.get_job_billing_reconciliation(p_job_id uuid)
returns table(
  job_id uuid,authorized_value numeric,approved_value numeric,remaining_authorized_value numeric,
  billed_value numeric,credit_value numeric,net_billed_value numeric,approved_unbilled_value numeric,
  awaiting_review_count bigint,draft_report_count bigint,pending_packet_count bigint,
  redline_count bigint,active_batch_count bigint,final_bill_count bigint
)
language plpgsql stable security definer set search_path='' as $$
declare v_company uuid; v_role text; v_active boolean;
begin
  select p.company_id,lower(coalesce(p.role,'')),p.active into v_company,v_role,v_active
  from public.profiles p where p.id=auth.uid();
  if v_company is null or not v_active or v_role not in ('owner','admin','superintendent') then
    raise exception using errcode='42501',message='Billing access is required.';
  end if;
  if v_role='superintendent' and (not public.linecrew_has_capability('reporting') or
    not public.linecrew_has_capability('actual_pricing')) then
    raise exception using errcode='42501',message='Reporting and Actual Pricing permissions are required.';
  end if;
  if not exists(select 1 from public.jobs j where j.id=p_job_id and j.company_id=v_company) then
    raise exception using errcode='P0002',message='Job was not found in your company.';
  end if;
  return query
  with progress as (
    select * from public.get_job_progress_dashboard() p where p.job_id=p_job_id
  ), eligible as (
    select location.location_line_id production_location_id,location.item_code unit_code,
      location.install_quantity,location.retirement_quantity,
      location.actual_install_price,location.actual_retirement_price
    from public.daily_reports report
    cross join lateral public.get_daily_report_unit_locations(report.id) location
    where report.company_id=v_company and report.job_id=p_job_id
      and lower(coalesce(report.status,''))='approved'
      and location.authorization_status in ('authorized','redline')
  ), actions as (
    select e.production_location_id,
      case when right(upper(btrim(e.unit_code)),1)='T' then 'TRANSFER' else 'INSTALL' end work_type,
      round(e.install_quantity*coalesce(e.actual_install_price,0),2) value
    from eligible e where e.install_quantity>0
    union all
    select e.production_location_id,'REMOVE',
      round(e.retirement_quantity*coalesce(e.actual_retirement_price,0),2)
    from eligible e where e.retirement_quantity>0
  ), approved as (
    select coalesce(sum(a.value),0) approved_total,
      coalesce(sum(a.value) filter(where not exists(
        select 1 from public.billing_export_lines line
        where line.company_id=v_company and line.production_location_id=a.production_location_id
          and line.work_type=a.work_type and line.active
      )),0) approved_unbilled
    from actions a
  ), batches as (
    select
      coalesce(sum(case when b.status<>'void' and b.billing_type<>'credit' then b.total_value else 0 end),0) billed,
      coalesce(sum(case when b.status<>'void' and b.billing_type='credit' then b.total_value else 0 end),0) credits,
      count(*) filter(where b.status<>'void') active_batches,
      count(*) filter(where b.status<>'void' and b.billing_type='final') finals
    from public.billing_export_batches b where b.company_id=v_company and b.job_id=p_job_id
  ), reports as (
    select count(*) filter(where lower(coalesce(r.status,''))='submitted') awaiting,
      count(*) filter(where lower(coalesce(r.status,'')) in ('draft','returned')) drafts
    from public.daily_reports r where r.company_id=v_company and r.job_id=p_job_id and not r.archived
  )
  select p_job_id,coalesce(p.authorized_value,0),a.approved_total,
    greatest(coalesce(p.remaining_value,0),0),b.billed,abs(b.credits),b.billed+b.credits,
    a.approved_unbilled,r.awaiting,r.drafts,coalesce(p.pending_packet_count,0),
    coalesce(p.redline_count,0),b.active_batches,b.finals
  from progress p cross join approved a cross join batches b cross join reports r;
end;
$$;

revoke all on function public.get_job_billing_reconciliation(uuid) from public,anon;
grant execute on function public.get_job_billing_reconciliation(uuid) to authenticated;

commit;
