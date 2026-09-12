-- Close the remaining launch-readiness defects found after PR #598.
-- This migration is intentionally additive/idempotent and performs no customer-data rewrites.

alter table public.job_package_work_points
  add column if not exists normalized_work_point_key text
  generated always as (public.normalize_work_point_key(work_point_code)) stored;

create index if not exists job_package_work_points_package_normalized_idx
  on public.job_package_work_points(job_package_id, normalized_work_point_key, company_id);

-- B1: Manager is an operational peer of Admin, but cannot administer Owners.
do $do$
declare v_oid oid; v_definition text; v_updated text;
begin
  v_oid:=to_regprocedure('public.get_billing_export_batches_v4(text)');
  select pg_get_functiondef(v_oid) into v_definition;
  v_updated:=replace(v_definition,
    $$v_role not in ('owner','admin','superintendent')$$,
    $$v_role not in ('owner','manager','admin','superintendent')$$);
  if v_updated=v_definition then raise exception 'Manager billing-list gate was not found.'; end if;
  execute v_updated;
end $do$;

-- B3: Aggregate production once and join through stored normalized keys. This
-- removes one correlated scan for every authorized unit row.
create or replace function public.get_job_package_work_points_v2(p_package_id uuid)
returns table(work_point_id uuid,work_point_code text,work_point_description text,
  authorized_unit_id uuid,unit_code text,unit_name text,unit_description text,
  authorized_install_quantity numeric,authorized_transfer_quantity numeric,
  authorized_retirement_quantity numeric,reported_install_quantity numeric,
  reported_transfer_quantity numeric,reported_retirement_quantity numeric,
  approved_install_quantity numeric,approved_transfer_quantity numeric,
  approved_retirement_quantity numeric,authorized_value numeric,reported_value numeric,
  approved_value numeric)
language plpgsql stable security definer set search_path=''
as $$
declare v_company_id uuid; v_job_id uuid;
begin
  if not public.linecrew_can_manage_job_packages() then
    raise exception using errcode='42501',message='You do not have permission to view package progress.';
  end if;
  select profile.company_id into v_company_id from public.profiles profile
    where profile.id=auth.uid() and profile.active is true;
  select package.job_id into v_job_id from public.job_packages package
    where package.id=p_package_id and package.company_id=v_company_id;
  if v_job_id is null then raise exception using errcode='P0002',message='Utility job package was not found in your company.'; end if;

  return query
  with production as (
    select location.price_book_item_id,location.normalized_pole_location_key location_key,
      sum(location.install_quantity)::numeric reported_install,
      sum(location.transfer_quantity)::numeric reported_transfer,
      sum(location.retirement_quantity)::numeric reported_retirement,
      coalesce(sum(location.install_quantity) filter(where lower(coalesce(report.status,''))='approved'),0)::numeric approved_install,
      coalesce(sum(location.transfer_quantity) filter(where lower(coalesce(report.status,''))='approved'),0)::numeric approved_transfer,
      coalesce(sum(location.retirement_quantity) filter(where lower(coalesce(report.status,''))='approved'),0)::numeric approved_retirement
    from public.daily_production_unit_locations location
    join public.daily_reports report on report.id=location.daily_report_id and report.company_id=location.company_id
    where location.company_id=v_company_id and report.job_id=v_job_id
      and public.linecrew_report_counts_toward_progress(report.status,report.reviewed_at,report.review_notes,report.archived)
    group by location.price_book_item_id,location.normalized_pole_location_key
  )
  select point.id,point.work_point_code,point.description,authorized.id,authorized.unit_code,
    item.item_name,item.description,coalesce(authorized.authorized_install_quantity,0),
    coalesce(authorized.authorized_transfer_quantity,0),coalesce(authorized.authorized_retirement_quantity,0),
    coalesce(production.reported_install,0),coalesce(production.reported_transfer,0),coalesce(production.reported_retirement,0),
    coalesce(production.approved_install,0),coalesce(production.approved_transfer,0),coalesce(production.approved_retirement,0),
    coalesce(authorized.authorized_install_quantity*item.install_price+
      authorized.authorized_transfer_quantity*item.transfer_price+
      authorized.authorized_retirement_quantity*item.retirement_price,0),
    coalesce(least(production.reported_install,authorized.authorized_install_quantity)*item.install_price+
      least(production.reported_transfer,authorized.authorized_transfer_quantity)*item.transfer_price+
      least(production.reported_retirement,authorized.authorized_retirement_quantity)*item.retirement_price,0),
    coalesce(least(production.approved_install,authorized.authorized_install_quantity)*item.install_price+
      least(production.approved_transfer,authorized.authorized_transfer_quantity)*item.transfer_price+
      least(production.approved_retirement,authorized.authorized_retirement_quantity)*item.retirement_price,0)
  from public.job_package_work_points point
  left join public.job_package_authorized_units authorized on authorized.work_point_id=point.id and authorized.company_id=point.company_id
  left join public.price_book_items item on item.id=authorized.price_book_item_id and item.company_id=authorized.company_id
  left join production on production.price_book_item_id=authorized.price_book_item_id
    and production.location_key=point.normalized_work_point_key
  where point.job_package_id=p_package_id and point.company_id=v_company_id
  order by point.work_point_key,authorized.unit_code;
