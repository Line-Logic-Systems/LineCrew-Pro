begin;

-- Resolve staged packet Contractor Units against the job's Price Book.
-- Exact codes support utility/co-op formats; an I/R suffix fallback supports
-- Oncor books where the packet separates work type from the Contractor Unit.
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
  select item.id
  from public.utility_packet_imports packet_import
  join public.job_packages package
    on package.id = packet_import.job_package_id
   and package.company_id = packet_import.company_id
  join public.jobs job
    on job.id = package.job_id
   and job.company_id = packet_import.company_id
  join public.price_books book
    on book.company_id = packet_import.company_id
   and book.active is true
   and (
     book.id = job.price_book_id
     or (job.price_book_id is null and book.contract_id = package.contract_id)
   )
  join public.price_book_items item
    on item.price_book_id = book.id
   and item.company_id = packet_import.company_id
   and item.active is true
  where packet_import.id = p_import_id
    and nullif(btrim(coalesce(p_contractor_unit_code, '')), '') is not null
    and (
      regexp_replace(upper(btrim(item.item_code)), '[^A-Z0-9]', '', 'g') =
        regexp_replace(upper(btrim(p_contractor_unit_code)), '[^A-Z0-9]', '', 'g')
      or regexp_replace(upper(btrim(item.item_code)), '[^A-Z0-9]', '', 'g') =
        regexp_replace(upper(btrim(p_contractor_unit_code)), '[^A-Z0-9]', '', 'g') ||
        case lower(btrim(coalesce(p_work_type, '')))
          when 'install' then 'I'
          when 'remove' then 'R'
          else ''
        end
    )
  order by
    case when regexp_replace(upper(btrim(item.item_code)), '[^A-Z0-9]', '', 'g') =
      regexp_replace(upper(btrim(p_contractor_unit_code)), '[^A-Z0-9]', '', 'g')
      then 0 else 1 end,
    book.effective_start desc nulls last,
    book.updated_at desc nulls last,
    item.updated_at desc nulls last
  limit 1;
$$;

revoke all on function public.resolve_utility_packet_price_item(uuid,text,text) from public, anon;
grant execute on function public.resolve_utility_packet_price_item(uuid,text,text) to authenticated;

create or replace function public.get_utility_packet_import_review(p_import_id uuid)
returns table (
  row_id uuid, source_page integer, source_row integer, work_point_code text,
  work_point_description text, work_type text, material_cu text,
  contractor_unit_code text, estimated_quantity numeric, description text,
  confidence numeric, include_in_import boolean, review_note text,
  price_book_match boolean
)
language sql
security definer
set search_path = ''
as $$
  select r.id, r.source_page, r.source_row, r.work_point_code,
    r.work_point_description, r.work_type, r.material_cu,
    r.contractor_unit_code, r.estimated_quantity, r.description,
    r.confidence, r.include_in_import, r.review_note,
    public.resolve_utility_packet_price_item(
      r.import_id, r.contractor_unit_code, r.work_type
    ) is not null
  from public.utility_packet_import_rows r
  join public.utility_packet_imports i
    on i.id = r.import_id and i.company_id = r.company_id
  join public.profiles profile
    on profile.id = auth.uid()
   and profile.company_id = i.company_id
   and profile.active is true
  where r.import_id = p_import_id
  order by r.source_page nulls last, r.source_row;
$$;

revoke all on function public.get_utility_packet_import_review(uuid) from public, anon;
grant execute on function public.get_utility_packet_import_review(uuid) to authenticated;

