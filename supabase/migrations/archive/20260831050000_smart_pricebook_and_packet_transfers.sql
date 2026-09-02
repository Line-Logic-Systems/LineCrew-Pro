begin;

-- Smart packet review already presents Transfer as a valid action. Keep the
-- database contract aligned with the UI and with explicit transfer quantities.
alter table public.utility_packet_import_rows
  drop constraint if exists utility_packet_import_rows_type_check;
alter table public.utility_packet_import_rows
  add constraint utility_packet_import_rows_type_check
  check (work_type in ('install', 'transfer', 'remove'));

create or replace function public.update_utility_packet_import_row(
  p_row_id uuid,
  p_work_point_code text,
  p_work_type text,
  p_contractor_unit_code text,
  p_estimated_quantity numeric,
  p_include_in_import boolean,
  p_review_note text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_work_type text := lower(btrim(coalesce(p_work_type, '')));
begin
  if not public.linecrew_can_manage_job_packages() then
    raise exception using errcode = '42501',
      message = 'You do not have permission to review job packets.';
  end if;
  if v_work_type not in ('install', 'transfer', 'remove') then
    raise exception using errcode = '22023',
      message = 'Work type must be Install, Transfer or Remove.';
  end if;
  if nullif(btrim(coalesce(p_work_point_code, '')), '') is null then
    raise exception using errcode = '22023',
      message = 'A work point is required.';
  end if;
  if coalesce(p_estimated_quantity, 0) <= 0 then
    raise exception using errcode = '22023',
      message = 'Estimated quantity must be greater than zero.';
  end if;

  update public.utility_packet_import_rows row_item
  set work_point_code = btrim(p_work_point_code),
      work_type = v_work_type,
      contractor_unit_code = nullif(btrim(coalesce(p_contractor_unit_code, '')), ''),
      estimated_quantity = p_estimated_quantity,
      include_in_import = coalesce(p_include_in_import, false),
      review_note = nullif(btrim(coalesce(p_review_note, '')), '')
  from public.utility_packet_imports packet_import,
       public.profiles profile
  where row_item.id = p_row_id
    and packet_import.id = row_item.import_id
    and profile.id = auth.uid()
    and profile.active is true
    and profile.company_id = row_item.company_id
    and packet_import.company_id = row_item.company_id
    and packet_import.status = 'review';

  if not found then
    raise exception using errcode = 'P0002',
      message = 'Review row was not found or is no longer editable.';
  end if;
end;
$$;
revoke all on function public.update_utility_packet_import_row(
  uuid, text, text, text, numeric, boolean, text
) from public, anon;
grant execute on function public.update_utility_packet_import_row(
  uuid, text, text, text, numeric, boolean, text
) to authenticated;

-- Exact action codes still win. The I/T/R suffix is only a fallback and the
-- one-character fallback remains restricted to a unique candidate.
create or replace function public.resolve_utility_packet_price_item(
  p_import_id uuid,
  p_contractor_unit_code text,
  p_work_type text
)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  with context as (
    select packet_import.company_id, package.contract_id, job.price_book_id,
      regexp_replace(upper(btrim(p_contractor_unit_code)), '[^A-Z0-9]', '', 'g') base_code,
      case lower(btrim(coalesce(p_work_type, '')))
        when 'install' then 'I'
        when 'transfer' then 'T'
        when 'remove' then 'R'
        else ''
      end work_suffix
    from public.utility_packet_imports packet_import
    join public.job_packages package
      on package.id = packet_import.job_package_id
     and package.company_id = packet_import.company_id
    join public.jobs job
      on job.id = package.job_id
     and job.company_id = package.company_id
    join public.profiles profile
      on profile.id = auth.uid()
     and profile.company_id = packet_import.company_id
     and profile.active is true
    where packet_import.id = p_import_id
      and nullif(btrim(coalesce(p_contractor_unit_code, '')), '') is not null
  ), candidates as (
    select item.id, item.item_code, book.effective_start,
      book.updated_at book_updated_at, item.updated_at item_updated_at,
      regexp_replace(upper(btrim(item.item_code)), '[^A-Z0-9]', '', 'g') normalized_item_code,
      context.base_code, context.work_suffix
    from context
    join public.price_books book
      on book.company_id = context.company_id
     and book.active is true
     and (
       book.id = context.price_book_id
       or (context.price_book_id is null and book.contract_id = context.contract_id)
     )
    join public.price_book_items item
      on item.price_book_id = book.id
     and item.company_id = context.company_id
     and item.active is true
  ), eligible as (
    select candidate.*,
      case
        when candidate.normalized_item_code = candidate.base_code then 0
        when candidate.normalized_item_code =
          candidate.base_code || candidate.work_suffix then 1
        when length(candidate.normalized_item_code) =
             length(candidate.base_code) + 1
         and left(candidate.normalized_item_code, length(candidate.base_code)) =
             candidate.base_code
         and 1 = (
           select count(distinct alternate.normalized_item_code)
           from candidates alternate
           where length(alternate.normalized_item_code) =
                 length(candidate.base_code) + 1
             and left(alternate.normalized_item_code,
                      length(candidate.base_code)) = candidate.base_code
         ) then 2
        else 99
      end match_rank
    from candidates candidate
  )
  select eligible.id
  from eligible
  where eligible.match_rank < 99
  order by eligible.match_rank, eligible.effective_start desc nulls last,
    eligible.book_updated_at desc nulls last,
    eligible.item_updated_at desc nulls last
  limit 1;
$$;
revoke all on function public.resolve_utility_packet_price_item(
  uuid, text, text
) from public, anon;
grant execute on function public.resolve_utility_packet_price_item(
  uuid, text, text
) to authenticated;

create or replace function public.validate_job_package_import(
  p_package_id uuid,
  p_rows jsonb
)
returns table(row_number integer, is_valid boolean, error_message text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid; v_contract_id uuid; v_row jsonb;
  v_work_point text; v_unit_code text; v_error text;
  v_install numeric; v_transfer numeric; v_retirement numeric;
begin
  if not public.linecrew_can_manage_job_packages() then
    raise exception using errcode = '42501',
      message = 'You do not have permission to validate job packet imports.';
  end if;
  select profile.company_id into v_company_id
  from public.profiles profile
  where profile.id = auth.uid() and profile.active is true;
  select package.contract_id into v_contract_id
  from public.job_packages package
  where package.id = p_package_id and package.company_id = v_company_id;
  if v_contract_id is null then
    raise exception using errcode = 'P0002',
      message = 'Utility job package was not found in your company.';
  end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0
     or jsonb_array_length(p_rows) > 2000 then
    raise exception using errcode = '22023',
      message = 'Import between 1 and 2,000 consolidated rows.';
  end if;

  for v_row in select value from jsonb_array_elements(p_rows) loop
    row_number := coalesce((v_row->>'row_number')::integer, 0);
    v_work_point := btrim(coalesce(v_row->>'work_point_code', ''));
    v_unit_code := btrim(coalesce(v_row->>'unit_code', ''));
    v_install := coalesce((v_row->>'install_quantity')::numeric, 0);
    v_transfer := coalesce((v_row->>'transfer_quantity')::numeric, 0);
    v_retirement := coalesce((v_row->>'retirement_quantity')::numeric, 0);
    v_error := null;
    if v_work_point = '' then v_error := 'Missing work point';
    elsif v_unit_code = '' then v_error := 'Missing unit code';
    elsif v_install < 0 or v_transfer < 0 or v_retirement < 0
       or v_install + v_transfer + v_retirement <= 0 then
      v_error := 'Authorized quantity must be greater than zero';
    elsif not exists (
      select 1 from public.price_book_items item
      join public.price_books book
        on book.id = item.price_book_id and book.company_id = item.company_id
      where item.company_id = v_company_id
        and book.contract_id = v_contract_id and book.active is true
        and item.active is true
        and lower(btrim(item.item_code)) = lower(v_unit_code)
    ) then
      v_error := 'Unit code was not found in an active Price Book for this contract';
    end if;
    is_valid := v_error is null;
    error_message := v_error;
    return next;
  end loop;
exception when invalid_text_representation then
  raise exception using errcode = '22023',
    message = 'One or more quantities are not valid numbers.';
end;
$$;
revoke all on function public.validate_job_package_import(uuid, jsonb)
  from public, anon;
grant execute on function public.validate_job_package_import(uuid, jsonb)
  to authenticated;

create or replace function public.import_job_package_units(
  p_package_id uuid,
  p_rows jsonb,
  p_source_filename text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid; v_contract_id uuid; v_job_id uuid; v_row jsonb;
  v_work_point text; v_description text; v_unit_code text;
  v_install numeric; v_transfer numeric; v_retirement numeric;
  v_work_point_id uuid; v_item_id uuid; v_canonical_code text;
  v_imported integer := 0;
begin
  if not public.linecrew_can_manage_job_packages() then
    raise exception using errcode = '42501',
      message = 'You do not have permission to import job packets.';
  end if;
  select profile.company_id into v_company_id
  from public.profiles profile
  where profile.id = auth.uid() and profile.active is true;
  select package.contract_id, package.job_id into v_contract_id, v_job_id
  from public.job_packages package
  where package.id = p_package_id and package.company_id = v_company_id
  for update;
  if v_contract_id is null then
    raise exception using errcode = 'P0002',
      message = 'Utility job package was not found in your company.';
  end if;

  -- Validate the complete payload before the first write.
  if exists (
    select 1 from public.validate_job_package_import(p_package_id, p_rows)
    where not is_valid
  ) then
    raise exception using errcode = '22023',
      message = 'One or more packet rows need attention. Nothing was imported.';
  end if;

  for v_row in select value from jsonb_array_elements(p_rows) loop
    v_work_point := btrim(v_row->>'work_point_code');
    v_description := nullif(btrim(coalesce(
      v_row->>'work_point_description', ''
    )), '');
    v_unit_code := btrim(v_row->>'unit_code');
    v_install := coalesce((v_row->>'install_quantity')::numeric, 0);
    v_transfer := coalesce((v_row->>'transfer_quantity')::numeric, 0);
    v_retirement := coalesce((v_row->>'retirement_quantity')::numeric, 0);

    select point.id into v_work_point_id
    from public.job_package_work_points point
    where point.company_id = v_company_id
      and point.job_package_id = p_package_id
      and public.normalize_work_point_key(point.work_point_code) =
          public.normalize_work_point_key(v_work_point)
    order by point.created_at limit 1;
    if v_work_point_id is null then
      insert into public.job_package_work_points(
        company_id, job_package_id, job_id, work_point_code, description, created_by
      ) values (
        v_company_id, p_package_id, v_job_id, v_work_point, v_description, auth.uid()
      ) returning id into v_work_point_id;
    elsif v_description is not null then
      update public.job_package_work_points
      set description = coalesce(description, v_description), updated_at = now()
      where id = v_work_point_id and company_id = v_company_id;
    end if;

    select item.id, item.item_code into v_item_id, v_canonical_code
    from public.price_book_items item
    join public.price_books book
      on book.id = item.price_book_id and book.company_id = item.company_id
    where item.company_id = v_company_id
      and book.contract_id = v_contract_id and book.active is true
      and item.active is true
      and lower(btrim(item.item_code)) = lower(v_unit_code)
    order by book.effective_start desc nulls last,
      book.updated_at desc nulls last limit 1;

    insert into public.job_package_authorized_units(
      company_id, job_package_id, work_point_id, price_book_item_id, unit_code,
      authorized_install_quantity, authorized_transfer_quantity,
      authorized_retirement_quantity, created_by
    ) values (
      v_company_id, p_package_id, v_work_point_id, v_item_id, v_canonical_code,
      v_install, v_transfer, v_retirement, auth.uid()
    ) on conflict (work_point_id, price_book_item_id) do update set
      authorized_install_quantity = excluded.authorized_install_quantity,
      authorized_transfer_quantity = excluded.authorized_transfer_quantity,
      authorized_retirement_quantity = excluded.authorized_retirement_quantity,
      unit_code = excluded.unit_code, updated_at = now();
    v_imported := v_imported + 1;
    v_work_point_id := null;
  end loop;

  update public.job_packages
  set source_filename = nullif(btrim(coalesce(p_source_filename, '')), ''),
      updated_at = now()
  where id = p_package_id and company_id = v_company_id;
  return jsonb_build_object('imported_rows', v_imported);
exception when invalid_text_representation then
  raise exception using errcode = '22023',
    message = 'One or more quantities are not valid numbers. Nothing was imported.';
end;
$$;
revoke all on function public.import_job_package_units(uuid, jsonb, text)
  from public, anon;
grant execute on function public.import_job_package_units(uuid, jsonb, text)
  to authenticated;

create or replace function public.save_job_package_authorized_unit_v2(
  p_work_point_id uuid,
  p_unit_code text,
  p_install_quantity numeric,
  p_transfer_quantity numeric,
  p_retirement_quantity numeric
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid; v_package_id uuid; v_contract_id uuid;
  v_item_id uuid; v_unit_code text; v_authorized_id uuid;
begin
  if not public.linecrew_can_manage_job_packages() then
    raise exception using errcode = '42501',
      message = 'You do not have permission to add authorized units.';
  end if;
  select profile.company_id into v_company_id
  from public.profiles profile
  where profile.id = auth.uid() and profile.active is true;
  if nullif(btrim(coalesce(p_unit_code, '')), '') is null
     or coalesce(p_install_quantity, 0) < 0
     or coalesce(p_transfer_quantity, 0) < 0
     or coalesce(p_retirement_quantity, 0) < 0
     or coalesce(p_install_quantity, 0)
      + coalesce(p_transfer_quantity, 0)
      + coalesce(p_retirement_quantity, 0) <= 0 then
    raise exception using errcode = '22023',
      message = 'Unit code and an authorized quantity greater than zero are required.';
  end if;

  select point.job_package_id, package.contract_id
  into v_package_id, v_contract_id
  from public.job_package_work_points point
  join public.job_packages package
    on package.id = point.job_package_id and package.company_id = point.company_id
  where point.id = p_work_point_id and point.company_id = v_company_id;
  if v_package_id is null then
    raise exception using errcode = 'P0002',
      message = 'Package work point was not found in your company.';
  end if;

  select item.id, item.item_code into v_item_id, v_unit_code
  from public.price_book_items item
  join public.price_books book
    on book.id = item.price_book_id and book.company_id = item.company_id
  where item.company_id = v_company_id
    and book.contract_id = v_contract_id and book.active is true
    and item.active is true
    and lower(btrim(item.item_code)) = lower(btrim(p_unit_code))
  order by book.effective_start desc nulls last,
    book.updated_at desc nulls last limit 1;
  if v_item_id is null then
    raise exception using errcode = 'P0002',
      message = 'That unit code was not found in an active Price Book for this contract.';
  end if;

  insert into public.job_package_authorized_units(
    company_id, job_package_id, work_point_id, price_book_item_id, unit_code,
    authorized_install_quantity, authorized_transfer_quantity,
    authorized_retirement_quantity, created_by
  ) values (
    v_company_id, v_package_id, p_work_point_id, v_item_id, v_unit_code,
    coalesce(p_install_quantity, 0), coalesce(p_transfer_quantity, 0),
    coalesce(p_retirement_quantity, 0), auth.uid()
  ) on conflict (work_point_id, price_book_item_id) do update set
    authorized_install_quantity = excluded.authorized_install_quantity,
    authorized_transfer_quantity = excluded.authorized_transfer_quantity,
    authorized_retirement_quantity = excluded.authorized_retirement_quantity,
    unit_code = excluded.unit_code, updated_at = now()
  returning id into v_authorized_id;
  return v_authorized_id;
end;
$$;
revoke all on function public.save_job_package_authorized_unit_v2(
  uuid, text, numeric, numeric, numeric
) from public, anon;
grant execute on function public.save_job_package_authorized_unit_v2(
  uuid, text, numeric, numeric, numeric
) to authenticated;

create or replace function public.get_job_package_work_points_v2(
  p_package_id uuid
)
returns table(
  work_point_id uuid, work_point_code text, work_point_description text,
  authorized_unit_id uuid, unit_code text, unit_name text, unit_description text,
  authorized_install_quantity numeric, authorized_transfer_quantity numeric,
  authorized_retirement_quantity numeric, reported_install_quantity numeric,
  reported_transfer_quantity numeric, reported_retirement_quantity numeric,
  approved_install_quantity numeric, approved_transfer_quantity numeric,
  approved_retirement_quantity numeric, authorized_value numeric,
  reported_value numeric, approved_value numeric
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_company_id uuid; v_job_id uuid;
begin
  if not public.linecrew_can_manage_job_packages() then
    raise exception using errcode = '42501',
      message = 'You do not have permission to view package progress.';
  end if;
  select profile.company_id into v_company_id
  from public.profiles profile
  where profile.id = auth.uid() and profile.active is true;
  select package.job_id into v_job_id
  from public.job_packages package
  where package.id = p_package_id and package.company_id = v_company_id;
  if v_job_id is null then
    raise exception using errcode = 'P0002',
      message = 'Utility job package was not found in your company.';
  end if;

  return query
  select point.id, point.work_point_code, point.description,
    authorized.id, authorized.unit_code, item.item_name, item.description,
    coalesce(authorized.authorized_install_quantity, 0),
    coalesce(authorized.authorized_transfer_quantity, 0),
    coalesce(authorized.authorized_retirement_quantity, 0),
    coalesce(production.reported_install, 0),
    coalesce(production.reported_transfer, 0),
    coalesce(production.reported_retirement, 0),
    coalesce(production.approved_install, 0),
    coalesce(production.approved_transfer, 0),
    coalesce(production.approved_retirement, 0),
    coalesce(
      authorized.authorized_install_quantity * item.install_price +
      authorized.authorized_transfer_quantity * item.transfer_price +
      authorized.authorized_retirement_quantity * item.retirement_price, 0
    ),
    coalesce(
      least(production.reported_install, authorized.authorized_install_quantity)
        * item.install_price +
      least(production.reported_transfer, authorized.authorized_transfer_quantity)
        * item.transfer_price +
      least(production.reported_retirement, authorized.authorized_retirement_quantity)
        * item.retirement_price, 0
    ),
    coalesce(
      least(production.approved_install, authorized.authorized_install_quantity)
        * item.install_price +
      least(production.approved_transfer, authorized.authorized_transfer_quantity)
        * item.transfer_price +
      least(production.approved_retirement, authorized.authorized_retirement_quantity)
        * item.retirement_price, 0
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
      coalesce(sum(location.install_quantity), 0) reported_install,
      coalesce(sum(location.transfer_quantity), 0) reported_transfer,
      coalesce(sum(location.retirement_quantity), 0) reported_retirement,
      coalesce(sum(location.install_quantity) filter (
        where lower(coalesce(report.status, '')) = 'approved'
      ), 0) approved_install,
      coalesce(sum(location.transfer_quantity) filter (
        where lower(coalesce(report.status, '')) = 'approved'
      ), 0) approved_transfer,
      coalesce(sum(location.retirement_quantity) filter (
        where lower(coalesce(report.status, '')) = 'approved'
      ), 0) approved_retirement
    from public.daily_production_unit_locations location
    join public.daily_reports report
      on report.id = location.daily_report_id
     and report.company_id = location.company_id
    where location.company_id = v_company_id and report.job_id = v_job_id
      and public.normalize_work_point_key(location.pole_location) =
          public.normalize_work_point_key(point.work_point_code)
      and location.price_book_item_id = authorized.price_book_item_id
      and lower(coalesce(report.status, '')) <> 'rejected'
  ) production on authorized.id is not null
  where point.job_package_id = p_package_id
    and point.company_id = v_company_id
  order by point.work_point_key, authorized.unit_code;
end;
$$;
revoke all on function public.get_job_package_work_points_v2(uuid)
  from public, anon;
grant execute on function public.get_job_package_work_points_v2(uuid)
  to authenticated;

create unique index if not exists price_book_items_book_code_unique
on public.price_book_items(
  price_book_id,
  lower(btrim(item_code))
);

create or replace function public.import_price_book_items_atomic(
  p_price_book_id uuid,
  p_rows jsonb,
  p_update_existing boolean default false,
  p_source_filename text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid; v_role text; v_active boolean; v_row jsonb;
  v_item_id uuid; v_code text; v_name text; v_description text;
  v_category text; v_uom text; v_install numeric;
  v_transfer numeric; v_retirement numeric;
  v_added integer := 0; v_updated integer := 0;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile where profile.id = auth.uid();
  if v_company_id is null or v_active is not true
     or v_role not in ('owner', 'admin', 'superintendent') then
    raise exception using errcode = '42501',
      message = 'You do not have permission to import Price Book units.';
  end if;
  if v_role = 'superintendent'
     and not public.linecrew_has_capability('price_books') then
    raise exception using errcode = '42501',
      message = 'This Superintendent does not have Price Books permission.';
  end if;

  perform 1 from public.price_books book
  where book.id = p_price_book_id and book.company_id = v_company_id
  for update;
  if not found then
    raise exception using errcode = 'P0002',
      message = 'Price Book was not found in your company.';
  end if;
  if jsonb_typeof(p_rows) <> 'array'
     or jsonb_array_length(p_rows) = 0
     or jsonb_array_length(p_rows) > 5000 then
    raise exception using errcode = '22023',
      message = 'Import between 1 and 5,000 completed pricing rows.';
  end if;
  if exists (
    select 1
    from jsonb_array_elements(p_rows) row_item
    group by lower(btrim(row_item->>'item_code'))
    having count(*) > 1
  ) then
    raise exception using errcode = '23505',
      message = 'The import contains duplicate Unit Codes. Nothing was saved.';
  end if;

  -- Validate every row before writing so any problem leaves the Price Book
  -- completely unchanged.
  for v_row in select value from jsonb_array_elements(p_rows) loop
    v_code := btrim(coalesce(v_row->>'item_code', ''));
    v_name := btrim(coalesce(v_row->>'item_name', ''));
    v_description := nullif(btrim(coalesce(v_row->>'description', '')), '');
    v_install := (v_row->>'install_price')::numeric;
    v_transfer := (v_row->>'transfer_price')::numeric;
    v_retirement := (v_row->>'retirement_price')::numeric;
    if v_code = '' or (v_name = '' and v_description is null) then
      raise exception using errcode = '22023',
        message = 'Every imported row needs a Unit Code and description.';
    end if;
    if v_install is null or v_transfer is null or v_retirement is null
       or v_install < 0 or v_transfer < 0 or v_retirement < 0 then
      raise exception using errcode = '22023',
        message = 'Unit prices cannot be negative.';
    end if;
    if not coalesce(p_update_existing, false) and exists (
      select 1 from public.price_book_items item
      where item.company_id = v_company_id
        and item.price_book_id = p_price_book_id
        and lower(btrim(item.item_code)) = lower(v_code)
    ) then
      raise exception using errcode = '23505',
        message = 'Unit Code ' || v_code ||
          ' already exists. Choose Update Existing Units and try again.';
    end if;
  end loop;

  for v_row in select value from jsonb_array_elements(p_rows) loop
    v_code := btrim(v_row->>'item_code');
    v_name := btrim(coalesce(v_row->>'item_name', ''));
    v_description := nullif(btrim(coalesce(v_row->>'description', '')), '');
    v_category := nullif(btrim(coalesce(v_row->>'category', '')), '');
    v_uom := nullif(btrim(coalesce(v_row->>'unit_of_measure', '')), '');
    v_install := (v_row->>'install_price')::numeric;
    v_transfer := (v_row->>'transfer_price')::numeric;
    v_retirement := (v_row->>'retirement_price')::numeric;
    select item.id into v_item_id
    from public.price_book_items item
    where item.company_id = v_company_id
      and item.price_book_id = p_price_book_id
      and lower(btrim(item.item_code)) = lower(v_code)
    limit 1;
    if v_item_id is null then
      insert into public.price_book_items(
        company_id, price_book_id, item_code, item_name, description,
        category, unit_of_measure, install_price, transfer_price,
        retirement_price, active
      ) values (
        v_company_id, p_price_book_id, v_code,
        coalesce(nullif(v_name, ''), v_description), v_description,
        v_category, v_uom, v_install, v_transfer, v_retirement, true
      );
      v_added := v_added + 1;
    else
      update public.price_book_items
      set item_name = coalesce(nullif(v_name, ''), v_description),
          description = v_description, category = v_category,
          unit_of_measure = v_uom, install_price = v_install,
          transfer_price = v_transfer, retirement_price = v_retirement,
          updated_at = now()
      where id = v_item_id and company_id = v_company_id
        and price_book_id = p_price_book_id;
      v_updated := v_updated + 1;
    end if;
    v_item_id := null;
  end loop;

  update public.price_books
  set source_filename = coalesce(
        source_filename,
        nullif(btrim(coalesce(p_source_filename, '')), '')
      ),
      updated_at = now()
  where id = p_price_book_id and company_id = v_company_id;
  return jsonb_build_object(
    'added', v_added,
    'updated', v_updated,
    'total', v_added + v_updated
  );
exception when invalid_text_representation then
  raise exception using errcode = '22023',
    message = 'One or more prices are not valid numbers. Nothing was imported.';
end;
$$;
revoke all on function public.import_price_book_items_atomic(
  uuid, jsonb, boolean, text
) from public, anon;
grant execute on function public.import_price_book_items_atomic(
  uuid, jsonb, boolean, text
) to authenticated;

commit;
