begin;

alter table public.price_book_items
  add column if not exists transfer_price numeric(12,2) not null default 0;

update public.price_book_items
set transfer_price = coalesce(install_price, 0)
where transfer_price = 0;

alter table public.price_book_items
  drop constraint if exists price_book_items_transfer_price_nonnegative,
  add constraint price_book_items_transfer_price_nonnegative
    check (transfer_price >= 0);

alter table public.daily_production_units
  add column if not exists actual_transfer_price numeric(14,2),
  add column if not exists adjusted_transfer_price numeric(14,2);

update public.daily_production_units
set actual_transfer_price = coalesce(actual_transfer_price, actual_install_price),
    adjusted_transfer_price = coalesce(adjusted_transfer_price, adjusted_install_price)
where actual_transfer_price is null or adjusted_transfer_price is null;

alter table public.daily_production_units
  alter column actual_transfer_price set not null,
  alter column adjusted_transfer_price set not null;

create or replace function public.set_daily_production_transfer_price_snapshot()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_transfer_price numeric;
begin
  select item.transfer_price
  into v_transfer_price
  from public.price_book_items item
  where item.id = new.price_book_item_id
    and item.company_id = new.company_id
    and item.price_book_id = new.price_book_id;

  if v_transfer_price is null then
    raise exception using
      errcode = 'P0002',
      message = 'Transfer pricing was not found for this unit.';
  end if;

  new.actual_transfer_price := v_transfer_price;
  new.adjusted_transfer_price := round(
    v_transfer_price * coalesce(new.field_value_percent_snapshot, 100) / 100,
    2
  );
  return new;
end;
$$;

drop trigger if exists set_daily_production_transfer_price_snapshot
on public.daily_production_units;
create trigger set_daily_production_transfer_price_snapshot
before insert or update of price_book_item_id, price_book_id, company_id,
  field_value_percent_snapshot, actual_install_price, adjusted_install_price
on public.daily_production_units
for each row execute function public.set_daily_production_transfer_price_snapshot();

revoke all on function public.set_daily_production_transfer_price_snapshot()
from public, anon, authenticated;

