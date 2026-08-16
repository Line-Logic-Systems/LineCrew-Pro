begin;

alter table public.companies
  add column if not exists require_gf_redline_approval boolean not null default false;

alter table public.daily_reports
  add column if not exists redline_override_by uuid null
    references auth.users(id) on delete set null;

alter table public.daily_reports
  add column if not exists redline_override_reason text null;

alter table public.daily_reports
  add column if not exists redline_override_at timestamptz null;

create or replace function public.set_company_redline_approval_requirement(
  p_required boolean
)
returns void
language plpgsql
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

  if v_company_id is null or v_active is not true or v_role <> 'admin' then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin can change redline approval requirements.';
  end if;

  update public.companies company
  set require_gf_redline_approval = coalesce(p_required, false)
  where company.id = v_company_id;
end;
$$;

revoke all on function public.set_company_redline_approval_requirement(boolean)
from public, anon;
grant execute on function public.set_company_redline_approval_requirement(boolean)
to authenticated;

create or replace function public.get_daily_report_authorization_summaries()
returns table (
  report_id uuid,
  unit_entry_count bigint,
  authorized_count bigint,
  pending_packet_count bigint,
  redline_count bigint
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
      message = 'Only an active company Admin or General Foreman can view the review queue.';
  end if;

  return query
  select
    report.id,
    count(location.location_line_id),
    count(*) filter (where location.authorization_status = 'authorized'),
    count(*) filter (where location.authorization_status = 'pending_packet'),
    count(*) filter (where location.authorization_status = 'redline')
  from public.daily_reports report
  left join lateral public.get_daily_report_unit_locations(report.id) location
    on true
  where report.company_id = v_company_id
  group by report.id;
end;
$$;

revoke all on function public.get_daily_report_authorization_summaries()
from public, anon;
grant execute on function public.get_daily_report_authorization_summaries()
to authenticated;

create or replace function public.approve_daily_report(
  p_report_id uuid,
  p_review_notes text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_report_company_id uuid;
  v_report_status text;
  v_require_gf boolean;
  v_redline_count bigint;
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

  select report.company_id, lower(coalesce(report.status, 'draft'))
  into v_report_company_id, v_report_status
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

  if coalesce(v_require_gf, false) and v_redline_count > 0 and v_role = 'admin' and
     nullif(btrim(coalesce(p_review_notes, '')), '') is null then
    raise exception using errcode = '22023',
      message = 'Enter an Admin override reason because this company requires GF approval for redlines.';
  end if;

  update public.daily_reports report
  set
    status = 'approved',
    review_notes = nullif(btrim(coalesce(p_review_notes, '')), ''),
    redline_override_by = case
      when coalesce(v_require_gf, false) and v_redline_count > 0 and v_role = 'admin'
        then auth.uid() else null end,
    redline_override_reason = case
      when coalesce(v_require_gf, false) and v_redline_count > 0 and v_role = 'admin'
        then btrim(p_review_notes) else null end,
    redline_override_at = case
      when coalesce(v_require_gf, false) and v_redline_count > 0 and v_role = 'admin'
        then now() else null end
  where report.id = p_report_id
    and report.company_id = v_company_id;
end;
$$;

revoke all on function public.approve_daily_report(uuid, text) from public, anon;
grant execute on function public.approve_daily_report(uuid, text) to authenticated;

commit;
