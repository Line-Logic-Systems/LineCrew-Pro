begin;

create or replace function public.normalize_work_point_key(p_value text)
returns text
language sql
immutable
set search_path = ''
as $$
  select regexp_replace(
    regexp_replace(
      lower(btrim(coalesce(p_value, ''))),
      '^(pole|wp|work[[:space:]_-]*point)[[:space:]#:_-]*',
      '',
      'i'
    ),
    '[^a-z0-9]+',
    '',
    'g'
  );
$$;

revoke all on function public.normalize_work_point_key(text) from public, anon;
grant execute on function public.normalize_work_point_key(text) to authenticated;

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
      and public.normalize_work_point_key(location.pole_location) =
          public.normalize_work_point_key(point.work_point_code)
      and lower(trim(historical_item.item_code)) = lower(trim(authorized.unit_code))
  ) production on authorized.id is not null
  where point.job_package_id = p_package_id
    and point.company_id = v_company_id
  order by point.work_point_key, authorized.unit_code;
end;
$$;

revoke all on function public.get_job_package_work_points(uuid) from public, anon;
grant execute on function public.get_job_package_work_points(uuid) to authenticated;

create or replace function public.delete_job_package_authorized_unit(
  p_authorized_unit_id uuid
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
      message = 'Only an active company Admin can delete authorized units.';
  end if;

  delete from public.job_package_authorized_units authorized
  where authorized.id = p_authorized_unit_id
    and authorized.company_id = v_company_id;

  if not found then
    raise exception using errcode = 'P0002',
      message = 'Authorized unit was not found in your company.';
  end if;
end;
$$;

revoke all on function public.delete_job_package_authorized_unit(uuid)
from public, anon;
grant execute on function public.delete_job_package_authorized_unit(uuid)
to authenticated;

create or replace function public.delete_job_package_work_point(
  p_work_point_id uuid
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
      message = 'Only an active company Admin can delete package work points.';
  end if;

  if exists (
    select 1
    from public.job_package_authorized_units authorized
    where authorized.work_point_id = p_work_point_id
      and authorized.company_id = v_company_id
  ) then
    raise exception using errcode = '23503',
      message = 'Delete the authorized units from this work point first.';
  end if;

  delete from public.job_package_work_points point
  where point.id = p_work_point_id
    and point.company_id = v_company_id;

  if not found then
    raise exception using errcode = 'P0002',
      message = 'Package work point was not found in your company.';
  end if;
end;
$$;

revoke all on function public.delete_job_package_work_point(uuid)
from public, anon;
grant execute on function public.delete_job_package_work_point(uuid)
to authenticated;

create or replace function public.delete_job_package(
  p_package_id uuid
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
      message = 'Only an active company Admin can delete utility job packages.';
  end if;

  delete from public.job_packages package
  where package.id = p_package_id
    and package.company_id = v_company_id;

  if not found then
    raise exception using errcode = 'P0002',
      message = 'Utility job package was not found in your company.';
  end if;
end;
$$;

revoke all on function public.delete_job_package(uuid) from public, anon;
grant execute on function public.delete_job_package(uuid) to authenticated;

commit;
