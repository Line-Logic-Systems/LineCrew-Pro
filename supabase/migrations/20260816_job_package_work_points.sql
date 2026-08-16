begin;

create table if not exists public.job_package_work_points (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  job_package_id uuid not null references public.job_packages(id) on delete cascade,
  job_id uuid not null references public.jobs(id) on delete cascade,
  work_point_code text not null,
  work_point_key text generated always as (lower(trim(work_point_code))) stored,
  description text null,
  created_by uuid not null default auth.uid() references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint job_package_work_points_code_not_blank
    check (length(trim(work_point_code)) > 0),
  constraint job_package_work_points_package_code_unique
    unique (job_package_id, work_point_key)
);

create index if not exists job_package_work_points_company_job_idx
  on public.job_package_work_points(company_id, job_id);

create table if not exists public.job_package_authorized_units (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  job_package_id uuid not null references public.job_packages(id) on delete cascade,
  work_point_id uuid not null references public.job_package_work_points(id) on delete cascade,
  price_book_item_id uuid not null references public.price_book_items(id) on delete restrict,
  unit_code text not null,
  authorized_install_quantity numeric(12,2) not null default 0,
  authorized_retirement_quantity numeric(12,2) not null default 0,
  created_by uuid not null default auth.uid() references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint job_package_authorized_units_nonnegative
    check (authorized_install_quantity >= 0 and authorized_retirement_quantity >= 0),
  constraint job_package_authorized_units_has_quantity
    check (authorized_install_quantity > 0 or authorized_retirement_quantity > 0),
  constraint job_package_authorized_units_point_item_unique
    unique (work_point_id, price_book_item_id)
);

create index if not exists job_package_authorized_units_company_package_idx
  on public.job_package_authorized_units(company_id, job_package_id);

alter table public.job_package_work_points enable row level security;
alter table public.job_package_authorized_units enable row level security;

revoke all on public.job_package_work_points from public, anon, authenticated;
revoke all on public.job_package_authorized_units from public, anon, authenticated;