end;
$$;

-- B3/B4: classify each report line against only approved history plus the report
-- currently under review. Allocate authorization chronologically, exactly as v3
-- billing does, and use stored normalized keys on both sides.
create or replace function public.get_daily_report_unit_locations_v2(p_report_id uuid)
returns table(location_line_id uuid,price_book_item_id uuid,item_code text,item_name text,
  description text,unit_of_measure text,category text,pole_location text,install_price numeric,
  retirement_price numeric,actual_install_price numeric,actual_retirement_price numeric,
  adjusted_install_price numeric,adjusted_retirement_price numeric,has_adjustment boolean,
  install_quantity numeric,transfer_quantity numeric,retirement_quantity numeric,
  actual_line_value numeric,adjusted_line_value numeric,visible_line_value numeric,
  authorization_status text,authorization_note text)
language plpgsql stable security definer set search_path=''
as $$
declare v_company_id uuid; v_role text; v_active boolean; v_report_company_id uuid;
  v_report_creator uuid; v_report_job_id uuid; v_can_see_actual boolean;
begin
  select profile.company_id,lower(coalesce(profile.role,'')),profile.active
    into v_company_id,v_role,v_active from public.profiles profile where profile.id=auth.uid();
  if v_company_id is null or not v_active or v_role not in ('foreman','gf','superintendent','admin','manager','owner') then
    raise exception using errcode='42501',message='An active production profile is required.';
  end if;
  select report.company_id,report.created_by,report.job_id into v_report_company_id,v_report_creator,v_report_job_id
    from public.daily_reports report where report.id=p_report_id;
  if v_report_company_id is null or v_report_company_id<>v_company_id then
    raise exception using errcode='P0002',message='Daily report was not found in your company.';
  end if;
  if v_role='foreman' and v_report_creator is distinct from auth.uid() then
    raise exception using errcode='42501',message='Foremen can view unit production only on their own reports.';
  end if;
  v_can_see_actual:=public.linecrew_has_capability('actual_pricing');

  return query
  with package_count as (
    select count(*)::integer value from public.job_packages package
    where package.company_id=v_company_id and package.job_id=v_report_job_id and package.status='active'
  ), authorization as (
    select authorized.price_book_item_id,point.normalized_work_point_key location_key,
      count(authorized.id)::integer authorized_unit_count,
      sum(authorized.authorized_install_quantity)::numeric authorized_install,
      sum(authorized.authorized_transfer_quantity)::numeric authorized_transfer,
      sum(authorized.authorized_retirement_quantity)::numeric authorized_retirement
    from public.job_packages package
    join public.job_package_work_points point on point.job_package_id=package.id and point.company_id=package.company_id
    join public.job_package_authorized_units authorized on authorized.work_point_id=point.id and authorized.company_id=point.company_id
    where package.company_id=v_company_id and package.job_id=v_report_job_id and package.status='active'
    group by authorized.price_book_item_id,point.normalized_work_point_key
  ), eligible as (
    select location.id,location.price_book_item_id,location.normalized_pole_location_key location_key,
      location.install_quantity,location.transfer_quantity,location.retirement_quantity,
      report.work_date,report.created_at report_created_at,location.created_at location_created_at
    from public.daily_production_unit_locations location
    join public.daily_reports report on report.id=location.daily_report_id and report.company_id=location.company_id
    where location.company_id=v_company_id and report.job_id=v_report_job_id and not report.archived
      and (lower(coalesce(report.status,''))='approved' or report.id=p_report_id)
  ), allocated as (
    select eligible.*,
      coalesce(sum(eligible.install_quantity) over allocation,0)-eligible.install_quantity prior_install,
      coalesce(sum(eligible.transfer_quantity) over allocation,0)-eligible.transfer_quantity prior_transfer,
      coalesce(sum(eligible.retirement_quantity) over allocation,0)-eligible.retirement_quantity prior_retirement
    from eligible
    window allocation as (partition by eligible.price_book_item_id,eligible.location_key
      order by eligible.work_date,eligible.report_created_at,eligible.location_created_at,eligible.id
      rows between unbounded preceding and current row)
  )
  select location.id,unit.price_book_item_id,unit.item_code,unit.item_name,unit.description,
    unit.unit_of_measure,unit.category,location.pole_location,
    case when v_can_see_actual then unit.actual_install_price else unit.adjusted_install_price end,
    case when v_can_see_actual then unit.actual_retirement_price else unit.adjusted_retirement_price end,
    case when v_can_see_actual then unit.actual_install_price else null end,
    case when v_can_see_actual then unit.actual_retirement_price else null end,
    unit.adjusted_install_price,unit.adjusted_retirement_price,unit.has_adjustment,
    location.install_quantity,location.transfer_quantity,location.retirement_quantity,
    case when v_can_see_actual then round(location.install_quantity*unit.actual_install_price+
      location.transfer_quantity*unit.actual_transfer_price+location.retirement_quantity*unit.actual_retirement_price,2) else null end,
    round(location.install_quantity*unit.adjusted_install_price+
      location.transfer_quantity*unit.adjusted_transfer_price+location.retirement_quantity*unit.adjusted_retirement_price,2),
    case when v_can_see_actual then round(location.install_quantity*unit.actual_install_price+
      location.transfer_quantity*unit.actual_transfer_price+location.retirement_quantity*unit.actual_retirement_price,2)
    else round(location.install_quantity*unit.adjusted_install_price+
      location.transfer_quantity*unit.adjusted_transfer_price+location.retirement_quantity*unit.adjusted_retirement_price,2) end,
    case when packages.value=0 then 'pending_packet'
      when coalesce(authz.authorized_unit_count,0)=0 then 'redline'
      when location.install_quantity>greatest(authz.authorized_install-coalesce(allocation.prior_install,0),0)
        or location.transfer_quantity>greatest(authz.authorized_transfer-coalesce(allocation.prior_transfer,0),0)
        or location.retirement_quantity>greatest(authz.authorized_retirement-coalesce(allocation.prior_retirement,0),0)
        then 'redline' else 'authorized' end,
    case when packages.value=0 then 'No active utility job packet has been added yet. This entry will reconcile when a packet is imported.'
      when coalesce(authz.authorized_unit_count,0)=0 then 'This unit is not authorized at this pole or work point in the active utility job packet.'
      when location.install_quantity>greatest(authz.authorized_install-coalesce(allocation.prior_install,0),0)
        or location.transfer_quantity>greatest(authz.authorized_transfer-coalesce(allocation.prior_transfer,0),0)
        or location.retirement_quantity>greatest(authz.authorized_retirement-coalesce(allocation.prior_retirement,0),0)
        then 'This line exceeds the remaining approved utility-authorized quantity at this pole or work point.' else null end
  from public.daily_production_unit_locations location
  join public.daily_production_units unit on unit.id=location.daily_production_unit_id
    and unit.company_id=location.company_id and unit.daily_report_id=location.daily_report_id
    and unit.price_book_item_id=location.price_book_item_id
  cross join package_count packages
  left join authorization authz on authz.price_book_item_id=location.price_book_item_id
    and authz.location_key=location.normalized_pole_location_key
  left join allocated allocation on allocation.id=location.id
  where location.daily_report_id=p_report_id and location.company_id=v_company_id
  order by location.pole_location_key,unit.item_code;
