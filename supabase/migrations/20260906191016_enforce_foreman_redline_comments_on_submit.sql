create or replace function public.enforce_daily_report_redline_comments()
returns trigger
language plpgsql
set search_path to ''
as $$
begin
  if new.status = 'submitted' and old.status is distinct from 'submitted' and
     exists (
       select 1
       from public.get_daily_report_unit_locations_visible_v2(new.id) item
       join public.daily_production_unit_locations location
         on location.id = item.location_line_id
        and location.company_id = new.company_id
       where item.authorization_status = 'redline'
         and nullif(btrim(coalesce(location.redline_comment, '')), '') is null
     ) then
    raise exception using
      errcode = '22023',
      message = 'Add a comment explaining each redline before submitting this daily report.';
  end if;
  return new;
end;
$$;

drop trigger if exists enforce_daily_report_redline_comments_trigger
  on public.daily_reports;
create trigger enforce_daily_report_redline_comments_trigger
before update of status on public.daily_reports
for each row
execute function public.enforce_daily_report_redline_comments();

revoke all on function public.enforce_daily_report_redline_comments()
  from public, anon, authenticated;
grant execute on function public.enforce_daily_report_redline_comments()
  to service_role;
