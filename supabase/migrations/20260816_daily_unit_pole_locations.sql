begin;

create table if not exists public.daily_production_unit_locations (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null
    references public.companies(id) on delete cascade,
  daily_report_id uuid not null
    references public.daily_reports(id) on delete cascade,
  daily_production_unit_id uuid not null
    references public.daily_production_units(id) on delete cascade,
  price_book_item_id uuid not null
    references public.price_book_items(id) on delete restrict,
  pole_location text not null,
  pole_location_key text generated always as (lower(btrim(pole_location))) stored,
  install_quantity numeric(12,2) not null default 0,
  retirement_quantity numeric(12,2) not null default 0,
  created_by uuid null references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint daily_production_unit_locations_location_not_blank
    check (length(btrim(pole_location)) > 0),
  constraint daily_production_unit_locations_nonnegative
    check (install_quantity >= 0 and retirement_quantity >= 0),
  constraint daily_production_unit_locations_has_quantity
    check (install_quantity > 0 or retirement_quantity > 0),
  constraint daily_production_unit_locations_report_item_location_unique
    unique (daily_report_id, price_book_item_id, pole_location_key)
);

create index if not exists daily_production_unit_locations_company_report_idx
  on public.daily_production_unit_locations(company_id, daily_report_id);

alter table public.daily_production_unit_locations enable row level security;

revoke all on public.daily_production_unit_locations from public;
revoke all on public.daily_production_unit_locations from anon;
revoke all on public.daily_production_unit_locations from authenticated;

insert into public.daily_production_unit_locations (
  company_id,
  daily_report_id,
  daily_production_unit_id,
  price_book_item_id,
  pole_location,
  install_quantity,
  retirement_quantity,
  created_by,
  created_at,
  updated_at
)
select
  line.company_id,
  line.daily_report_id,
  line.id,
  line.price_book_item_id,
  'Unspecified',
  line.install_quantity,
  line.retirement_quantity,
  line.created_by,
  line.created_at,
  line.updated_at
from public.daily_production_units line
where not exists (
  select 1
  from public.daily_production_unit_locations location_line
  where location_line.daily_report_id = line.daily_report_id
    and location_line.price_book_item_id = line.price_book_item_id
);