end;
$$;

-- Use the generated work-point key in the two other progress functions.
do $do$
declare v_signature text; v_oid oid; v_definition text; v_updated text;
begin
  foreach v_signature in array array[
    'public.get_job_billing_reconciliation_v3(uuid)',
    'public.get_job_progress_dashboard_v2(uuid)'
  ] loop
    v_oid:=to_regprocedure(v_signature); select pg_get_functiondef(v_oid) into v_definition;
    v_updated:=replace(v_definition,'public.normalize_work_point_key(point.work_point_code) location_key','point.normalized_work_point_key location_key');
    v_updated:=replace(v_updated,'public.normalize_work_point_key(point.work_point_code)','point.normalized_work_point_key');
    if v_updated=v_definition then raise exception 'Stored work-point key call was not found in %',v_signature; end if;
    execute v_updated;
  end loop;
end $do$;

-- S-04: derive the rounded redline portion from the rounded billable and
-- authorized portions so the displayed buckets reconcile to the cent.
do $do$
declare v_oid oid; v_definition text; v_updated text;
begin
  v_oid:=to_regprocedure('public.get_job_billing_reconciliation_v3(uuid)');
  select pg_get_functiondef(v_oid) into v_definition;
  v_updated:=replace(v_definition,
$$round(
        (install_quantity-authorized_install_quantity)*actual_install_price+
        (transfer_quantity-authorized_transfer_quantity)*actual_transfer_price+
        (retirement_quantity-authorized_retirement_quantity)*actual_retirement_price,2)$$,
$$round(install_quantity*actual_install_price+transfer_quantity*actual_transfer_price+
        retirement_quantity*actual_retirement_price,2)
        - round(authorized_install_quantity*actual_install_price+
        authorized_transfer_quantity*actual_transfer_price+
        authorized_retirement_quantity*actual_retirement_price,2)$$);
  if v_updated=v_definition then raise exception 'Billing redline rounding expression was not found.'; end if;
  execute v_updated;
