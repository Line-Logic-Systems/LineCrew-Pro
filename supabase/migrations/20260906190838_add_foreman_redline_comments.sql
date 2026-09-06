alter table public.daily_production_unit_locations
  add column if not exists redline_comment text;

alter table public.daily_production_unit_locations
  drop constraint if exists daily_production_unit_locations_redline_comment_length;

alter table public.daily_production_unit_locations
  add constraint daily_production_unit_locations_redline_comment_length
  check (
    redline_comment is null or
    char_length(btrim(redline_comment)) between 1 and 1000
  );

create or replace function public.get_daily_report_unit_locations_visible_v3(
  p_report_id uuid
) returns table(
  location_line_id uuid,
  price_book_item_id uuid,
  item_code text,
  item_name text,
  description text,
  unit_of_measure text,
  category text,
  pole_location text,
  install_price numeric,
  retirement_price numeric,
  actual_install_price numeric,
  actual_retirement_price numeric,
  adjusted_install_price numeric,
  adjusted_retirement_price numeric,
  has_adjustment boolean,
  install_quantity numeric,
  transfer_quantity numeric,
  retirement_quantity numeric,
  actual_line_value numeric,
  adjusted_line_value numeric,
  visible_line_value numeric,
  authorization_status text,
  authorization_note text,
  redline_comment text
)
language sql
stable
security definer
set search_path to ''
as $$
  select item.*, location.redline_comment
  from public.get_daily_report_unit_locations_visible_v2(p_report_id) item
  join public.daily_production_unit_locations location
    on location.id = item.location_line_id
   and location.company_id = public.my_company_id();
$$;

revoke all on function public.get_daily_report_unit_locations_visible_v3(uuid)
  from public;
grant execute on function public.get_daily_report_unit_locations_visible_v3(uuid)
  to authenticated, service_role;

create or replace function public.save_daily_report_unit_redline_comment(
  p_location_line_id uuid,
  p_comment text
) returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_report_id uuid;
  v_report_creator uuid;
  v_report_status text;
  v_authorization_status text;
  v_comment text := nullif(btrim(coalesce(p_comment, '')), '');
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
    into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or not v_active or
     v_role not in ('foreman','gf','superintendent','admin','owner') then
    raise exception using
      errcode = '42501',
      message = 'An active production profile is required.';
  end if;

  select location.daily_report_id, report.created_by,
         lower(coalesce(report.status, 'draft'))
    into v_report_id, v_report_creator, v_report_status
  from public.daily_production_unit_locations location
  join public.daily_reports report
    on report.id = location.daily_report_id
   and report.company_id = location.company_id
  where location.id = p_location_line_id
    and location.company_id = v_company_id;

  if v_report_id is null then
    raise exception using
      errcode = 'P0002',
      message = 'Daily report unit was not found in your company.';
  end if;
  if v_report_status <> 'draft' then
    raise exception using
      errcode = '42501',
      message = 'Redline comments can be changed only while the report is a draft.';
  end if;
  if v_role = 'foreman' and v_report_creator is distinct from auth.uid() then
    raise exception using
      errcode = '42501',
      message = 'Foremen can comment only on their own reports.';
  end if;
  if v_comment is null then
    raise exception using
      errcode = '22023',
      message = 'Enter a redline comment.';
  end if;
  if char_length(v_comment) > 1000 then
    raise exception using
      errcode = '22023',
      message = 'Redline comments must be 1,000 characters or fewer.';
  end if;

  select item.authorization_status
    into v_authorization_status
  from public.get_daily_report_unit_locations_visible_v2(v_report_id) item
  where item.location_line_id = p_location_line_id;

  if coalesce(v_authorization_status, '') <> 'redline' then
    raise exception using
      errcode = '22023',
      message = 'A redline comment is required only for a redline unit.';
  end if;

  update public.daily_production_unit_locations
  set redline_comment = v_comment,
      updated_at = now()
  where id = p_location_line_id
    and company_id = v_company_id;
end;
$$;

revoke all on function public.save_daily_report_unit_redline_comment(uuid, text)
  from public;
grant execute on function public.save_daily_report_unit_redline_comment(uuid, text)
  to authenticated, service_role;

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
