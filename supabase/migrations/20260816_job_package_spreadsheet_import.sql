begin;

create or replace function public.validate_job_package_import(
  p_package_id uuid,
  p_rows jsonb
)
returns table (
  row_number integer,
  is_valid boolean,
  error_message text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_contract_id uuid;
  v_row jsonb;
  v_row_number integer;
  v_work_point text;
  v_unit_code text;
  v_install numeric;
  v_retirement numeric;
  v_error text;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role <> 'admin' then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin can validate job packet imports.';
  end if;

  select package.contract_id
  into v_contract_id
  from public.job_packages package
  where package.id = p_package_id
    and package.company_id = v_company_id;

  if v_contract_id is null then
    raise exception using errcode = 'P0002',
      message = 'Utility job package was not found in your company.';
  end if;

  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception using errcode = '22023', message = 'Import rows are required.';
  end if;

  if jsonb_array_length(p_rows) > 2000 then
    raise exception using errcode = '22023',
      message = 'A maximum of 2,000 consolidated rows can be imported at once.';
  end if;

  for v_row in select value from jsonb_array_elements(p_rows)
  loop
    v_row_number := coalesce((v_row->>'row_number')::integer, 0);
    v_work_point := trim(coalesce(v_row->>'work_point_code', ''));
    v_unit_code := trim(coalesce(v_row->>'unit_code', ''));
    v_install := coalesce((v_row->>'install_quantity')::numeric, 0);
    v_retirement := coalesce((v_row->>'retirement_quantity')::numeric, 0);
    v_error := null;

    if length(v_work_point) = 0 then
      v_error := 'Missing work point';
    elsif length(v_unit_code) = 0 then
      v_error := 'Missing unit code';
    elsif v_install < 0 or v_retirement < 0 or v_install + v_retirement <= 0 then
      v_error := 'Authorized quantity must be greater than zero';
    elsif not exists (
      select 1
      from public.price_book_items item
      join public.price_books book
        on book.id = item.price_book_id
       and book.company_id = item.company_id
      where item.company_id = v_company_id
        and book.contract_id = v_contract_id
        and book.active is true
        and item.active is true
        and lower(trim(item.item_code)) = lower(v_unit_code)
    ) then
      v_error := 'Unit code was not found in an active Price Book for this contract';
    end if;

    row_number := v_row_number;
    is_valid := v_error is null;
    error_message := v_error;
    return next;
  end loop;
exception
  when invalid_text_representation then
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
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_contract_id uuid;
  v_job_id uuid;
  v_row jsonb;
  v_row_number integer;
  v_work_point text;
  v_description text;
  v_unit_code text;
  v_install numeric;
  v_retirement numeric;
  v_work_point_id uuid;
  v_price_book_item_id uuid;
  v_canonical_unit_code text;
  v_imported integer := 0;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role <> 'admin' then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin can import utility job packets.';
  end if;

  select package.contract_id, package.job_id
  into v_contract_id, v_job_id
  from public.job_packages package
  join public.jobs job
    on job.id = package.job_id
   and job.company_id = package.company_id
  where package.id = p_package_id
    and package.company_id = v_company_id;

  if v_contract_id is null then
    raise exception using errcode = 'P0002',
      message = 'Utility job package was not found in your company.';
  end if;

  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception using errcode = '22023', message = 'Import rows are required.';
  end if;

  if jsonb_array_length(p_rows) > 2000 then
    raise exception using errcode = '22023',
      message = 'A maximum of 2,000 consolidated rows can be imported at once.';
  end if;

  -- Validate every row before writing anything. Any exception rolls back the call.
  for v_row in select value from jsonb_array_elements(p_rows)
  loop
    v_row_number := coalesce((v_row->>'row_number')::integer, 0);
    v_work_point := trim(coalesce(v_row->>'work_point_code', ''));
    v_unit_code := trim(coalesce(v_row->>'unit_code', ''));
    v_install := coalesce((v_row->>'install_quantity')::numeric, 0);
    v_retirement := coalesce((v_row->>'retirement_quantity')::numeric, 0);

    if length(v_work_point) = 0 or length(v_unit_code) = 0 or
       v_install < 0 or v_retirement < 0 or v_install + v_retirement <= 0 then
      raise exception using errcode = '22023',
        message = 'Import row ' || v_row_number || ' is incomplete or has an invalid quantity.';
    end if;

    if not exists (
      select 1
      from public.price_book_items item
      join public.price_books book
        on book.id = item.price_book_id
       and book.company_id = item.company_id
      where item.company_id = v_company_id
        and book.contract_id = v_contract_id
        and book.active is true
        and item.active is true
        and lower(trim(item.item_code)) = lower(v_unit_code)
    ) then
      raise exception using errcode = 'P0002',
        message = 'Import row ' || v_row_number || ': unit ' || v_unit_code ||
          ' was not found in an active Price Book for this contract.';
    end if;
  end loop;

  for v_row in select value from jsonb_array_elements(p_rows)
  loop
    v_work_point := trim(v_row->>'work_point_code');
    v_description := nullif(trim(coalesce(v_row->>'work_point_description', '')), '');
    v_unit_code := trim(v_row->>'unit_code');
    v_install := coalesce((v_row->>'install_quantity')::numeric, 0);
    v_retirement := coalesce((v_row->>'retirement_quantity')::numeric, 0);

    select point.id
    into v_work_point_id
    from public.job_package_work_points point
    where point.company_id = v_company_id
      and point.job_package_id = p_package_id
      and public.normalize_work_point_key(point.work_point_code) =
          public.normalize_work_point_key(v_work_point)
    order by point.created_at
    limit 1;

    if v_work_point_id is null then
      insert into public.job_package_work_points (
        company_id, job_package_id, job_id, work_point_code, description, created_by
      ) values (
        v_company_id, p_package_id, v_job_id, v_work_point, v_description, auth.uid()
      )
      returning id into v_work_point_id;
    elsif v_description is not null then
      update public.job_package_work_points
      set description = coalesce(description, v_description), updated_at = now()
      where id = v_work_point_id and company_id = v_company_id;
    end if;

    select item.id, item.item_code
    into v_price_book_item_id, v_canonical_unit_code
    from public.price_book_items item
    join public.price_books book
      on book.id = item.price_book_id
     and book.company_id = item.company_id
    where item.company_id = v_company_id
      and book.contract_id = v_contract_id
      and book.active is true
      and item.active is true
      and lower(trim(item.item_code)) = lower(v_unit_code)
    order by book.effective_start desc nulls last, book.updated_at desc nulls last
    limit 1;

    insert into public.job_package_authorized_units (
      company_id, job_package_id, work_point_id, price_book_item_id, unit_code,
      authorized_install_quantity, authorized_retirement_quantity, created_by
    ) values (
      v_company_id, p_package_id, v_work_point_id, v_price_book_item_id,
      v_canonical_unit_code, v_install, v_retirement, auth.uid()
    )
    on conflict (work_point_id, price_book_item_id) do update set
      authorized_install_quantity = excluded.authorized_install_quantity,
      authorized_retirement_quantity = excluded.authorized_retirement_quantity,
      unit_code = excluded.unit_code,
      updated_at = now();

    v_imported := v_imported + 1;
  end loop;

  update public.job_packages
  set source_filename = nullif(trim(coalesce(p_source_filename, '')), ''),
      updated_at = now()
  where id = p_package_id and company_id = v_company_id;

  return jsonb_build_object('imported_rows', v_imported);
exception
  when invalid_text_representation then
    raise exception using errcode = '22023',
      message = 'One or more quantities are not valid numbers. Nothing was imported.';
end;
$$;

revoke all on function public.import_job_package_units(uuid, jsonb, text)
from public, anon;
grant execute on function public.import_job_package_units(uuid, jsonb, text)
to authenticated;

commit;
