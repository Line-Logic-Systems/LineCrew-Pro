begin;

-- A report must be reviewed by someone other than its field author/Foreman.
create or replace function public.approve_daily_report(
  p_report_id uuid,
  p_review_notes text default null::text
)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_report_company_id uuid;
  v_report_status text;
  v_report_creator uuid;
  v_report_foreman uuid;
  v_require_gf boolean;
  v_redline_count bigint;
  v_existing_notes text;
  v_new_note text;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin', 'gf', 'owner', 'superintendent') then
    raise exception using errcode = '42501',
      message = 'Only active company leadership can approve reports.';
  end if;

  if v_role = 'superintendent' and not public.linecrew_has_capability('production_review') then
    raise exception using errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;

  select report.company_id, lower(coalesce(report.status, 'draft')),
         report.created_by, report.foreman_id, report.review_notes
  into v_report_company_id, v_report_status, v_report_creator,
       v_report_foreman, v_existing_notes
  from public.daily_reports report
  where report.id = p_report_id;

  if v_report_company_id is null or v_report_company_id <> v_company_id then
    raise exception using errcode = 'P0002',
      message = 'Daily report was not found in your company.';
  end if;

  if v_report_status <> 'submitted' then
    raise exception using errcode = '23514',
      message = 'Only submitted reports can be approved.';
  end if;

  if auth.uid() = v_report_creator or auth.uid() = v_report_foreman then
    raise exception using errcode = '42501',
      message = 'A Daily Report must be approved by someone other than its author or Foreman.';
  end if;

  select company.require_gf_redline_approval
  into v_require_gf
  from public.companies company
  where company.id = v_company_id;

  select count(*)
  into v_redline_count
  from public.get_daily_report_unit_locations_v2(p_report_id) location
  where location.authorization_status = 'redline';

  v_new_note := nullif(btrim(coalesce(p_review_notes, '')), '');

  if coalesce(v_require_gf, false) and v_redline_count > 0 and
     v_role in ('admin', 'owner', 'superintendent') and v_new_note is null then
    raise exception using errcode = '22023',
      message = 'Enter an override reason because this company requires GF approval for redlines.';
  end if;

  update public.daily_reports report
  set status = 'approved',
      review_notes = case
        when v_new_note is null then v_existing_notes
        when nullif(btrim(coalesce(v_existing_notes, '')), '') is null then v_new_note
        else btrim(v_existing_notes) || E'\n\nGF APPROVAL:\n' || v_new_note
      end,
      redline_override_by = case
        when coalesce(v_require_gf, false) and v_redline_count > 0 and
             v_role in ('admin', 'owner', 'superintendent') then auth.uid()
        else null
      end,
      redline_override_reason = case
        when coalesce(v_require_gf, false) and v_redline_count > 0 and
             v_role in ('admin', 'owner', 'superintendent') then v_new_note
        else null
      end,
      redline_override_at = case
        when coalesce(v_require_gf, false) and v_redline_count > 0 and
             v_role in ('admin', 'owner', 'superintendent') then now()
        else null
      end
  where report.id = p_report_id and report.company_id = v_company_id;
end;
$$;

