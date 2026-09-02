create or replace function public.approve_daily_report(p_report_id uuid, p_review_notes text default null::text)
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
     v_role not in ('admin', 'gf') then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin or General Foreman can approve reports.';
  end if;

  select report.company_id, lower(coalesce(report.status, 'draft')), report.review_notes
  into v_report_company_id, v_report_status, v_existing_notes
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

  select company.require_gf_redline_approval
  into v_require_gf
  from public.companies company
  where company.id = v_company_id;

  select count(*)
  into v_redline_count
  from public.get_daily_report_unit_locations(p_report_id) location
  where location.authorization_status = 'redline';

  v_new_note := nullif(btrim(coalesce(p_review_notes, '')), '');

  if coalesce(v_require_gf, false) and v_redline_count > 0 and v_role = 'admin' and
     v_new_note is null then
    raise exception using errcode = '22023',
      message = 'Enter an Admin override reason because this company requires GF approval for redlines.';
  end if;

  update public.daily_reports report
  set
    status = 'approved',
    review_notes = case
      when v_new_note is null then v_existing_notes
      when nullif(btrim(coalesce(v_existing_notes,'')), '') is null then v_new_note
      else btrim(v_existing_notes) || E'\n\nGF APPROVAL:\n' || v_new_note
    end,
    redline_override_by = case
      when coalesce(v_require_gf, false) and v_redline_count > 0 and v_role = 'admin'
        then auth.uid() else null end,
    redline_override_reason = case
      when coalesce(v_require_gf, false) and v_redline_count > 0 and v_role = 'admin'
        then v_new_note else null end,
    redline_override_at = case
      when coalesce(v_require_gf, false) and v_redline_count > 0 and v_role = 'admin'
        then now() else null end
  where report.id = p_report_id
    and report.company_id = v_company_id;
end;
$$;