end $do$;

-- S-16: a draft credit is only a proposal. Release source lines when the
-- credit becomes exported/submitted/paid, not while it remains draft.
do $do$
declare v_oid oid; v_definition text; v_updated text;
begin
  v_oid:=to_regprocedure('public.create_billing_credit_batch(uuid,text)');
  select pg_get_functiondef(v_oid) into v_definition;
  v_updated:=replace(v_definition,
$$  -- Release the original production actions from the active uniqueness lock.
  -- The immutable source and adjustment rows remain available for audit/export.
  update public.billing_export_lines
  set active=false
  where billing_batch_id=v_source.id and company_id=v_company;

$$,'');
  if v_updated=v_definition then raise exception 'Premature credit release was not found.'; end if;
  execute v_updated;

  v_oid:=to_regprocedure('public.set_billing_export_batch_status_v2(uuid,text,text)');
  select pg_get_functiondef(v_oid) into v_definition;
  v_updated:=replace(v_definition,
$$  if v_next='void' and v_billing_type='credit' then$$,
$$  if v_billing_type='credit' and v_current='draft' and v_next in ('exported','submitted','paid') then
    update public.billing_export_lines set active=false
    where company_id=v_company and billing_batch_id=v_parent_batch_id;
  end if;

  if v_next='void' and v_billing_type='credit' then$$);
  if v_updated=v_definition then raise exception 'Credit activation insertion point was not found.'; end if;
  execute v_updated;