create or replace function public.get_daily_report_unit_locations(
  p_report_id uuid
)
returns table (
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
  retirement_quantity numeric,
  actual_line_value numeric,
  adjusted_line_value numeric,
  visible_line_value numeric
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_profile_active boolean;
  v_report_company_id uuid;
  v_report_creator uuid;
  v_can_see_actual boolean;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_profile_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_profile_active is not true or
     v_role not in ('foreman', 'gf', 'admin') then
    raise exception using
      errcode = '42501',
      message = 'An active Foreman, General Foreman or Admin profile is required.';
  end if;

  select report.company_id, report.created_by
  into v_report_company_id, v_report_creator
  from public.daily_reports report
  where report.id = p_report_id;

  if v_report_company_id is null or v_report_company_id <> v_company_id then
    raise exception using
      errcode = 'P0002',
      message = 'Daily report was not found in your company.';
  end if;

  if v_role = 'foreman' and v_report_creator is distinct from auth.uid() then
    raise exception using
      errcode = '42501',
      message = 'Foremen can view unit production only on their own reports.';
  end if;

  v_can_see_actual := v_role in ('admin', 'gf');

  return query
  select
    location_line.id,
    aggregate_line.price_book_item_id,
    aggregate_line.item_code,
    aggregate_line.item_name,
    aggregate_line.description,
    aggregate_line.unit_of_measure,
    aggregate_line.category,
    location_line.pole_location,
    case when v_can_see_actual
      then aggregate_line.actual_install_price
      else aggregate_line.adjusted_install_price
    end,
    case when v_can_see_actual
      then aggregate_line.actual_retirement_price
      else aggregate_line.adjusted_retirement_price
    end,
    case when v_can_see_actual
      then aggregate_line.actual_install_price
      else null
    end,
    case when v_can_see_actual
      then aggregate_line.actual_retirement_price
      else null
    end,
    aggregate_line.adjusted_install_price,
    aggregate_line.adjusted_retirement_price,
    aggregate_line.has_adjustment,
    location_line.install_quantity,
    location_line.retirement_quantity,
    case when v_can_see_actual then round(
      location_line.install_quantity * aggregate_line.actual_install_price +
      location_line.retirement_quantity * aggregate_line.actual_retirement_price,
      2
    ) else null end,
    round(
      location_line.install_quantity * aggregate_line.adjusted_install_price +
      location_line.retirement_quantity * aggregate_line.adjusted_retirement_price,
      2
    ),
    case when v_can_see_actual then round(
      location_line.install_quantity * aggregate_line.actual_install_price +
      location_line.retirement_quantity * aggregate_line.actual_retirement_price,
      2
    ) else round(
      location_line.install_quantity * aggregate_line.adjusted_install_price +
      location_line.retirement_quantity * aggregate_line.adjusted_retirement_price,
      2
    ) end
  from public.daily_production_unit_locations location_line
  join public.daily_production_units aggregate_line
    on aggregate_line.id = location_line.daily_production_unit_id
   and aggregate_line.company_id = location_line.company_id
   and aggregate_line.daily_report_id = location_line.daily_report_id
   and aggregate_line.price_book_item_id = location_line.price_book_item_id
  where location_line.daily_report_id = p_report_id
    and location_line.company_id = v_company_id
  order by
    location_line.pole_location_key,
    aggregate_line.item_code;
end;
$$;

revoke all on function public.get_daily_report_unit_locations(uuid) from public;
revoke all on function public.get_daily_report_unit_locations(uuid) from anon;
grant execute on function public.get_daily_report_unit_locations(uuid)
to authenticated;

create or replace function public.save_daily_report_unit_location(
  p_report_id uuid,
  p_price_book_item_id uuid,
  p_pole_location text,
  p_install_quantity numeric,
  p_retirement_quantity numeric
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_profile_active boolean;
  v_report_company_id uuid;
  v_report_creator uuid;
  v_report_status text;
  v_location text;
  v_total_install numeric;
  v_total_retirement numeric;
  v_aggregate_line_id uuid;
  v_location_line_id uuid;
begin
  v_location := btrim(coalesce(p_pole_location, ''));

  if length(v_location) = 0 then
    raise exception using
      errcode = '22023',
      message = 'Enter a pole or work location.';
  end if;

  if coalesce(p_install_quantity, 0) < 0 or
     coalesce(p_retirement_quantity, 0) < 0 or
     (
       coalesce(p_install_quantity, 0) = 0 and
       coalesce(p_retirement_quantity, 0) = 0
     ) then
    raise exception using
      errcode = '22023',
      message = 'Enter an installed or removed quantity greater than zero.';
  end if;

  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_profile_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_profile_active is not true or
     v_role not in ('foreman', 'gf', 'admin') then
    raise exception using
      errcode = '42501',
      message = 'An active Foreman, General Foreman or Admin profile is required.';
  end if;

  select report.company_id, report.created_by,
         lower(coalesce(report.status, 'draft'))
  into v_report_company_id, v_report_creator, v_report_status
  from public.daily_reports report
  where report.id = p_report_id;

  if v_report_company_id is null or v_report_company_id <> v_company_id then
    raise exception using
      errcode = 'P0002',
      message = 'Daily report was not found in your company.';
  end if;

  if v_report_status <> 'draft' then
    raise exception using
      errcode = '42501',
      message = 'Units can be changed only while the report is a draft.';
  end if;

  if v_role = 'foreman' and v_report_creator is distinct from auth.uid() then
    raise exception using
      errcode = '42501',
      message = 'Foremen can change units only on their own reports.';
  end if;

  select
    coalesce(sum(location_line.install_quantity), 0) +
      coalesce(p_install_quantity, 0),
    coalesce(sum(location_line.retirement_quantity), 0) +
      coalesce(p_retirement_quantity, 0)
  into v_total_install, v_total_retirement
  from public.daily_production_unit_locations location_line
  where location_line.daily_report_id = p_report_id
    and location_line.price_book_item_id = p_price_book_item_id
    and location_line.company_id = v_company_id
    and location_line.pole_location_key <> lower(v_location);

  v_aggregate_line_id := public.save_daily_report_unit(
    p_report_id,
    p_price_book_item_id,
    v_total_install,
    v_total_retirement
  );

  insert into public.daily_production_unit_locations (
    company_id,
    daily_report_id,
    daily_production_unit_id,
    price_book_item_id,
    pole_location,
    install_quantity,
    retirement_quantity,
    created_by,
    updated_at
  ) values (
    v_company_id,
    p_report_id,
    v_aggregate_line_id,
    p_price_book_item_id,
    v_location,
    coalesce(p_install_quantity, 0),
    coalesce(p_retirement_quantity, 0),
    auth.uid(),
    now()
  )
  on conflict (daily_report_id, price_book_item_id, pole_location_key)
  do update set
    daily_production_unit_id = excluded.daily_production_unit_id,
    pole_location = excluded.pole_location,
    install_quantity = excluded.install_quantity,
    retirement_quantity = excluded.retirement_quantity,
    updated_at = now()
  returning id into v_location_line_id;

  return v_location_line_id;
end;
$$;

revoke all on function public.save_daily_report_unit_location(
  uuid, uuid, text, numeric, numeric
) from public;
revoke all on function public.save_daily_report_unit_location(
  uuid, uuid, text, numeric, numeric
) from anon;
grant execute on function public.save_daily_report_unit_location(
  uuid, uuid, text, numeric, numeric
) to authenticated;

create or replace function public.delete_daily_report_unit_location(
  p_report_id uuid,
  p_price_book_item_id uuid,
  p_pole_location text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_profile_active boolean;
  v_report_company_id uuid;
  v_report_creator uuid;
  v_report_status text;
  v_total_install numeric;
  v_total_retirement numeric;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_profile_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_profile_active is not true or
     v_role not in ('foreman', 'gf', 'admin') then
    raise exception using
      errcode = '42501',
      message = 'An active Foreman, General Foreman or Admin profile is required.';
  end if;

  select report.company_id, report.created_by,
         lower(coalesce(report.status, 'draft'))
  into v_report_company_id, v_report_creator, v_report_status
  from public.daily_reports report
  where report.id = p_report_id;

  if v_report_company_id is null or v_report_company_id <> v_company_id then
    raise exception using
      errcode = 'P0002',
      message = 'Daily report was not found in your company.';
  end if;

  if v_report_status <> 'draft' then
    raise exception using
      errcode = '42501',
      message = 'Units can be changed only while the report is a draft.';
  end if;

  if v_role = 'foreman' and v_report_creator is distinct from auth.uid() then
    raise exception using
      errcode = '42501',
      message = 'Foremen can change units only on their own reports.';
  end if;

  delete from public.daily_production_unit_locations location_line
  where location_line.daily_report_id = p_report_id
    and location_line.price_book_item_id = p_price_book_item_id
    and location_line.company_id = v_company_id
    and location_line.pole_location_key =
      lower(btrim(coalesce(p_pole_location, '')));

  select
    coalesce(sum(location_line.install_quantity), 0),
    coalesce(sum(location_line.retirement_quantity), 0)
  into v_total_install, v_total_retirement
  from public.daily_production_unit_locations location_line
  where location_line.daily_report_id = p_report_id
    and location_line.price_book_item_id = p_price_book_item_id
    and location_line.company_id = v_company_id;

  if v_total_install = 0 and v_total_retirement = 0 then
    perform public.delete_daily_report_unit(
      p_report_id,
      p_price_book_item_id
    );
  else
    perform public.save_daily_report_unit(
      p_report_id,
      p_price_book_item_id,
      v_total_install,
      v_total_retirement
    );
  end if;
end;
$$;

revoke all on function public.delete_daily_report_unit_location(
  uuid, uuid, text
) from public;
revoke all on function public.delete_daily_report_unit_location(
  uuid, uuid, text
) from anon;
grant execute on function public.delete_daily_report_unit_location(
  uuid, uuid, text
) to authenticated;

commit;