create or replace function public.create_job_package_work_point(
  p_package_id uuid,
  p_work_point_code text,
  p_description text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_job_id uuid;
  v_work_point_id uuid;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role <> 'admin' then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin can add package work points.';
  end if;

  if length(trim(coalesce(p_work_point_code, ''))) = 0 then
    raise exception using errcode = '22023',
      message = 'Pole or work-point number is required.';
  end if;

  select package.job_id
  into v_job_id
  from public.job_packages package
  join public.jobs job
    on job.id = package.job_id
   and job.company_id = package.company_id
  where package.id = p_package_id
    and package.company_id = v_company_id;

  if v_job_id is null then
    raise exception using errcode = 'P0002',
      message = 'Utility job package was not found in your company.';
  end if;

  insert into public.job_package_work_points (
    company_id, job_package_id, job_id, work_point_code, description, created_by
  ) values (
    v_company_id, p_package_id, v_job_id, trim(p_work_point_code),
    nullif(trim(coalesce(p_description, '')), ''), auth.uid()
  )
  returning id into v_work_point_id;

  return v_work_point_id;
exception
  when unique_violation then
    raise exception using errcode = '23505',
      message = 'That pole or work point already exists in this package.';
end;
$$;

revoke all on function public.create_job_package_work_point(uuid, text, text)
from public, anon;
grant execute on function public.create_job_package_work_point(uuid, text, text)
to authenticated;

create or replace function public.save_job_package_authorized_unit(
  p_work_point_id uuid,
  p_unit_code text,
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
  v_active boolean;
  v_package_id uuid;
  v_contract_id uuid;
  v_price_book_item_id uuid;
  v_unit_code text;
  v_authorized_unit_id uuid;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role <> 'admin' then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin can add authorized units.';
  end if;

  if length(trim(coalesce(p_unit_code, ''))) = 0 or
     coalesce(p_install_quantity, 0) < 0 or
     coalesce(p_retirement_quantity, 0) < 0 or
     coalesce(p_install_quantity, 0) + coalesce(p_retirement_quantity, 0) <= 0 then
    raise exception using errcode = '22023',
      message = 'Unit code and an authorized quantity greater than zero are required.';
  end if;

  select point.job_package_id, package.contract_id
  into v_package_id, v_contract_id
  from public.job_package_work_points point
  join public.job_packages package
    on package.id = point.job_package_id
   and package.company_id = point.company_id
  where point.id = p_work_point_id
    and point.company_id = v_company_id;

  if v_package_id is null then
    raise exception using errcode = 'P0002',
      message = 'Package work point was not found in your company.';
  end if;

  select item.id, item.item_code
  into v_price_book_item_id, v_unit_code
  from public.price_book_items item
  join public.price_books book
    on book.id = item.price_book_id
   and book.company_id = item.company_id
  where item.company_id = v_company_id
    and book.contract_id = v_contract_id
    and book.active is true
    and item.active is true
    and lower(trim(item.item_code)) = lower(trim(p_unit_code))
  order by book.effective_start desc nulls last, book.updated_at desc nulls last
  limit 1;

  if v_price_book_item_id is null then
    raise exception using errcode = 'P0002',
      message = 'That unit code was not found in an active Price Book for this contract.';
  end if;

  insert into public.job_package_authorized_units (
    company_id, job_package_id, work_point_id, price_book_item_id, unit_code,
    authorized_install_quantity, authorized_retirement_quantity, created_by
  ) values (
    v_company_id, v_package_id, p_work_point_id, v_price_book_item_id, v_unit_code,
    coalesce(p_install_quantity, 0), coalesce(p_retirement_quantity, 0), auth.uid()
  )
  on conflict (work_point_id, price_book_item_id) do update set
    authorized_install_quantity = excluded.authorized_install_quantity,
    authorized_retirement_quantity = excluded.authorized_retirement_quantity,
    unit_code = excluded.unit_code,
    updated_at = now()
  returning id into v_authorized_unit_id;

  return v_authorized_unit_id;
end;
$$;

revoke all on function public.save_job_package_authorized_unit(uuid, text, numeric, numeric)
from public, anon;
grant execute on function public.save_job_package_authorized_unit(uuid, text, numeric, numeric)
to authenticated;

create or replace function public.get_job_package_work_points(
  p_package_id uuid
)
returns table (
  work_point_id uuid,
  work_point_code text,
  work_point_description text,
  authorized_unit_id uuid,
  unit_code text,
  unit_name text,
  unit_description text,
  authorized_install_quantity numeric,
  authorized_retirement_quantity numeric,
  reported_install_quantity numeric,
  reported_retirement_quantity numeric,
  approved_install_quantity numeric,
  approved_retirement_quantity numeric,
  authorized_value numeric,
  reported_value numeric,
  approved_value numeric
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_job_id uuid;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin', 'gf') then
    raise exception using errcode = '42501',
      message = 'Only an active Admin or General Foreman can view package progress.';
  end if;

  select package.job_id
  into v_job_id
  from public.job_packages package
  where package.id = p_package_id
    and package.company_id = v_company_id;

  if v_job_id is null then
    raise exception using errcode = 'P0002',
      message = 'Utility job package was not found in your company.';
  end if;

  return query
  select
    point.id,
    point.work_point_code,
    point.description,
    authorized.id,
    authorized.unit_code,
    item.item_name,
    item.description,
    coalesce(authorized.authorized_install_quantity, 0),
    coalesce(authorized.authorized_retirement_quantity, 0),
    coalesce(production.reported_install, 0),
    coalesce(production.reported_retirement, 0),
    coalesce(production.approved_install, 0),
    coalesce(production.approved_retirement, 0),
    coalesce(
      authorized.authorized_install_quantity * item.install_price +
      authorized.authorized_retirement_quantity * item.retirement_price,
      0
    ),
    coalesce(
      least(production.reported_install, authorized.authorized_install_quantity) * item.install_price +
      least(production.reported_retirement, authorized.authorized_retirement_quantity) * item.retirement_price,
      0
    ),
    coalesce(
      least(production.approved_install, authorized.authorized_install_quantity) * item.install_price +
      least(production.approved_retirement, authorized.authorized_retirement_quantity) * item.retirement_price,
      0
    )
  from public.job_package_work_points point
  left join public.job_package_authorized_units authorized
    on authorized.work_point_id = point.id
   and authorized.company_id = point.company_id
  left join public.price_book_items item
    on item.id = authorized.price_book_item_id
   and item.company_id = authorized.company_id
  left join lateral (
    select
      coalesce(sum(location.install_quantity), 0) as reported_install,
      coalesce(sum(location.retirement_quantity), 0) as reported_retirement,
      coalesce(sum(location.install_quantity) filter (
        where lower(coalesce(report.status, '')) = 'approved'
      ), 0) as approved_install,
      coalesce(sum(location.retirement_quantity) filter (
        where lower(coalesce(report.status, '')) = 'approved'
      ), 0) as approved_retirement
    from public.daily_production_unit_locations location
    join public.daily_reports report
      on report.id = location.daily_report_id
     and report.company_id = location.company_id
    join public.price_book_items historical_item
      on historical_item.id = location.price_book_item_id
     and historical_item.company_id = location.company_id
    where location.company_id = v_company_id
      and report.job_id = v_job_id
      and location.pole_location_key = point.work_point_key
      and lower(trim(historical_item.item_code)) = lower(trim(authorized.unit_code))
  ) production on authorized.id is not null
  where point.job_package_id = p_package_id
    and point.company_id = v_company_id
  order by point.work_point_key, authorized.unit_code;
end;
$$;

revoke all on function public.get_job_package_work_points(uuid) from public, anon;
grant execute on function public.get_job_package_work_points(uuid) to authenticated;

commit;
