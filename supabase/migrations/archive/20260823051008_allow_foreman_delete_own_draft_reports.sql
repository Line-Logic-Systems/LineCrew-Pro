begin;

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
    raise exception using errcode = '42501', message = 'This Superintendent does not have production review permission.';
  end if;

  if v_role not in ('owner', 'admin', 'superintendent', 'foreman') then
    raise exception using errcode = '42501', message = 'You do not have permission to delete draft Daily Reports.';
  end if;

  if not exists (
    select 1
    from public.daily_reports report
    where report.id = p_report_id
      and report.company_id = v_company_id
      and lower(coalesce(report.status, 'draft')) = 'draft'
      and (
        v_role in ('owner', 'admin', 'superintendent')
        or (v_role = 'foreman' and report.foreman_id = auth.uid())
      )
  ) then
    raise exception using errcode = 'P0002',
      message = 'Draft report was not found or cannot be deleted. Foremen may delete only their own drafts.';
  end if;

  delete from public.timekeeping_entries entry
  where entry.daily_report_id = p_report_id
    and entry.company_id = v_company_id;

  delete from public.daily_reports report
  where report.id = p_report_id
    and report.company_id = v_company_id
    and lower(coalesce(report.status, 'draft')) = 'draft';
end;
$$;

revoke all on function public.delete_draft_daily_report(uuid) from public, anon;
grant execute on function public.delete_draft_daily_report(uuid) to authenticated;

commit;
