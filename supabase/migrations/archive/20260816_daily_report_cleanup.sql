begin;

alter table public.daily_reports
  add column if not exists archived boolean not null default false;

create index if not exists daily_reports_company_archived_work_date_idx
  on public.daily_reports (company_id, archived, work_date desc);

create or replace function public.delete_draft_daily_report(p_report_id uuid)
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
      message = 'Only an active company Admin can delete draft daily reports.';
  end if;

  delete from public.daily_reports report
  where report.id = p_report_id
    and report.company_id = v_company_id
    and lower(coalesce(report.status, 'draft')) = 'draft';

  if not found then
    raise exception using errcode = 'P0002',
      message = 'Draft report was not found in your company. Submitted and approved reports must be archived.';
  end if;
end;
$$;

revoke all on function public.delete_draft_daily_report(uuid) from public, anon;
grant execute on function public.delete_draft_daily_report(uuid) to authenticated;

create or replace function public.set_daily_report_archived(
  p_report_id uuid,
  p_archived boolean
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
      message = 'Only an active company Admin can archive daily reports.';
  end if;

  update public.daily_reports report
  set archived = coalesce(p_archived, false)
  where report.id = p_report_id
    and report.company_id = v_company_id
    and (
      coalesce(p_archived, false) is false or
      lower(coalesce(report.status, '')) = 'approved'
    );

  if not found then
    raise exception using errcode = 'P0002',
      message = 'Only approved reports can be archived. Draft reports may be deleted instead.';
  end if;
end;
$$;

revoke all on function public.set_daily_report_archived(uuid, boolean) from public, anon;
grant execute on function public.set_daily_report_archived(uuid, boolean) to authenticated;

commit;