create or replace function public.finalize_utility_packet_import(p_import_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_package_id uuid;
  v_source_filename text;
  v_company_id uuid;
  v_job_id uuid;
  v_rows jsonb;
  v_row jsonb;
  v_work_point_id uuid;
  v_result jsonb;
begin
  if not public.linecrew_can_manage_job_packages() then
    raise exception using errcode = '42501', message = 'You do not have permission to import job packets.';
  end if;

  select i.job_package_id, i.source_filename, i.company_id, p.job_id
  into v_package_id, v_source_filename, v_company_id, v_job_id
  from public.utility_packet_imports i
  join public.job_packages p on p.id = i.job_package_id and p.company_id = i.company_id
  join public.profiles profile
    on profile.id = auth.uid() and profile.company_id = i.company_id and profile.active is true
  where i.id = p_import_id and i.status = 'review'
  for update;

  if v_package_id is null then
    raise exception using errcode = 'P0002', message = 'Packet review was not found or was already finalized.';
  end if;

  if exists (
    select 1 from public.utility_packet_import_rows r
    where r.import_id = p_import_id and r.include_in_import
      and (r.contractor_unit_code is null or length(trim(r.contractor_unit_code)) = 0)
  ) then
    raise exception using errcode = '22023',
      message = 'Every included production row must have a Contractor Unit. Exclude material-only rows or correct the mapping.';
  end if;

  if exists (
    select 1
    from public.utility_packet_import_rows r
    where r.import_id = p_import_id
      and r.include_in_import
      and r.contractor_unit_code is not null
      and public.resolve_utility_packet_price_item(
        r.import_id, r.contractor_unit_code, r.work_type
      ) is null
  ) then
    raise exception using errcode = 'P0002',
      message = 'One or more Contractor Units were not found in the job Price Book. Correct the unmatched rows before importing.';
  end if;

  select jsonb_agg(jsonb_build_object(
    'row_number', grouped.first_source_row,
    'work_point_code', grouped.work_point_code,
    'work_point_description', grouped.work_point_description,
    'price_book_item_id', grouped.price_book_item_id,
    'unit_code', grouped.canonical_unit_code,
    'install_quantity', grouped.install_quantity,
    'retirement_quantity', grouped.retirement_quantity
  ) order by grouped.work_point_code, grouped.canonical_unit_code)
  into v_rows
  from (
    select min(r.source_row) first_source_row,
      min(trim(r.work_point_code)) work_point_code,
      max(r.work_point_description) work_point_description,
      item.id price_book_item_id,
      item.item_code canonical_unit_code,
      sum(case when r.work_type = 'install' then r.estimated_quantity else 0 end) install_quantity,
      sum(case when r.work_type = 'remove' then r.estimated_quantity else 0 end) retirement_quantity
    from public.utility_packet_import_rows r
    join public.price_book_items item
      on item.id = public.resolve_utility_packet_price_item(
        r.import_id, r.contractor_unit_code, r.work_type
      )
    where r.import_id = p_import_id
      and r.include_in_import
      and r.contractor_unit_code is not null
    group by public.normalize_work_point_key(r.work_point_code), item.id, item.item_code
  ) grouped;

  if v_rows is null or jsonb_array_length(v_rows) = 0 then
    raise exception using errcode = '22023', message = 'No reviewed Contractor Unit rows are selected for import.';
  end if;

  for v_row in select value from jsonb_array_elements(v_rows)
  loop
    select point.id into v_work_point_id
    from public.job_package_work_points point
    where point.company_id = v_company_id and point.job_package_id = v_package_id
      and public.normalize_work_point_key(point.work_point_code) =
          public.normalize_work_point_key(v_row->>'work_point_code')
    order by point.created_at limit 1;

    if v_work_point_id is null then
      insert into public.job_package_work_points (
        company_id, job_package_id, job_id, work_point_code, description, created_by
      ) values (
        v_company_id, v_package_id, v_job_id, trim(v_row->>'work_point_code'),
        nullif(trim(coalesce(v_row->>'work_point_description','')), ''), auth.uid()
      ) returning id into v_work_point_id;
    end if;

    insert into public.job_package_authorized_units (
      company_id, job_package_id, work_point_id, price_book_item_id, unit_code,
      authorized_install_quantity, authorized_retirement_quantity, created_by
    ) values (
      v_company_id, v_package_id, v_work_point_id,
      (v_row->>'price_book_item_id')::uuid, v_row->>'unit_code',
      (v_row->>'install_quantity')::numeric,
      (v_row->>'retirement_quantity')::numeric, auth.uid()
    ) on conflict (work_point_id, price_book_item_id) do update set
      authorized_install_quantity = excluded.authorized_install_quantity,
      authorized_retirement_quantity = excluded.authorized_retirement_quantity,
      unit_code = excluded.unit_code,
      updated_at = now();

    v_work_point_id := null;
  end loop;

  update public.job_packages
  set source_filename = v_source_filename, updated_at = now()
  where id = v_package_id and company_id = v_company_id;

  -- Remember the newest active contract Price Book when the job has none.
  update public.jobs job
  set price_book_id = (
    select book.id
    from public.price_books book
    where book.company_id = v_company_id
      and book.contract_id = job.contract_id
      and book.active is true
    order by book.effective_start desc nulls last, book.updated_at desc nulls last
    limit 1
  )
  where job.id = v_job_id and job.company_id = v_company_id and job.price_book_id is null;

  v_result := jsonb_build_object('imported_rows', jsonb_array_length(v_rows));

  update public.utility_packet_imports
  set status = 'imported', reviewed_by = auth.uid(), reviewed_at = now()
  where id = p_import_id;

  return v_result || jsonb_build_object(
    'source_rows', (select count(*) from public.utility_packet_import_rows r where r.import_id = p_import_id),
    'material_only_rows', (select count(*) from public.utility_packet_import_rows r where r.import_id = p_import_id and r.contractor_unit_code is null),
    'consolidated_rows', jsonb_array_length(v_rows)
  );
end;
$$;

revoke all on function public.finalize_utility_packet_import(uuid) from public, anon;
grant execute on function public.finalize_utility_packet_import(uuid) to authenticated;

commit;