end $do$;

-- S-24: ordinary reapproval must preserve the structured redline override.
do $do$
declare v_oid oid; v_definition text; v_updated text;
begin
  v_oid:=to_regprocedure('public.approve_daily_report(uuid,text)');
  select pg_get_functiondef(v_oid) into v_definition;
  v_updated:=replace(v_definition,$$        else null
      end,
      redline_override_reason$$,$$        else report.redline_override_by
      end,
      redline_override_reason$$);
  v_updated:=replace(v_updated,$$        else null
      end,
      redline_override_at$$,$$        else report.redline_override_reason
      end,
      redline_override_at$$);
  v_updated:=replace(v_updated,$$        else null
      end
  where report.id=p_report_id$$,$$        else report.redline_override_at
      end
  where report.id=p_report_id$$);
  if v_updated=v_definition then raise exception 'Redline override reset expressions were not found.'; end if;
  execute v_updated;
end $do$;

-- S-22: access suspension/restoration is a governance event.
do $do$
declare v_oid oid; v_definition text; v_updated text;
begin
  v_oid:=to_regprocedure('public.set_company_member_active(uuid,boolean)');
  select pg_get_functiondef(v_oid) into v_definition;
  v_updated:=replace(v_definition,$$  where id = target.id
    and company_id = actor_company_id;
end;$$,
$$  where id = target.id
    and company_id = actor_company_id;

  insert into public.audit_log(company_id,user_id,action,table_name,record_id,old_data,new_data)
  values(actor_company_id,auth.uid(),'company_member_access_changed','profiles',target.id,
    jsonb_build_object('active',target.active,'role',target_role),
    jsonb_build_object('active',p_active,'role',target_role));
end;$$);
  if v_updated=v_definition then raise exception 'Team-access audit insertion point was not found.'; end if;
  execute v_updated;
end $do$;

revoke all on function public.get_job_package_work_points_v2(uuid) from public,anon;
grant execute on function public.get_job_package_work_points_v2(uuid) to authenticated,service_role;
revoke all on function public.get_daily_report_unit_locations_v2(uuid) from public,anon;
grant execute on function public.get_daily_report_unit_locations_v2(uuid) to authenticated,service_role;

comment on function public.get_daily_report_unit_locations_v2(uuid) is
  'Classifies report lines against approved history plus the report under review using chronological authorization allocation and stored normalized keys.';

-- S-03: close the remaining Manager parity gaps in Timekeeping.
do $do$
declare v_signature text; v_oid oid; v_definition text; v_updated text;
begin
  foreach v_signature in array array[
    'public.timekeeping_set_period_status(date,date,text)',
    'public.validate_timekeeping_employee_assignment()'
  ] loop
    v_oid:=to_regprocedure(v_signature); select pg_get_functiondef(v_oid) into v_definition;
    v_updated:=replace(v_definition,$$('gf','admin','owner')$$,$$('gf','admin','manager','owner')$$);
    v_updated:=replace(v_updated,$$('admin','owner')$$,$$('admin','manager','owner')$$);
    v_updated:=replace(v_updated,$$('owner', 'admin', 'gf')$$,$$('owner', 'admin', 'manager', 'gf')$$);
    if v_updated=v_definition then raise exception 'Manager Timekeeping gate was not found in %',v_signature; end if;
    execute v_updated;
  end loop;
end $do$;

