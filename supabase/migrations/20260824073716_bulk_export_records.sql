begin;

-- Return the two report-level collections used by the completed-job archive in
-- one request.  The existing report RPCs remain the source of truth for unit
-- authorization, visible pricing, audit ordering, and role checks.
create or replace function public.get_completed_job_export_details_v1(p_job_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_units jsonb;
  v_audit jsonb;
begin
  select p.company_id, lower(coalesce(p.role, '')), p.active
  into v_company_id, v_role, v_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('owner', 'admin', 'superintendent', 'gf') then
    raise exception using errcode = '42501',
      message = 'Completed job access is required.';
  end if;

  if not exists (
    select 1
    from public.jobs j
    where j.id = p_job_id
      and j.company_id = v_company_id
      and j.active = false
  ) then
    raise exception using errcode = 'P0002',
      message = 'Completed job was not found in your company.';
  end if;

  select coalesce(
    jsonb_agg(
      to_jsonb(unit_row) || jsonb_build_object(
        'report_id', report.id,
        'work_date', report.work_date,
        'foreman_name', report.foreman_name,
        'crew_name', report.crew_name
      )
      order by report.work_date, report.id, unit_row.pole_location, unit_row.item_code,
        unit_row.location_line_id
    ),
    '[]'::jsonb
  )
  into v_units
  from public.daily_reports report
  cross join lateral public.get_daily_report_unit_locations_v2(report.id) unit_row
  where report.company_id = v_company_id
    and report.job_id = p_job_id;

  select coalesce(
    jsonb_agg(
      to_jsonb(audit_row) || jsonb_build_object(
        'report_id', report.id,
        'work_date', report.work_date
      )
      order by report.work_date, report.id, audit_row.event_at desc, audit_row.event_id desc
    ),
    '[]'::jsonb
  )
  into v_audit
  from public.daily_reports report
  cross join lateral public.get_daily_report_audit_history(report.id) audit_row
  where report.company_id = v_company_id
    and report.job_id = p_job_id;

  return jsonb_build_object('units', v_units, 'audit', v_audit);
end;
$$;

-- Return every line and attachment for every retained billing batch on one job.
-- Batch summaries still come from get_billing_export_batches_v4, so this RPC
-- only replaces the per-batch detail loop used by complete exports.
create or replace function public.get_complete_job_billing_export_details_v1(p_job_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_lines jsonb;
  v_attachments jsonb;
begin
  if not public.linecrew_can_use_billing_exports_internal() then
    raise exception using errcode = '42501',
      message = 'Billing export access is required.';
  end if;

  select p.company_id
  into v_company_id
  from public.profiles p
  where p.id = auth.uid()
    and p.active = true;

  if not exists (
    select 1
    from public.jobs j
    where j.id = p_job_id
      and j.company_id = v_company_id
  ) then
    raise exception using errcode = 'P0002',
      message = 'Job was not found in your company.';
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'batch_id', batch.id,
        'line_id', line.id,
        'batch_number', batch.batch_number,
        'job_number', job.job_number,
        'job_name', job.job_name,
        'customer_name', job.customer_name,
        'utility_name', job.utility_name,
        'report_date', line.report_date,
        'foreman_name', line.foreman_name,
        'crew_name', line.crew_name,
        'work_point', line.work_point,
        'unit_code', line.unit_code,
        'unit_name', line.unit_name,
        'unit_description', line.unit_description,
        'work_type', line.work_type,
        'quantity', line.quantity,
        'unit_price', line.unit_price,
        'extended_value', line.extended_value,
        'authorization_status', line.authorization_status
      )
      order by batch.created_at, batch.id,
        case when line.authorization_status = 'authorized' then 0 else 1 end,
        line.report_date, line.work_point, line.unit_code, line.work_type, line.id
    ),
    '[]'::jsonb
  )
  into v_lines
  from public.billing_export_batches batch
  join public.billing_export_lines line
    on line.billing_batch_id = batch.id
   and line.company_id = batch.company_id
  join public.jobs job
    on job.id = line.job_id
   and job.company_id = line.company_id
  where batch.company_id = v_company_id
    and batch.job_id = p_job_id;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'batch_id', attachment.billing_batch_id,
        'id', attachment.id,
        'storage_path', attachment.storage_path,
        'original_filename', attachment.original_filename,
        'mime_type', attachment.mime_type,
        'file_size_bytes', attachment.file_size_bytes,
        'caption', attachment.caption,
        'uploaded_by', attachment.uploaded_by,
        'created_at', attachment.created_at
      )
      order by batch.created_at, batch.id, attachment.created_at, attachment.id
    ),
    '[]'::jsonb
  )
  into v_attachments
  from public.billing_export_batches batch
  join public.billing_export_attachments attachment
    on attachment.billing_batch_id = batch.id
   and attachment.company_id = batch.company_id
  where batch.company_id = v_company_id
    and batch.job_id = p_job_id;

  return jsonb_build_object('lines', v_lines, 'attachments', v_attachments);
end;
$$;

revoke all on function public.get_completed_job_export_details_v1(uuid) from public, anon;
revoke all on function public.get_complete_job_billing_export_details_v1(uuid) from public, anon;
grant execute on function public.get_completed_job_export_details_v1(uuid) to authenticated;
grant execute on function public.get_complete_job_billing_export_details_v1(uuid) to authenticated;

commit;
