alter table public.daily_production_unit_locations
  add column if not exists normalized_pole_location_key text
  generated always as (public.normalize_work_point_key(pole_location)) stored;

alter table public.daily_production_unit_locations
  drop constraint if exists daily_production_unit_locations_report_item_location_unique;

alter table public.daily_production_unit_locations
  add constraint daily_production_unit_locations_report_item_normalized_location_unique
  unique (daily_report_id, price_book_item_id, normalized_pole_location_key);

create index if not exists daily_production_unit_locations_company_item_normalized_idx
  on public.daily_production_unit_locations
  (company_id, price_book_item_id, normalized_pole_location_key);

do $$
declare v_signature text; v_oid oid; v_definition text; v_updated text;
begin
  foreach v_signature in array array[
    'public.save_daily_report_unit_location(uuid,uuid,text,numeric,numeric)',
    'public.save_daily_report_unit_location_v2(uuid,uuid,text,numeric,numeric,numeric)'
  ] loop
    v_oid := to_regprocedure(v_signature);
    if v_oid is null then raise exception 'Expected location save function is missing: %',v_signature; end if;
    select pg_get_functiondef(v_oid) into v_definition;
    v_updated := replace(v_definition,
      'pole_location_key <> lower(v_location)',
      'normalized_pole_location_key <> public.normalize_work_point_key(v_location)');
    v_updated := replace(v_updated,
      'pole_location_key<>lower(v_location)',
      'normalized_pole_location_key<>public.normalize_work_point_key(v_location)');
    v_updated := replace(v_updated,
      'daily_report_id, price_book_item_id, pole_location_key',
      'daily_report_id, price_book_item_id, normalized_pole_location_key');
    v_updated := replace(v_updated,
      'daily_report_id,price_book_item_id,pole_location_key',
      'daily_report_id,price_book_item_id,normalized_pole_location_key');
    if v_updated=v_definition or strpos(v_updated,'normalized_pole_location_key')=0 then
      raise exception 'Expected weak location key was not patched in %',v_signature;
    end if;
    execute v_updated;
  end loop;
end $$;