-- S-10: make the uniqueness constraint, rather than a racy pre-check, decide
-- whether another report already owns an employee/job/date entry.
do $do$
declare v_oid oid; v_definition text; v_updated text;
begin
  v_oid:=to_regprocedure('public.save_daily_report_crew_time(uuid,jsonb)');
  select pg_get_functiondef(v_oid) into v_definition;
  v_updated:=replace(v_definition,
$$      updated_by=v_user_id,
      updated_at=now();
  end loop;$$,
$$      updated_by=v_user_id,
      updated_at=now()
    where timekeeping_entries.daily_report_id=p_report_id;
    if not found then
      raise exception using errcode='23505',message='An employee is already recorded on another crew report for this job and date.';
    end if;
  end loop;$$);
  if v_updated=v_definition then raise exception 'Atomic Crew Time ownership guard was not inserted.'; end if;
  execute v_updated;
end $do$;

-- S-12: Storage does not run the PostgREST pre-request hook, so enforce paid,
-- trial, pilot, or explicit-override entitlement directly as a restrictive RLS policy.
drop policy if exists linecrew_company_entitlement_required on storage.objects;
create policy linecrew_company_entitlement_required on storage.objects
  as restrictive for all to authenticated
  using (
    bucket_id not in ('billing-export-attachments','company-logos','daily-report-attachments',
      'job-packet-documents','jsa-uploads','profile-photos')
    or public.linecrew_company_access_enabled(public.my_company_id())
  )
  with check (
    bucket_id not in ('billing-export-attachments','company-logos','daily-report-attachments',
      'job-packet-documents','jsa-uploads','profile-photos')
    or public.linecrew_company_access_enabled(public.my_company_id())
  );

-- S-18: direct REST reads of JSA attachment metadata must match file access.
drop policy if exists "jsa attachment role scoped read" on public.jsa_upload_attachments;
create policy "jsa attachment role scoped read" on public.jsa_upload_attachments
  for select to authenticated
  using (
    company_id=(select public.my_company_id())
    and exists (
      select 1 from public.daily_report_jsas jsa
      where jsa.id=jsa_upload_attachments.jsa_id
        and jsa.company_id=jsa_upload_attachments.company_id
        and (
          jsa.created_by=(select auth.uid())
          or public.my_role() in ('owner','manager','admin','gf')
          or (public.my_role()='superintendent' and public.linecrew_has_capability('safety_records'))
          or public.my_role()='safety'
        )
    )
  );

-- S-19/N-10: keep packet files tied to an existing package/job path and allow
-- authorized package managers to delete obsolete documents.
drop policy if exists job_packet_documents_manager_update on storage.objects;
create policy job_packet_documents_manager_update on storage.objects
  for update to authenticated
  using (
    bucket_id='job-packet-documents' and public.current_user_has_active_profile()
    and public.linecrew_can_manage_job_packages()
    and (storage.foldername(name))[1]=public.my_company_id()::text
    and exists(select 1 from public.job_packages package
      where package.id::text=(storage.foldername(name))[3]
        and package.job_id::text=(storage.foldername(name))[2]
        and package.company_id=public.my_company_id())
  )
  with check (
    bucket_id='job-packet-documents' and public.current_user_has_active_profile()
    and public.linecrew_can_manage_job_packages()
    and (storage.foldername(name))[1]=public.my_company_id()::text
    and exists(select 1 from public.job_packages package
      where package.id::text=(storage.foldername(name))[3]
        and package.job_id::text=(storage.foldername(name))[2]
        and package.company_id=public.my_company_id())
  );

drop policy if exists job_packet_documents_manager_delete on storage.objects;
create policy job_packet_documents_manager_delete on storage.objects
  for delete to authenticated
  using (
    bucket_id='job-packet-documents' and public.current_user_has_active_profile()
    and public.linecrew_can_manage_job_packages()
    and (storage.foldername(name))[1]=public.my_company_id()::text
    and exists(select 1 from public.job_packages package
      where package.id::text=(storage.foldername(name))[3]
        and package.job_id::text=(storage.foldername(name))[2]
        and package.company_id=public.my_company_id())
  );