-- Only never-submitted drafts may be hard-deleted. Returned reports retain their audit history.
create or replace function public.delete_draft_daily_report(p_report_id uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Not authenticated.';
  end if;

  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true then
    raise exception using errcode = '42501', message = 'An active company profile is required.';
  end if;

  if v_role = 'superintendent' and not public.linecrew_has_capability('production_review') then
    raise exception using errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;

  if v_role not in ('owner', 'admin', 'superintendent', 'foreman') then
    raise exception using errcode = '42501',
      message = 'You do not have permission to delete draft Daily Reports.';
  end if;

  if not exists (
    select 1
    from public.daily_reports report
    where report.id = p_report_id
      and report.company_id = v_company_id
      and lower(coalesce(report.status, 'draft')) = 'draft'
      and report.submitted_at is null
      and report.reviewed_at is null
      and (
        v_role in ('owner', 'admin', 'superintendent')
        or (v_role = 'foreman' and report.foreman_id = auth.uid())
      )
  ) then
    raise exception using errcode = 'P0002',
      message = 'Only a never-submitted draft can be deleted.';
  end if;

  delete from public.timekeeping_entries entry
  where entry.daily_report_id = p_report_id and entry.company_id = v_company_id;

  delete from public.daily_reports report
  where report.id = p_report_id
    and report.company_id = v_company_id
    and lower(coalesce(report.status, 'draft')) = 'draft'
    and report.submitted_at is null
    and report.reviewed_at is null;
end;
$$;

-- Reconciliation now treats transfer quantities as their own billable action.
create or replace function public.get_job_billing_reconciliation(p_job_id uuid)
returns table(
  job_id uuid, authorized_value numeric, approved_value numeric,
  remaining_authorized_value numeric, billed_value numeric, credit_value numeric,
  net_billed_value numeric, approved_unbilled_value numeric,
  awaiting_review_count bigint, draft_report_count bigint,
  pending_packet_count bigint, redline_count bigint,
  active_batch_count bigint, final_bill_count bigint
)
language plpgsql stable security definer set search_path = '' as $$
declare v_company uuid; v_role text; v_active boolean;
begin
  select p.company_id, lower(coalesce(p.role, '')), p.active
  into v_company, v_role, v_active
  from public.profiles p where p.id = auth.uid();
  if v_company is null or not v_active or v_role not in ('owner', 'admin', 'superintendent') then
    raise exception using errcode = '42501', message = 'Billing access is required.';
  end if;
  if v_role = 'superintendent' and
     (not public.linecrew_has_capability('reporting') or
      not public.linecrew_has_capability('actual_pricing')) then
    raise exception using errcode = '42501',
      message = 'Reporting and Actual Pricing permissions are required.';
  end if;
  if not exists (select 1 from public.jobs j where j.id = p_job_id and j.company_id = v_company) then
    raise exception using errcode = 'P0002', message = 'Job was not found in your company.';
  end if;

  return query
  with progress as (
    select * from public.get_job_progress_dashboard() p where p.job_id = p_job_id
  ), eligible as (
    select location.location_line_id production_location_id,
      location.install_quantity, location.transfer_quantity, location.retirement_quantity,
      location.actual_install_price, location.actual_retirement_price
    from public.daily_reports report
    cross join lateral public.get_daily_report_unit_locations_v2(report.id) location
    where report.company_id = v_company and report.job_id = p_job_id
      and lower(coalesce(report.status, '')) = 'approved'
      and location.authorization_status in ('authorized', 'redline')
  ), actions as (
    select e.production_location_id, 'INSTALL'::text work_type,
      round(e.install_quantity * coalesce(e.actual_install_price, 0), 2) value
    from eligible e where e.install_quantity > 0
    union all
    select e.production_location_id, 'TRANSFER'::text,
      round(e.transfer_quantity * coalesce(e.actual_install_price, 0), 2)
    from eligible e where e.transfer_quantity > 0
    union all
    select e.production_location_id, 'REMOVE'::text,
      round(e.retirement_quantity * coalesce(e.actual_retirement_price, 0), 2)
    from eligible e where e.retirement_quantity > 0
  ), approved as (
    select coalesce(sum(a.value), 0) approved_total,
      coalesce(sum(a.value) filter (where not exists (
        select 1 from public.billing_export_lines line
        where line.company_id = v_company
          and line.production_location_id = a.production_location_id
          and line.work_type = a.work_type and line.active
      )), 0) approved_unbilled
    from actions a
  ), batches as (
    select
      coalesce(sum(case when b.status not in ('void', 'draft') and b.billing_type <> 'credit'
                        then b.total_value else 0 end), 0) billed,
      coalesce(sum(case when b.status not in ('void', 'draft') and b.billing_type = 'credit'
                        then b.total_value else 0 end), 0) credits,
      count(*) filter (where b.status not in ('void', 'draft')) active_batches,
      count(*) filter (where b.status not in ('void', 'draft') and b.billing_type = 'final') finals
    from public.billing_export_batches b
    where b.company_id = v_company and b.job_id = p_job_id
  ), reports as (
    select count(*) filter (where lower(coalesce(r.status, '')) = 'submitted') awaiting,
      count(*) filter (where lower(coalesce(r.status, '')) in ('draft', 'returned')) drafts
    from public.daily_reports r
    where r.company_id = v_company and r.job_id = p_job_id and not r.archived
  )
  select p_job_id, coalesce(p.authorized_value, 0), a.approved_total,
    greatest(coalesce(p.remaining_value, 0), 0), b.billed, abs(b.credits), b.billed + b.credits,
    a.approved_unbilled, r.awaiting, r.drafts, coalesce(p.pending_packet_count, 0),
    coalesce(p.redline_count, 0), b.active_batches, b.finals
  from progress p cross join approved a cross join batches b cross join reports r;
end;
$$;

-- The transfer-aware location function must feed every progress/authorization consumer.
create or replace function public.get_daily_report_authorization_summaries()
returns table(
  report_id uuid, unit_entry_count bigint, authorized_count bigint,
  pending_packet_count bigint, redline_count bigint
)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_company_id uuid; v_role text; v_active boolean; v_role_permissions jsonb;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active,
         coalesce(profile.role_permissions, '{}'::jsonb)
  into v_company_id, v_role, v_active, v_role_permissions
  from public.profiles profile where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin', 'owner', 'gf', 'superintendent') then
    raise exception using errcode = '42501',
      message = 'Only active company leadership can view production summaries.';
  end if;
  if v_role = 'superintendent' and
     not public.linecrew_has_capability('production_review') and
     not public.linecrew_has_capability('reporting') then
    raise exception using errcode = '42501',
      message = 'Production visibility is disabled for this Superintendent.';
  end if;

  return query
  select report.id, count(location.location_line_id),
    count(*) filter (where location.authorization_status = 'authorized'),
    count(*) filter (where location.authorization_status = 'pending_packet'),
    count(*) filter (where location.authorization_status = 'redline')
  from public.daily_reports report
  left join lateral public.get_daily_report_unit_locations_v2(report.id) location on true
  where report.company_id = v_company_id
  group by report.id;
end;
$$;

create or replace function public.get_job_progress_dashboard()
returns table(
  job_id uuid, package_count bigint, work_point_count bigint,
  authorized_value numeric, reported_value numeric, approved_value numeric,
  remaining_value numeric, reported_percent numeric, approved_percent numeric,
  report_count bigint, redline_count bigint, pending_packet_count bigint
)
language plpgsql stable security definer set search_path = '' as $$
declare v_company_id uuid; v_role text; v_active boolean;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile where profile.id = auth.uid();
  if v_company_id is null or v_active is not true or
     v_role not in ('admin', 'gf', 'owner', 'superintendent') then
    raise exception using errcode = '42501',
      message = 'Only active company leadership can view job progress.';
  end if;
  if v_role = 'superintendent' and not public.linecrew_has_capability('reporting') then
    raise exception using errcode = '42501',
      message = 'This Superintendent does not have reporting permission.';
  end if;

  return query
  with package_totals as (
    select package.job_id, count(distinct package.id)::bigint package_count,
      count(distinct progress.work_point_id)::bigint work_point_count,
      coalesce(sum(progress.authorized_value), 0)::numeric authorized_value,
      coalesce(sum(progress.reported_value), 0)::numeric reported_value,
      coalesce(sum(progress.approved_value), 0)::numeric approved_value
    from public.job_packages package
    left join lateral public.get_job_package_work_points(package.id) progress on true
    where package.company_id = v_company_id and package.status = 'active'
    group by package.job_id
  ), report_totals as (
    select report.job_id, count(distinct report.id)::bigint report_count
    from public.daily_reports report
    where report.company_id = v_company_id and report.archived is not true
    group by report.job_id
  ), exception_totals as (
    select report.job_id,
      count(*) filter (where location.authorization_status = 'redline')::bigint redline_count,
      count(*) filter (where location.authorization_status = 'pending_packet')::bigint pending_packet_count
    from public.daily_reports report
    cross join lateral public.get_daily_report_unit_locations_v2(report.id) location
    where report.company_id = v_company_id and report.archived is not true
      and lower(coalesce(report.status, 'draft')) <> 'rejected'
    group by report.job_id
  )
  select job.id, coalesce(package.package_count, 0), coalesce(package.work_point_count, 0),
    coalesce(package.authorized_value, 0), coalesce(package.reported_value, 0),
    coalesce(package.approved_value, 0),
    greatest(coalesce(package.authorized_value, 0) - coalesce(package.reported_value, 0), 0),
    case when coalesce(package.authorized_value, 0) > 0
      then round(least(package.reported_value / package.authorized_value * 100, 100), 1) else 0 end,
    case when coalesce(package.authorized_value, 0) > 0
      then round(least(package.approved_value / package.authorized_value * 100, 100), 1) else 0 end,
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

-- A Final Bill override is a break-glass Owner action, not a free-form bypass.
create or replace function public.create_billing_export_batch_v3(
  p_job_id uuid, p_date_from date default null, p_date_to date default null,
  p_separate_redline_summary boolean default false, p_notes text default null,
  p_is_final boolean default false, p_final_override_reason text default null
)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_rec record; v_id uuid; v_role text;
begin
  if coalesce(p_is_final, false) then
    select * into v_rec from public.get_job_billing_reconciliation(p_job_id);
    if v_rec.remaining_authorized_value > 0.01 or v_rec.awaiting_review_count > 0 or
       v_rec.draft_report_count > 0 or v_rec.pending_packet_count > 0 then
      if nullif(btrim(coalesce(p_final_override_reason, '')), '') is null then
        raise exception using errcode = '23514', message =
          'Final Bill has unresolved work or reports. Enter an override reason to continue.';
      end if;
      select lower(coalesce(p.role, '')) into v_role
      from public.profiles p where p.id = auth.uid() and p.active;
      if v_role <> 'owner' then
        raise exception using errcode = '42501', message =
          'Only the Company Owner can override unresolved Final Bill blockers.';
      end if;
    end if;
  end if;
  v_id := public.create_billing_export_batch_v2(
    p_job_id, p_date_from, p_date_to, p_separate_redline_summary, p_notes, p_is_final
  );
  if p_is_final then
    update public.billing_export_batches set
      final_override_reason = nullif(btrim(coalesce(p_final_override_reason, '')), ''),
      updated_at = now(), updated_by = auth.uid()
    where id = v_id;
  end if;
  return v_id;
end;
$$;

revoke all on function public.approve_daily_report(uuid, text) from public, anon;
grant execute on function public.approve_daily_report(uuid, text) to authenticated;
revoke all on function public.delete_draft_daily_report(uuid) from public, anon;
grant execute on function public.delete_draft_daily_report(uuid) to authenticated;
revoke all on function public.get_job_billing_reconciliation(uuid) from public, anon;
grant execute on function public.get_job_billing_reconciliation(uuid) to authenticated;
revoke all on function public.get_daily_report_authorization_summaries() from public, anon;
grant execute on function public.get_daily_report_authorization_summaries() to authenticated;
revoke all on function public.get_job_progress_dashboard() from public, anon;
grant execute on function public.get_job_progress_dashboard() to authenticated;
revoke all on function public.create_billing_export_batch_v3(uuid,date,date,boolean,text,boolean,text)
  from public, anon;
grant execute on function public.create_billing_export_batch_v3(uuid,date,date,boolean,text,boolean,text)
  to authenticated;

commit;