drop function if exists public.get_price_book_items_for_user(uuid);
create function public.get_price_book_items_for_user(p_price_book_id uuid)
returns table (
  id uuid, company_id uuid, price_book_id uuid, item_code text, item_name text,
  description text, install_price numeric, transfer_price numeric,
  retirement_price numeric, unit_of_measure text, category text, extra_data jsonb,
  active boolean, created_at timestamptz, updated_at timestamptz,
  actual_install_price numeric, actual_transfer_price numeric,
  actual_retirement_price numeric, adjusted_install_price numeric,
  adjusted_transfer_price numeric, adjusted_retirement_price numeric,
  has_adjustment boolean
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
  v_can_see_actual boolean;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true then
    raise exception using errcode = '42501',
      message = 'An active company profile is required.';
  end if;
  if v_role not in ('foreman', 'gf', 'admin', 'owner', 'superintendent') then
    raise exception using errcode = '42501',
      message = 'Your role cannot view contract unit values.';
  end if;
  if v_role = 'superintendent' and not public.linecrew_has_capability('price_books') then
    raise exception using errcode = '42501',
      message = 'This Superintendent does not have price books permission.';
  end if;
  if not exists (
    select 1 from public.price_books book
    where book.id = p_price_book_id and book.company_id = v_company_id
  ) then
    raise exception using errcode = 'P0002',
      message = 'Price Book was not found in your company.';
  end if;

  v_can_see_actual := v_role in ('admin', 'owner', 'gf') or
    (v_role = 'superintendent' and public.linecrew_has_capability('actual_pricing'));

  return query
  select item.id, item.company_id, item.price_book_id, item.item_code,
    item.item_name, item.description,
    case when v_can_see_actual then item.install_price
      else round(item.install_price * coalesce(setting.field_value_percent, 100) / 100, 2) end,
    case when v_can_see_actual then item.transfer_price
      else round(item.transfer_price * coalesce(setting.field_value_percent, 100) / 100, 2) end,
    case when v_can_see_actual then item.retirement_price
      else round(item.retirement_price * coalesce(setting.field_value_percent, 100) / 100, 2) end,
    item.unit_of_measure, item.category, item.extra_data, item.active,
    item.created_at, item.updated_at,
    case when v_can_see_actual then item.install_price else null end,
    case when v_can_see_actual then item.transfer_price else null end,
    case when v_can_see_actual then item.retirement_price else null end,
    round(item.install_price * coalesce(setting.field_value_percent, 100) / 100, 2),
    round(item.transfer_price * coalesce(setting.field_value_percent, 100) / 100, 2),
    round(item.retirement_price * coalesce(setting.field_value_percent, 100) / 100, 2),
    setting.field_value_percent is not null
  from public.price_book_items item
  join public.price_books book
    on book.id = item.price_book_id and book.company_id = item.company_id
  left join public.contract_field_settings setting
    on setting.contract_id = book.contract_id and setting.company_id = item.company_id
  where item.price_book_id = p_price_book_id and item.company_id = v_company_id
  order by item.active desc, item.item_code;
end;
$$;

revoke all on function public.get_price_book_items_for_user(uuid) from public, anon;
grant execute on function public.get_price_book_items_for_user(uuid) to authenticated;

create or replace function public.get_daily_report_unit_locations_v2(p_report_id uuid)
returns table(
  location_line_id uuid, price_book_item_id uuid, item_code text, item_name text,
  description text, unit_of_measure text, category text, pole_location text,
  install_price numeric, retirement_price numeric, actual_install_price numeric,
  actual_retirement_price numeric, adjusted_install_price numeric,
  adjusted_retirement_price numeric, has_adjustment boolean,
  install_quantity numeric, transfer_quantity numeric, retirement_quantity numeric,
  actual_line_value numeric, adjusted_line_value numeric, visible_line_value numeric,
  authorization_status text, authorization_note text
)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_company_id uuid; v_role text; v_active boolean; v_report_company_id uuid;
  v_report_creator uuid; v_report_job_id uuid; v_can_see_actual boolean;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile where profile.id = auth.uid();
  if v_company_id is null or not v_active or
     v_role not in ('foreman', 'gf', 'superintendent', 'admin', 'owner') then
    raise exception using errcode = '42501',
      message = 'An active production profile is required.';
  end if;
  select report.company_id, report.created_by, report.job_id
  into v_report_company_id, v_report_creator, v_report_job_id
  from public.daily_reports report where report.id = p_report_id;
  if v_report_company_id is null or v_report_company_id <> v_company_id then
    raise exception using errcode = 'P0002',
      message = 'Daily report was not found in your company.';
  end if;
  if v_role = 'foreman' and v_report_creator is distinct from auth.uid() then
    raise exception using errcode = '42501',
      message = 'Foremen can view unit production only on their own reports.';
  end if;
  v_can_see_actual := v_role in ('admin', 'gf', 'owner') or
    (v_role = 'superintendent' and public.linecrew_has_capability('actual_pricing'));

  return query
  select location.id, unit.price_book_item_id, unit.item_code, unit.item_name,
    unit.description, unit.unit_of_measure, unit.category, location.pole_location,
    case when v_can_see_actual then unit.actual_install_price else unit.adjusted_install_price end,
    case when v_can_see_actual then unit.actual_retirement_price else unit.adjusted_retirement_price end,
    case when v_can_see_actual then unit.actual_install_price else null end,
    case when v_can_see_actual then unit.actual_retirement_price else null end,
    unit.adjusted_install_price, unit.adjusted_retirement_price, unit.has_adjustment,
    location.install_quantity, location.transfer_quantity, location.retirement_quantity,
    case when v_can_see_actual then round(
      location.install_quantity * unit.actual_install_price +
      location.transfer_quantity * unit.actual_transfer_price +
      location.retirement_quantity * unit.actual_retirement_price, 2
    ) else null end,
    round(
      location.install_quantity * unit.adjusted_install_price +
      location.transfer_quantity * unit.adjusted_transfer_price +
      location.retirement_quantity * unit.adjusted_retirement_price, 2
    ),
    case when v_can_see_actual then round(
      location.install_quantity * unit.actual_install_price +
      location.transfer_quantity * unit.actual_transfer_price +
      location.retirement_quantity * unit.actual_retirement_price, 2
    ) else round(
      location.install_quantity * unit.adjusted_install_price +
      location.transfer_quantity * unit.adjusted_transfer_price +
      location.retirement_quantity * unit.adjusted_retirement_price, 2
    ) end,
    case when packages.package_count = 0 then 'pending_packet'
      when authorizations.authorized_unit_count = 0 then 'redline'
      when production.reported_install > authorizations.authorized_install or
           production.reported_transfer > authorizations.authorized_transfer or
           production.reported_retirement > authorizations.authorized_retirement then 'redline'
      else 'authorized' end,
    case when packages.package_count = 0 then
      'No active utility job packet has been added yet. This entry will reconcile when a packet is imported.'
      when authorizations.authorized_unit_count = 0 then
      'This unit is not authorized at this pole or work point in the active utility job packet.'
      when production.reported_install > authorizations.authorized_install or
           production.reported_transfer > authorizations.authorized_transfer or
           production.reported_retirement > authorizations.authorized_retirement then
      'Reported quantity exceeds the active utility-authorized quantity at this pole or work point.'
      else null end
  from public.daily_production_unit_locations location
  join public.daily_production_units unit
    on unit.id = location.daily_production_unit_id
   and unit.company_id = location.company_id
   and unit.daily_report_id = location.daily_report_id
   and unit.price_book_item_id = location.price_book_item_id
  cross join lateral (
    select count(*)::integer package_count
    from public.job_packages package
    where package.company_id = v_company_id and package.job_id = v_report_job_id
      and package.status = 'active'
  ) packages
  cross join lateral (
    select count(authorized.id)::integer authorized_unit_count,
      coalesce(sum(authorized.authorized_install_quantity), 0) authorized_install,
      coalesce(sum(authorized.authorized_transfer_quantity), 0) authorized_transfer,
      coalesce(sum(authorized.authorized_retirement_quantity), 0) authorized_retirement
    from public.job_packages package
    join public.job_package_work_points work_point
      on work_point.job_package_id = package.id and work_point.company_id = package.company_id
    join public.job_package_authorized_units authorized
      on authorized.work_point_id = work_point.id and authorized.company_id = work_point.company_id
    where package.company_id = v_company_id and package.job_id = v_report_job_id
      and package.status = 'active'
      and public.normalize_work_point_key(work_point.work_point_code) =
          public.normalize_work_point_key(location.pole_location)
      and authorized.price_book_item_id = location.price_book_item_id
  ) authorizations
  cross join lateral (
    select coalesce(sum(other.install_quantity), 0) reported_install,
      coalesce(sum(other.transfer_quantity), 0) reported_transfer,
      coalesce(sum(other.retirement_quantity), 0) reported_retirement
    from public.daily_production_unit_locations other
    join public.daily_reports report
      on report.id = other.daily_report_id and report.company_id = other.company_id
    where other.company_id = v_company_id and report.job_id = v_report_job_id
      and lower(coalesce(report.status, '')) <> 'rejected'
      and other.price_book_item_id = location.price_book_item_id
      and public.normalize_work_point_key(other.pole_location) =
          public.normalize_work_point_key(location.pole_location)
  ) production
  where location.daily_report_id = p_report_id and location.company_id = v_company_id
  order by location.pole_location_key, unit.item_code;
end;
$$;

revoke all on function public.get_daily_report_unit_locations_v2(uuid) from public, anon;
grant execute on function public.get_daily_report_unit_locations_v2(uuid) to authenticated;

create or replace function public.get_daily_report_value_summaries()
returns table(
  report_id uuid, unit_line_count bigint, actual_total numeric,
  adjusted_total numeric, visible_total numeric, has_adjustment boolean
)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_company_id uuid; v_role text; v_active boolean; v_can_see_actual boolean;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile where profile.id = auth.uid();
  if v_company_id is null or not v_active or
     v_role not in ('foreman', 'gf', 'superintendent', 'admin', 'owner') then
    raise exception using errcode = '42501',
      message = 'An active company production profile is required.';
  end if;
  v_can_see_actual := v_role in ('admin', 'owner', 'gf') or
    (v_role = 'superintendent' and public.linecrew_has_capability('actual_pricing'));

  return query
  select report.id, count(unit.id),
    case when v_can_see_actual then coalesce(sum(
      greatest(unit.install_quantity - coalesce(location.transfer_quantity, 0), 0) * unit.actual_install_price +
      coalesce(location.transfer_quantity, 0) * unit.actual_transfer_price +
      unit.retirement_quantity * unit.actual_retirement_price
    ), 0) else null end,
    coalesce(sum(
      greatest(unit.install_quantity - coalesce(location.transfer_quantity, 0), 0) * unit.adjusted_install_price +
      coalesce(location.transfer_quantity, 0) * unit.adjusted_transfer_price +
      unit.retirement_quantity * unit.adjusted_retirement_price
    ), 0),
    case when v_can_see_actual then coalesce(sum(
      greatest(unit.install_quantity - coalesce(location.transfer_quantity, 0), 0) * unit.actual_install_price +
      coalesce(location.transfer_quantity, 0) * unit.actual_transfer_price +
      unit.retirement_quantity * unit.actual_retirement_price
    ), 0) else coalesce(sum(
      greatest(unit.install_quantity - coalesce(location.transfer_quantity, 0), 0) * unit.adjusted_install_price +
      coalesce(location.transfer_quantity, 0) * unit.adjusted_transfer_price +
      unit.retirement_quantity * unit.adjusted_retirement_price
    ), 0) end,
    coalesce(bool_or(unit.has_adjustment), false)
  from public.daily_reports report
  left join public.daily_production_units unit
    on unit.daily_report_id = report.id and unit.company_id = report.company_id
  left join lateral (
    select sum(detail.transfer_quantity) transfer_quantity
    from public.daily_production_unit_locations detail
    where detail.daily_production_unit_id = unit.id and detail.company_id = unit.company_id
  ) location on true
  where report.company_id = v_company_id
    and (v_role in ('admin', 'owner', 'gf', 'superintendent') or report.created_by = auth.uid())
  group by report.id;
end;
$$;

revoke all on function public.get_daily_report_value_summaries() from public, anon;
grant execute on function public.get_daily_report_value_summaries() to authenticated;

create or replace function public.get_job_package_work_points(p_package_id uuid)
returns table(
  work_point_id uuid, work_point_code text, work_point_description text,
  authorized_unit_id uuid, unit_code text, unit_name text, unit_description text,
  authorized_install_quantity numeric, authorized_retirement_quantity numeric,
  reported_install_quantity numeric, reported_retirement_quantity numeric,
  approved_install_quantity numeric, approved_retirement_quantity numeric,
  authorized_value numeric, reported_value numeric, approved_value numeric
)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_company_id uuid; v_role text; v_active boolean; v_job_id uuid;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile where profile.id = auth.uid();
  if v_company_id is null or not v_active or
     v_role not in ('admin', 'gf', 'owner', 'superintendent') then
    raise exception using errcode = '42501',
      message = 'Only active company leadership can view package progress.';
  end if;
  if v_role = 'superintendent' and not public.linecrew_has_capability('job_packages') then
    raise exception using errcode = '42501',
      message = 'This Superintendent does not have job packages permission.';
  end if;
  select package.job_id into v_job_id
  from public.job_packages package
  where package.id = p_package_id and package.company_id = v_company_id;
  if v_job_id is null then
    raise exception using errcode = 'P0002',
      message = 'Utility job package was not found in your company.';
  end if;

  return query
  select work_point.id, work_point.work_point_code, work_point.description,
    authorized.id, authorized.unit_code, item.item_name, item.description,
    coalesce(authorized.authorized_install_quantity + authorized.authorized_transfer_quantity, 0),
    coalesce(authorized.authorized_retirement_quantity, 0),
    coalesce(production.reported_install + production.reported_transfer, 0),
    coalesce(production.reported_retirement, 0),
    coalesce(production.approved_install + production.approved_transfer, 0),
    coalesce(production.approved_retirement, 0),
    coalesce(
      authorized.authorized_install_quantity * item.install_price +
      authorized.authorized_transfer_quantity * item.transfer_price +
      authorized.authorized_retirement_quantity * item.retirement_price, 0
    ),
    coalesce(
      least(production.reported_install, authorized.authorized_install_quantity) * item.install_price +
      least(production.reported_transfer, authorized.authorized_transfer_quantity) * item.transfer_price +
      least(production.reported_retirement, authorized.authorized_retirement_quantity) * item.retirement_price, 0
    ),
    coalesce(
      least(production.approved_install, authorized.authorized_install_quantity) * item.install_price +
      least(production.approved_transfer, authorized.authorized_transfer_quantity) * item.transfer_price +
      least(production.approved_retirement, authorized.authorized_retirement_quantity) * item.retirement_price, 0
    )
  from public.job_package_work_points work_point
  left join public.job_package_authorized_units authorized
    on authorized.work_point_id = work_point.id and authorized.company_id = work_point.company_id
  left join public.price_book_items item
    on item.id = authorized.price_book_item_id and item.company_id = authorized.company_id
  left join lateral (
    select coalesce(sum(location.install_quantity), 0) reported_install,
      coalesce(sum(location.transfer_quantity), 0) reported_transfer,
      coalesce(sum(location.retirement_quantity), 0) reported_retirement,
      coalesce(sum(location.install_quantity) filter (
        where lower(coalesce(report.status, '')) = 'approved'), 0) approved_install,
      coalesce(sum(location.transfer_quantity) filter (
        where lower(coalesce(report.status, '')) = 'approved'), 0) approved_transfer,
      coalesce(sum(location.retirement_quantity) filter (
        where lower(coalesce(report.status, '')) = 'approved'), 0) approved_retirement
    from public.daily_production_unit_locations location
    join public.daily_reports report
      on report.id = location.daily_report_id and report.company_id = location.company_id
    where location.company_id = v_company_id and report.job_id = v_job_id
      and public.normalize_work_point_key(location.pole_location) =
          public.normalize_work_point_key(work_point.work_point_code)
      and location.price_book_item_id = authorized.price_book_item_id
      and lower(coalesce(report.status, '')) <> 'rejected'
  ) production on authorized.id is not null
  where work_point.job_package_id = p_package_id and work_point.company_id = v_company_id
  order by work_point.work_point_key, authorized.unit_code;
end;
$$;

revoke all on function public.get_job_package_work_points(uuid) from public, anon;
grant execute on function public.get_job_package_work_points(uuid) to authenticated;

create or replace function public.create_billing_export_batch(
  p_job_id uuid, p_date_from date default null, p_date_to date default null,
  p_include_redlines boolean default false, p_notes text default null
)
returns uuid language plpgsql security definer set search_path = '' as $$
declare
  v_company_id uuid; v_role text; v_active boolean;
  v_batch_id uuid := gen_random_uuid(); v_batch_number text; v_inserted integer;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile where profile.id = auth.uid();
  if v_company_id is null or not v_active or
     v_role not in ('admin', 'owner', 'superintendent') then
    raise exception using errcode = '42501',
      message = 'Only an active Admin, Owner or Superintendent can create billing exports.';
  end if;
  if v_role = 'superintendent' and
     (not public.linecrew_has_capability('reporting') or
      not public.linecrew_has_capability('actual_pricing')) then
    raise exception using errcode = '42501',
      message = 'This Superintendent needs Reporting and Actual Pricing permissions for billing exports.';
  end if;
  if p_date_from is not null and p_date_to is not null and p_date_from > p_date_to then
    raise exception using errcode = '22023', message = 'From Date cannot be after Through Date.';
  end if;
  if not exists (
    select 1 from public.jobs job
    where job.id = p_job_id and job.company_id = v_company_id
  ) then
    raise exception using errcode = 'P0002', message = 'Job was not found in your company.';
  end if;

  v_batch_number := 'BILL-' || to_char(current_date, 'YYYYMMDD') || '-' ||
    upper(substr(replace(v_batch_id::text, '-', ''), 1, 6));
  insert into public.billing_export_batches(
    id, company_id, job_id, batch_number, date_from, date_to,
    include_redlines, notes, created_by
  ) values (
    v_batch_id, v_company_id, p_job_id, v_batch_number, p_date_from, p_date_to,
    coalesce(p_include_redlines, false), nullif(btrim(coalesce(p_notes, '')), ''), auth.uid()
  );

  with eligible as (
    select report.id daily_report_id, report.work_date report_date,
      report.foreman_name, report.crew_name,
      location.location_line_id production_location_id, location.price_book_item_id,
      location.pole_location work_point, location.item_code unit_code,
      location.item_name unit_name, location.description unit_description,
      location.install_quantity, location.transfer_quantity, location.retirement_quantity,
      location.actual_install_price, unit.actual_transfer_price,
      location.actual_retirement_price, location.authorization_status
    from public.daily_reports report
    cross join lateral public.get_daily_report_unit_locations_v2(report.id) location
    join public.daily_production_unit_locations source
      on source.id = location.location_line_id and source.company_id = report.company_id
    join public.daily_production_units unit
      on unit.id = source.daily_production_unit_id and unit.company_id = source.company_id
    where report.company_id = v_company_id and report.job_id = p_job_id
      and lower(coalesce(report.status, '')) = 'approved'
      and (p_date_from is null or report.work_date >= p_date_from)
      and (p_date_to is null or report.work_date <= p_date_to)
      and location.authorization_status in ('authorized', 'redline')
      and (location.authorization_status = 'authorized' or coalesce(p_include_redlines, false))
  ), actions as (
    select eligible.*, 'INSTALL'::text work_type,
      eligible.install_quantity quantity, eligible.actual_install_price unit_price
    from eligible where eligible.install_quantity > 0
    union all
    select eligible.*, 'TRANSFER'::text,
      eligible.transfer_quantity, eligible.actual_transfer_price
    from eligible where eligible.transfer_quantity > 0
    union all
    select eligible.*, 'REMOVE'::text,
      eligible.retirement_quantity, eligible.actual_retirement_price
    from eligible where eligible.retirement_quantity > 0
  )
  insert into public.billing_export_lines(
    company_id, billing_batch_id, job_id, daily_report_id,
    production_location_id, report_date, foreman_name, crew_name, work_point,
    price_book_item_id, unit_code, unit_name, unit_description, work_type,
    quantity, unit_price, extended_value, authorization_status
  )
  select v_company_id, v_batch_id, p_job_id, action.daily_report_id,
    action.production_location_id, action.report_date, action.foreman_name,
    action.crew_name, action.work_point, action.price_book_item_id,
    action.unit_code, action.unit_name, action.unit_description, action.work_type,
    action.quantity, coalesce(action.unit_price, 0),
    round(action.quantity * coalesce(action.unit_price, 0), 2),
    action.authorization_status
  from actions action
  where not exists (
    select 1 from public.billing_export_lines prior
    where prior.company_id = v_company_id
      and prior.production_location_id = action.production_location_id
      and prior.work_type = action.work_type and prior.active
  );
  get diagnostics v_inserted = row_count;
  if v_inserted = 0 then
    delete from public.billing_export_batches where id = v_batch_id;
    raise exception using errcode = 'P0002',
      message = 'No approved, unbilled unit lines match this job and date range.';
  end if;
  update public.billing_export_batches batch set
    authorized_line_count = (select count(*) from public.billing_export_lines line
      where line.billing_batch_id = v_batch_id and line.authorization_status = 'authorized'),
    redline_line_count = (select count(*) from public.billing_export_lines line
      where line.billing_batch_id = v_batch_id and line.authorization_status = 'redline'),
    total_value = (select coalesce(sum(line.extended_value), 0)
      from public.billing_export_lines line where line.billing_batch_id = v_batch_id)
  where batch.id = v_batch_id;
  return v_batch_id;
end;
$$;

revoke all on function public.create_billing_export_batch(uuid,date,date,boolean,text)
from public, anon, authenticated;

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
declare v_company_id uuid; v_role text; v_active boolean;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile where profile.id = auth.uid();
  if v_company_id is null or not v_active or
     v_role not in ('owner', 'admin', 'superintendent') then
    raise exception using errcode = '42501', message = 'Billing access is required.';
  end if;
  if v_role = 'superintendent' and
     (not public.linecrew_has_capability('reporting') or
      not public.linecrew_has_capability('actual_pricing')) then
    raise exception using errcode = '42501',
      message = 'Reporting and Actual Pricing permissions are required.';
  end if;
  if not exists (
    select 1 from public.jobs job
    where job.id = p_job_id and job.company_id = v_company_id
  ) then
    raise exception using errcode = 'P0002', message = 'Job was not found in your company.';
  end if;

  return query
  with progress as (
    select * from public.get_job_progress_dashboard() dashboard
    where dashboard.job_id = p_job_id
  ), eligible as (
    select location.location_line_id production_location_id,
      location.install_quantity, location.transfer_quantity, location.retirement_quantity,
      location.actual_install_price, unit.actual_transfer_price,
      location.actual_retirement_price
    from public.daily_reports report
    cross join lateral public.get_daily_report_unit_locations_v2(report.id) location
    join public.daily_production_unit_locations source
      on source.id = location.location_line_id and source.company_id = report.company_id
    join public.daily_production_units unit
      on unit.id = source.daily_production_unit_id and unit.company_id = source.company_id
    where report.company_id = v_company_id and report.job_id = p_job_id
      and lower(coalesce(report.status, '')) = 'approved'
      and location.authorization_status in ('authorized', 'redline')
  ), actions as (
    select eligible.production_location_id, 'INSTALL'::text work_type,
      round(eligible.install_quantity * coalesce(eligible.actual_install_price, 0), 2) value
    from eligible where eligible.install_quantity > 0
    union all
    select eligible.production_location_id, 'TRANSFER'::text,
      round(eligible.transfer_quantity * coalesce(eligible.actual_transfer_price, 0), 2)
    from eligible where eligible.transfer_quantity > 0
    union all
    select eligible.production_location_id, 'REMOVE'::text,
      round(eligible.retirement_quantity * coalesce(eligible.actual_retirement_price, 0), 2)
    from eligible where eligible.retirement_quantity > 0
  ), approved as (
    select coalesce(sum(action.value), 0) approved_total,
      coalesce(sum(action.value) filter (where not exists (
        select 1 from public.billing_export_lines line
        where line.company_id = v_company_id
          and line.production_location_id = action.production_location_id
          and line.work_type = action.work_type and line.active
      )), 0) approved_unbilled
    from actions action
  ), batches as (
    select coalesce(sum(case
        when batch.status not in ('void', 'draft') and batch.billing_type <> 'credit'
        then batch.total_value else 0 end), 0) billed,
      coalesce(sum(case
        when batch.status not in ('void', 'draft') and batch.billing_type = 'credit'
        then batch.total_value else 0 end), 0) credits,
      count(*) filter (where batch.status not in ('void', 'draft')) active_batches,
      count(*) filter (where batch.status not in ('void', 'draft')
        and batch.billing_type = 'final') finals
    from public.billing_export_batches batch
    where batch.company_id = v_company_id and batch.job_id = p_job_id
  ), reports as (
    select count(*) filter (where lower(coalesce(report.status, '')) = 'submitted') awaiting,
      count(*) filter (where lower(coalesce(report.status, '')) in ('draft', 'returned')) drafts
    from public.daily_reports report
    where report.company_id = v_company_id and report.job_id = p_job_id and not report.archived
  )
  select p_job_id, coalesce(progress.authorized_value, 0), approved.approved_total,
    greatest(coalesce(progress.remaining_value, 0), 0), batches.billed,
    abs(batches.credits), batches.billed + batches.credits,
    approved.approved_unbilled, reports.awaiting, reports.drafts,
    coalesce(progress.pending_packet_count, 0), coalesce(progress.redline_count, 0),
    batches.active_batches, batches.finals
  from progress cross join approved cross join batches cross join reports;
end;
$$;

revoke all on function public.get_job_billing_reconciliation(uuid) from public, anon;
grant execute on function public.get_job_billing_reconciliation(uuid) to authenticated;

commit;