create or replace function public.get_job_billing_reconciliation_v3(p_job_id uuid)
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
  select profile.company_id,lower(coalesce(profile.role,'')),profile.active
    into v_company_id,v_role,v_active
  from public.profiles profile where profile.id=auth.uid();
  if v_company_id is null or not v_active or
     v_role not in ('owner','admin','manager','superintendent') then
    raise exception using errcode='42501',message='Billing access is required.';
  end if;
  if v_role='superintendent' and
     (not public.linecrew_has_capability('reporting') or
      not public.linecrew_has_capability('actual_pricing')) then
    raise exception using errcode='42501',
      message='Reporting and Actual Pricing permissions are required.';
  end if;
  if not exists(select 1 from public.jobs job where job.id=p_job_id and job.company_id=v_company_id) then
    raise exception using errcode='P0002',message='Job was not found in your company.';
  end if;

  return query
  with progress as (
    select * from public.get_job_progress_dashboard() dashboard where dashboard.job_id=p_job_id
  ), authorized_scope as (
    select authorized.price_book_item_id,
      public.normalize_work_point_key(point.work_point_code) location_key,
      sum(authorized.authorized_install_quantity)::numeric authorized_install,
      sum(authorized.authorized_transfer_quantity)::numeric authorized_transfer,
      sum(authorized.authorized_retirement_quantity)::numeric authorized_retirement,
      max(item.install_price)::numeric current_install_price,
      max(item.transfer_price)::numeric current_transfer_price,
      max(item.retirement_price)::numeric current_retirement_price
    from public.job_packages package
    join public.job_package_work_points point on point.job_package_id=package.id and point.company_id=package.company_id
    join public.job_package_authorized_units authorized on authorized.work_point_id=point.id and authorized.company_id=point.company_id
    join public.price_book_items item on item.id=authorized.price_book_item_id and item.company_id=authorized.company_id
    where package.company_id=v_company_id and package.job_id=p_job_id and package.status='active'
    group by authorized.price_book_item_id,public.normalize_work_point_key(point.work_point_code)
  ), approved_source as (
    select location.id production_location_id,location.price_book_item_id,
      location.normalized_pole_location_key location_key,
      report.work_date,report.created_at report_created_at,location.created_at location_created_at,
      location.install_quantity,location.transfer_quantity,location.retirement_quantity,
      unit.actual_install_price,unit.actual_transfer_price,unit.actual_retirement_price,
      coalesce(authz.authorized_install,0) authorized_install,
      coalesce(authz.authorized_transfer,0) authorized_transfer,
      coalesce(authz.authorized_retirement,0) authorized_retirement
    from public.daily_production_unit_locations location
    join public.daily_reports report on report.id=location.daily_report_id and report.company_id=location.company_id
    join public.daily_production_units unit on unit.id=location.daily_production_unit_id and unit.company_id=location.company_id
    left join authorized_scope authz on authz.price_book_item_id=location.price_book_item_id
      and authz.location_key=location.normalized_pole_location_key
    where location.company_id=v_company_id and report.job_id=p_job_id
      and lower(coalesce(report.status,''))='approved'
  ), allocated as (
    select source.*,
      coalesce(sum(source.install_quantity) over allocation,0)-source.install_quantity prior_install,
      coalesce(sum(source.transfer_quantity) over allocation,0)-source.transfer_quantity prior_transfer,
      coalesce(sum(source.retirement_quantity) over allocation,0)-source.retirement_quantity prior_retirement
    from approved_source source
    window allocation as (
      partition by source.price_book_item_id,source.location_key
      order by source.work_date,source.report_created_at,source.location_created_at,source.production_location_id
      rows between unbounded preceding and current row
    )
  ), portions as (
    select allocated.*,
      least(install_quantity,greatest(authorized_install-prior_install,0)) authorized_install_quantity,
      least(transfer_quantity,greatest(authorized_transfer-prior_transfer,0)) authorized_transfer_quantity,
      least(retirement_quantity,greatest(authorized_retirement-prior_retirement,0)) authorized_retirement_quantity
    from allocated
  ), approved as (
    select
      coalesce(sum(round(
        authorized_install_quantity*actual_install_price+
        authorized_transfer_quantity*actual_transfer_price+
        authorized_retirement_quantity*actual_retirement_price,2)),0) authorized_total,
      coalesce(sum(round(
        (install_quantity-authorized_install_quantity)*actual_install_price+
        (transfer_quantity-authorized_transfer_quantity)*actual_transfer_price+
        (retirement_quantity-authorized_retirement_quantity)*actual_retirement_price,2)),0) redline_total,
      coalesce(sum(round(
        install_quantity*actual_install_price+transfer_quantity*actual_transfer_price+
        retirement_quantity*actual_retirement_price,2)),0) billable_total
    from portions
  ), approved_quantities as (
    select location.price_book_item_id,location.normalized_pole_location_key location_key,
      sum(location.install_quantity)::numeric install_quantity,
      sum(location.transfer_quantity)::numeric transfer_quantity,
      sum(location.retirement_quantity)::numeric retirement_quantity
    from public.daily_production_unit_locations location
    join public.daily_reports report on report.id=location.daily_report_id and report.company_id=location.company_id
    where location.company_id=v_company_id and report.job_id=p_job_id
      and lower(coalesce(report.status,''))='approved'
    group by location.price_book_item_id,location.normalized_pole_location_key
  ), remaining as (
    select coalesce(sum(
      greatest(authz.authorized_install-coalesce(quantity.install_quantity,0),0)*authz.current_install_price+
      greatest(authz.authorized_transfer-coalesce(quantity.transfer_quantity,0),0)*authz.current_transfer_price+
      greatest(authz.authorized_retirement-coalesce(quantity.retirement_quantity,0),0)*authz.current_retirement_price
    ),0)::numeric value
    from authorized_scope authz
    left join approved_quantities quantity on quantity.price_book_item_id=authz.price_book_item_id and quantity.location_key=authz.location_key
  ), unbilled as (
    select coalesce(sum(action.value),0) value
    from (
      select source.production_location_id,'INSTALL'::text work_type,round(source.install_quantity*source.actual_install_price,2) value from approved_source source where source.install_quantity>0
      union all
      select source.production_location_id,'TRANSFER',round(source.transfer_quantity*source.actual_transfer_price,2) from approved_source source where source.transfer_quantity>0
      union all
      select source.production_location_id,'REMOVE',round(source.retirement_quantity*source.actual_retirement_price,2) from approved_source source where source.retirement_quantity>0
    ) action
    where not exists(select 1 from public.billing_export_lines line where line.company_id=v_company_id
      and line.production_location_id=action.production_location_id and line.work_type=action.work_type and line.active)
  ), batches as (
    select coalesce(sum(case when batch.status not in ('void','draft') and batch.billing_type<>'credit' then batch.total_value else 0 end),0) billed,
      coalesce(sum(case when batch.status not in ('void','draft') and batch.billing_type='credit' then batch.total_value else 0 end),0) credits,
      count(*) filter(where batch.status not in ('void','draft')) active_batches,
      count(*) filter(where batch.status not in ('void','draft') and batch.billing_type='final') finals
    from public.billing_export_batches batch where batch.company_id=v_company_id and batch.job_id=p_job_id
  ), reports as (
    select count(*) filter(where lower(coalesce(report.status,''))='submitted') awaiting,
      count(*) filter(where lower(coalesce(report.status,'')) in ('draft','returned')) drafts
    from public.daily_reports report where report.company_id=v_company_id and report.job_id=p_job_id and not report.archived
  )
  select p_job_id,coalesce(progress.authorized_value,0),approved.authorized_total,
    approved.redline_total,approved.billable_total,remaining.value,batches.billed,abs(batches.credits),
    batches.billed+batches.credits,unbilled.value,reports.awaiting,reports.drafts,
    coalesce(progress.pending_packet_count,0),coalesce(progress.redline_count,0),batches.active_batches,batches.finals
  from progress cross join approved cross join remaining cross join unbilled cross join batches cross join reports;
end;
$$;

revoke all on function public.get_job_billing_reconciliation_v3(uuid) from public,anon;
grant execute on function public.get_job_billing_reconciliation_v3(uuid) to authenticated,service_role;

do $$
declare v_signature text; v_oid oid; v_definition text; v_updated text;
begin
  foreach v_signature in array array[
    'public.create_billing_export_batch_v3(uuid,date,date,boolean,text,boolean,text)',
    'public.set_job_closeout(uuid,boolean,text)'
  ] loop
    v_oid:=to_regprocedure(v_signature);
    if v_oid is null then raise exception 'Expected billing caller is missing: %',v_signature; end if;
    select pg_get_functiondef(v_oid) into v_definition;
    v_updated:=replace(v_definition,'public.get_job_billing_reconciliation(p_job_id)','public.get_job_billing_reconciliation_v3(p_job_id)');
    if v_updated=v_definition then raise exception 'Expected legacy reconciliation call was not found in %',v_signature; end if;
    execute v_updated;
  end loop;
end $$;

comment on function public.get_job_billing_reconciliation_v3(uuid) is
  'Splits approved production quantities into authorized and excess portions, prices both from immutable report snapshots, and derives remaining scope from approved quantities.';
