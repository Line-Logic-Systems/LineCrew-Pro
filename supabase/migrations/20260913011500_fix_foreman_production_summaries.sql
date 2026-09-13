create or replace function public.get_daily_report_authorization_summaries()
returns table(
  report_id uuid,
  unit_entry_count bigint,
  authorized_count bigint,
  pending_packet_count bigint,
  redline_count bigint
)
language plpgsql stable security definer set search_path=''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  select profile.company_id,lower(coalesce(profile.role,'')),profile.active
    into v_company_id,v_role,v_active
  from public.profiles profile
  where profile.id=auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('owner','manager','admin','superintendent','gf','foreman') then
    raise exception using errcode='42501',
      message='Active company production access is required.';
  end if;
  if v_role='superintendent' and
     not public.linecrew_has_capability('production_review') and
     not public.linecrew_has_capability('reporting') then
    raise exception using errcode='42501',
      message='Production visibility is disabled for this Superintendent.';
  end if;

  return query
  select report.id,count(location.location_line_id),
    count(*) filter(where location.authorization_status='authorized'),
    count(*) filter(where location.authorization_status='pending_packet'),
    count(*) filter(where location.authorization_status='redline')
  from public.daily_reports report
  left join lateral public.get_daily_report_unit_locations_v2(report.id) location on true
  where report.company_id=v_company_id
    and (v_role<>'foreman' or report.foreman_id=auth.uid() or report.created_by=auth.uid())
  group by report.id;
end;
$$;

revoke all on function public.get_daily_report_authorization_summaries() from public,anon;
grant execute on function public.get_daily_report_authorization_summaries() to authenticated,service_role;

comment on function public.get_daily_report_authorization_summaries() is
  'Company leadership sees company summaries; Foremen see only their own report summaries so their redline counts remain accurate without exposing another crew.';
