begin;

-- Keep the repository aligned with the production normalization behavior.
-- Numeric work points compare without leading zeroes, so "Pole 0020", "WP-20"
-- and "20" all resolve to the same authorized location.
create or replace function public.normalize_work_point_key(p_value text)
returns text
language sql
immutable
set search_path = ''
as $$
  with normalized as (
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
    ) as key
  )
  select case
    when key ~ '^[0-9]+$' then coalesce(nullif(ltrim(key, '0'), ''), '0')
    else key
  end
  from normalized;
$$;

revoke all on function public.normalize_work_point_key(text) from public, anon;
grant execute on function public.normalize_work_point_key(text) to authenticated;

-- Internal single source of truth for both spreadsheet and smart-PDF imports.
-- An existing job selection is sticky when it is still an active book for the
-- same company/contract. A new selection is made only when the job has none.
create or replace function public.linecrew_resolve_job_price_book(
  p_company_id uuid,
  p_job_id uuid,
  p_contract_id uuid
)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when job.price_book_id is not null then (
      select book.id
      from public.price_books book
      where book.id = job.price_book_id
        and book.company_id = p_company_id
        and book.contract_id = p_contract_id
        and book.active is true
    )
    else (
      select book.id
      from public.price_books book
      where book.company_id = p_company_id
        and book.contract_id = p_contract_id
        and book.active is true
      order by book.effective_start desc nulls last,
        book.updated_at desc nulls last,
        book.created_at desc,
        book.id desc
      limit 1
    )
  end
  from public.jobs job
  where job.id = p_job_id
    and job.company_id = p_company_id
    and job.contract_id = p_contract_id
    and job.active is true;
$$;

revoke all on function public.linecrew_resolve_job_price_book(uuid, uuid, uuid)
  from public, anon, authenticated;

-- Use the shared capability predicate everywhere a utility package is managed.
-- This keeps Owner/Admin/GF and capability-enabled Superintendent behavior
-- identical across manual creation, status changes and both import paths.
create or replace function public.create_job_package(
  p_job_id uuid,
  p_package_name text,
  p_package_number text default null,
  p_received_date date default null,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_contract_id uuid;
  v_package_id uuid;
begin
  if not public.linecrew_can_manage_job_packages() then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to add utility job packages.';
  end if;

  select profile.company_id
  into v_company_id
  from public.profiles profile
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where profile.id = auth.uid()
    and profile.active is true;

  if v_company_id is null then
    raise exception using
      errcode = '42501',
      message = 'An active company profile is required.';
  end if;

  if length(trim(coalesce(p_package_name, ''))) = 0 then
    raise exception using
      errcode = '22023',
      message = 'Package name is required.';
  end if;

  select job.contract_id
  into v_contract_id
  from public.jobs job
  join public.contracts contract
    on contract.id = job.contract_id
   and contract.company_id = job.company_id
   and contract.active is true
  where job.id = p_job_id
    and job.company_id = v_company_id
    and job.active is true
  for update of job;

  if v_contract_id is null then
    raise exception using
      errcode = 'P0002',
      message = 'An active job tied to your company contract is required.';
  end if;

  insert into public.job_packages (
    company_id,
    job_id,
    contract_id,
    package_name,
    package_number,
    received_date,
    notes,
    created_by
  ) values (
    v_company_id,
    p_job_id,
    v_contract_id,
    trim(p_package_name),
    nullif(trim(coalesce(p_package_number, '')), ''),
    p_received_date,
    nullif(trim(coalesce(p_notes, '')), ''),
    auth.uid()
  )
  returning id into v_package_id;

  return v_package_id;
exception
  when unique_violation then
    raise exception using
      errcode = '23505',
      message = 'That utility package reference already exists on this job.';
end;
$$;

revoke all on function public.create_job_package(uuid, text, text, date, text)
  from public, anon;
grant execute on function public.create_job_package(uuid, text, text, date, text)
  to authenticated;

create or replace function public.set_job_package_status(
  p_package_id uuid,
  p_status text
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_next_status text;
  v_job_active boolean;
  v_contract_active boolean;
begin
  if not public.linecrew_can_manage_job_packages() then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to change a utility package status.';
  end if;

  select profile.company_id
  into v_company_id
  from public.profiles profile
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where profile.id = auth.uid()
    and profile.active is true;

  if v_company_id is null then
    raise exception using
      errcode = '42501',
      message = 'An active company profile is required.';
  end if;

  v_next_status := lower(trim(coalesce(p_status, '')));
  if v_next_status not in ('active', 'closed') then
    raise exception using
      errcode = '22023',
      message = 'A utility package can only be activated or closed.';
  end if;

  select job.active, contract.active
  into v_job_active, v_contract_active
  from public.job_packages package
  join public.jobs job
    on job.id = package.job_id
   and job.company_id = package.company_id
  join public.contracts contract
    on contract.id = package.contract_id
   and contract.company_id = package.company_id
   and contract.id = job.contract_id
  where package.id = p_package_id
    and package.company_id = v_company_id
  for update of package, job;

  if v_job_active is null then
    raise exception using
      errcode = 'P0002',
      message = 'Utility job package was not found in your company.';
  end if;

  if v_next_status = 'active' and v_job_active is not true then
    raise exception using
      errcode = '22023',
      message = 'Reopen the job before activating this utility package.';
  end if;

  if v_next_status = 'active' and v_contract_active is not true then
    raise exception using
      errcode = '22023',
      message = 'Reactivate the job contract before activating this utility package.';
  end if;

  if v_next_status = 'active' and not exists (
    select 1
    from public.job_package_authorized_units unit
    where unit.company_id = v_company_id
      and unit.job_package_id = p_package_id
  ) then
    raise exception using
      errcode = '22023',
      message = 'Add at least one authorized unit before activating this utility package.';
  end if;

  update public.job_packages package
  set status = v_next_status,
      updated_at = now()
  where package.id = p_package_id
    and package.company_id = v_company_id;

  return v_next_status;
end;
$$;

revoke all on function public.set_job_package_status(uuid, text)
  from public, anon;
grant execute on function public.set_job_package_status(uuid, text)
  to authenticated;

-- Exactly one package revision may be active for a job. Closing every other
-- active package also repairs the reverse-revision case where an older package
-- is deliberately reactivated.
create or replace function public.supersede_prior_job_package()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status = 'active' then
    update public.job_packages package
    set status = 'closed',
        updated_at = now()
    where package.company_id = new.company_id
      and package.job_id = new.job_id
      and package.id <> new.id
      and package.status = 'active';
  end if;

  return new;
end;
$$;

revoke all on function public.supersede_prior_job_package()
  from public, anon, authenticated;

create or replace function public.create_job_package_from_file(
  p_job_id uuid,
  p_source_filename text,
  p_detected_reference text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_contract_id uuid;
  v_package_id uuid;
  v_name text;
begin
  if not public.linecrew_can_manage_job_packages() then
    raise exception using
      errcode = '42501',
      message = 'Only an active Admin, General Foreman, or authorized Superintendent can add job packets.';
  end if;

  select profile.company_id
  into v_company_id
  from public.profiles profile
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where profile.id = auth.uid()
    and profile.active is true;

  select job.contract_id
  into v_contract_id
  from public.jobs job
  join public.contracts contract
    on contract.id = job.contract_id
   and contract.company_id = job.company_id
   and contract.active is true
  where job.id = p_job_id
    and job.company_id = v_company_id
    and job.active is true
  for update of job;

  if v_contract_id is null then
    raise exception using
      errcode = 'P0002',
      message = 'Select an active job tied to an active company contract.';
  end if;

  if length(trim(coalesce(p_source_filename, ''))) = 0 then
    raise exception using
      errcode = '22023',
      message = 'A packet filename is required.';
  end if;

  v_name := regexp_replace(trim(p_source_filename), '\.[^.]+$', '');

  insert into public.job_packages (
    company_id, job_id, contract_id, package_name, package_number,
    source_filename, status, created_by
  ) values (
    v_company_id,
    p_job_id,
    v_contract_id,
    v_name,
    case
      when nullif(trim(coalesce(p_detected_reference, '')), '') is not null
       and not exists (
         select 1
         from public.job_packages existing
         where existing.company_id = v_company_id
           and existing.job_id = p_job_id
           and lower(trim(existing.package_number)) =
               lower(trim(p_detected_reference))
       ) then trim(p_detected_reference)
      else null
    end,
    trim(p_source_filename),
    'draft',
    auth.uid()
  )
  returning id into v_package_id;

  return v_package_id;
end;
$$;

revoke all on function public.create_job_package_from_file(uuid, text, text)
  from public, anon;
grant execute on function public.create_job_package_from_file(uuid, text, text)
  to authenticated;

-- Smart-PDF action matching is scoped to exactly the same selected job book as
-- spreadsheet validation/import. Exact action codes win; I/T/R suffix matching
-- is the first fallback; the one-character fallback must be unique.
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
    select packet_import.company_id,
      package.contract_id,
      package.job_id,
      regexp_replace(
        upper(btrim(p_contractor_unit_code)),
        '[^A-Z0-9]',
        '',
        'g'
      ) base_code,
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
     and package.status in ('draft', 'active')
    join public.jobs job
      on job.id = package.job_id
     and job.company_id = package.company_id
     and job.contract_id = package.contract_id
     and job.active is true
    join public.contracts contract
      on contract.id = package.contract_id
     and contract.company_id = package.company_id
     and contract.active is true
    join public.profiles profile
      on profile.id = auth.uid()
     and profile.company_id = packet_import.company_id
     and profile.active is true
    join public.companies company
      on company.id = profile.company_id
     and company.active is true
    where packet_import.id = p_import_id
      and nullif(btrim(coalesce(p_contractor_unit_code, '')), '') is not null
  ), selected_book as (
    select public.linecrew_resolve_job_price_book(
      context.company_id,
      context.job_id,
      context.contract_id
    ) id
    from context
  ), candidates as (
    select item.id,
      item.updated_at item_updated_at,
      regexp_replace(
        upper(btrim(item.item_code)),
        '[^A-Z0-9]',
        '',
        'g'
      ) normalized_item_code,
      context.base_code,
      context.work_suffix
    from context
    join selected_book
      on selected_book.id is not null
    join public.price_book_items item
      on item.price_book_id = selected_book.id
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
         and left(
           candidate.normalized_item_code,
           length(candidate.base_code)
         ) = candidate.base_code
         and 1 = (
           select count(distinct alternate.normalized_item_code)
           from candidates alternate
           where length(alternate.normalized_item_code) =
                 length(candidate.base_code) + 1
             and left(
               alternate.normalized_item_code,
               length(candidate.base_code)
             ) = candidate.base_code
         ) then 2
        else 99
      end match_rank
    from candidates candidate
  )
  select eligible.id
  from eligible
  where eligible.match_rank < 99
  order by eligible.match_rank,
    eligible.item_updated_at desc nulls last,
    eligible.id desc
  limit 1;
$$;

revoke all on function public.resolve_utility_packet_price_item(
  uuid, text, text
) from public, anon, authenticated;

create or replace function public.get_utility_packet_import_review(
  p_import_id uuid
)
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
  select row_item.id,
    row_item.source_page,
    row_item.source_row,
    row_item.work_point_code,
    row_item.work_point_description,
    row_item.work_type,
    row_item.material_cu,
    row_item.contractor_unit_code,
    row_item.estimated_quantity,
    row_item.description,
    row_item.confidence,
    row_item.include_in_import,
    row_item.review_note,
    public.resolve_utility_packet_price_item(
      row_item.import_id,
      row_item.contractor_unit_code,
      row_item.work_type
    ) is not null
  from public.utility_packet_import_rows row_item
  join public.utility_packet_imports packet_import
    on packet_import.id = row_item.import_id
   and packet_import.company_id = row_item.company_id
  join public.profiles profile
    on profile.id = auth.uid()
   and profile.company_id = packet_import.company_id
   and profile.active is true
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where row_item.import_id = p_import_id
    and public.linecrew_can_manage_job_packages()
  order by row_item.source_page nulls last, row_item.source_row;
$$;

revoke all on function public.get_utility_packet_import_review(uuid)
  from public, anon;
grant execute on function public.get_utility_packet_import_review(uuid)
  to authenticated;

create or replace function public.finalize_utility_packet_import(
  p_import_id uuid
)
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
  v_contract_id uuid;
  v_job_price_book_id uuid;
  v_price_book_id uuid;
  v_rows jsonb;
  v_row jsonb;
  v_work_point_id uuid;
  v_package_status text;
begin
  if not public.linecrew_can_manage_job_packages() then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to import job packets.';
  end if;

  select packet_import.job_package_id,
    packet_import.source_filename,
    packet_import.company_id,
    package.job_id,
    package.contract_id,
    job.price_book_id
  into v_package_id,
    v_source_filename,
    v_company_id,
    v_job_id,
    v_contract_id,
    v_job_price_book_id
  from public.utility_packet_imports packet_import
  join public.job_packages package
    on package.id = packet_import.job_package_id
   and package.company_id = packet_import.company_id
   and package.status in ('draft', 'active')
  join public.jobs job
    on job.id = package.job_id
   and job.company_id = package.company_id
   and job.contract_id = package.contract_id
   and job.active is true
  join public.contracts contract
    on contract.id = package.contract_id
   and contract.company_id = package.company_id
   and contract.active is true
  join public.profiles profile
    on profile.id = auth.uid()
   and profile.company_id = packet_import.company_id
   and profile.active is true
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where packet_import.id = p_import_id
    and packet_import.status = 'review'
  for update of packet_import, package, job;

  if v_package_id is null then
    raise exception using
      errcode = 'P0002',
      message = 'Packet review was not found, is not editable, or was already finalized.';
  end if;

  v_price_book_id := public.linecrew_resolve_job_price_book(
    v_company_id,
    v_job_id,
    v_contract_id
  );

  if v_price_book_id is null then
    if v_job_price_book_id is not null then
      raise exception using
        errcode = '22023',
        message = 'The job selected Price Book is not active for this contract.';
    else
      raise exception using
        errcode = 'P0002',
        message = 'No active Price Book is available for this job contract.';
    end if;
  end if;

  perform 1
  from public.price_books book
  where book.id = v_price_book_id
    and book.company_id = v_company_id
    and book.contract_id = v_contract_id
    and book.active is true
  for share;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'The selected job Price Book is no longer active.';
  end if;

  -- Make the resolver and the Foreman catalog observe the same book. This is
  -- still inside the finalizer transaction and rolls back on any later error.
  update public.jobs job
  set price_book_id = v_price_book_id
  where job.id = v_job_id
    and job.company_id = v_company_id
    and job.active is true;

  if not found then
    raise exception using
      errcode = '22023',
      message = 'The job closed while its utility packet was finalizing.';
  end if;

  update public.daily_reports report
  set price_book_id = v_price_book_id
  where report.company_id = v_company_id
    and report.job_id = v_job_id
    and report.price_book_id is null
    and lower(coalesce(report.status, 'draft')) = 'draft';

  if exists (
    select 1
    from public.utility_packet_import_rows row_item
    where row_item.import_id = p_import_id
      and row_item.include_in_import
      and nullif(btrim(row_item.contractor_unit_code), '') is null
  ) then
    raise exception using
      errcode = '22023',
      message = 'Every included production row must have a Contractor Unit. Exclude material-only rows or correct the mapping.';
  end if;

  if exists (
    select 1
    from public.utility_packet_import_rows row_item
    where row_item.import_id = p_import_id
      and row_item.include_in_import
      and row_item.contractor_unit_code is not null
      and public.resolve_utility_packet_price_item(
        row_item.import_id,
        row_item.contractor_unit_code,
        row_item.work_type
      ) is null
  ) then
    raise exception using
      errcode = 'P0002',
      message = 'One or more Contractor Units were not found in the selected job Price Book. Correct the unmatched rows before importing.';
  end if;

  select jsonb_agg(
    jsonb_build_object(
      'work_point_code', grouped.work_point_code,
      'work_point_description', grouped.work_point_description,
      'price_book_item_id', grouped.price_book_item_id,
      'unit_code', grouped.canonical_unit_code,
      'install_quantity', grouped.install_quantity,
      'transfer_quantity', grouped.transfer_quantity,
      'retirement_quantity', grouped.retirement_quantity
    )
    order by grouped.work_point_code, grouped.canonical_unit_code
  )
  into v_rows
  from (
    select min(btrim(row_item.work_point_code)) work_point_code,
      max(row_item.work_point_description) work_point_description,
      item.id price_book_item_id,
      item.item_code canonical_unit_code,
      sum(
        case when lower(row_item.work_type) = 'install'
          then row_item.estimated_quantity else 0 end
      ) install_quantity,
      sum(
        case when lower(row_item.work_type) = 'transfer'
          then row_item.estimated_quantity else 0 end
      ) transfer_quantity,
      sum(
        case when lower(row_item.work_type) = 'remove'
          then row_item.estimated_quantity else 0 end
      ) retirement_quantity
    from public.utility_packet_import_rows row_item
    join public.price_book_items item
      on item.id = public.resolve_utility_packet_price_item(
        row_item.import_id,
        row_item.contractor_unit_code,
        row_item.work_type
      )
     and item.price_book_id = v_price_book_id
     and item.company_id = v_company_id
     and item.active is true
    where row_item.import_id = p_import_id
      and row_item.include_in_import
      and row_item.contractor_unit_code is not null
    group by
      public.normalize_work_point_key(row_item.work_point_code),
      item.id,
      item.item_code
  ) grouped;

  if v_rows is null or jsonb_array_length(v_rows) = 0 then
    raise exception using
      errcode = '22023',
      message = 'No reviewed Contractor Unit rows are selected for import.';
  end if;

  for v_row in select value from jsonb_array_elements(v_rows)
  loop
    v_work_point_id := null;
    select work_point.id
    into v_work_point_id
    from public.job_package_work_points work_point
    where work_point.company_id = v_company_id
      and work_point.job_package_id = v_package_id
      and public.normalize_work_point_key(work_point.work_point_code) =
          public.normalize_work_point_key(v_row->>'work_point_code')
    order by work_point.created_at
    limit 1;

    if v_work_point_id is null then
      insert into public.job_package_work_points (
        company_id, job_package_id, job_id, work_point_code, description,
        created_by
      ) values (
        v_company_id,
        v_package_id,
        v_job_id,
        btrim(v_row->>'work_point_code'),
        nullif(btrim(coalesce(v_row->>'work_point_description', '')), ''),
        auth.uid()
      )
      returning id into v_work_point_id;
    elsif nullif(
      btrim(coalesce(v_row->>'work_point_description', '')),
      ''
    ) is not null then
      update public.job_package_work_points work_point
      set description = coalesce(
            work_point.description,
            nullif(
              btrim(coalesce(v_row->>'work_point_description', '')),
              ''
            )
          ),
          updated_at = now()
      where work_point.id = v_work_point_id
        and work_point.company_id = v_company_id;
    end if;

    insert into public.job_package_authorized_units (
      company_id, job_package_id, work_point_id, price_book_item_id, unit_code,
      authorized_install_quantity, authorized_transfer_quantity,
      authorized_retirement_quantity, created_by
    ) values (
      v_company_id,
      v_package_id,
      v_work_point_id,
      (v_row->>'price_book_item_id')::uuid,
      v_row->>'unit_code',
      (v_row->>'install_quantity')::numeric,
      (v_row->>'transfer_quantity')::numeric,
      (v_row->>'retirement_quantity')::numeric,
      auth.uid()
    )
    on conflict (work_point_id, price_book_item_id) do update set
      authorized_install_quantity = excluded.authorized_install_quantity,
      authorized_transfer_quantity = excluded.authorized_transfer_quantity,
      authorized_retirement_quantity = excluded.authorized_retirement_quantity,
      unit_code = excluded.unit_code,
      updated_at = now();
  end loop;

  update public.job_packages package
  set source_filename = v_source_filename,
      updated_at = now()
  where package.id = v_package_id
    and package.company_id = v_company_id;

  v_package_status := public.set_job_package_status(v_package_id, 'active');

  update public.utility_packet_imports packet_import
  set status = 'imported',
      reviewed_by = auth.uid(),
      reviewed_at = now()
  where packet_import.id = p_import_id
    and packet_import.company_id = v_company_id
    and packet_import.status = 'review';

  if not found then
    raise exception using
      errcode = '23514',
      message = 'The packet review changed before finalization completed.';
  end if;

  return jsonb_build_object(
    'imported_rows', jsonb_array_length(v_rows),
    'source_rows', (
      select count(*)
      from public.utility_packet_import_rows row_item
      where row_item.import_id = p_import_id
    ),
    'material_only_rows', (
      select count(*)
      from public.utility_packet_import_rows row_item
      where row_item.import_id = p_import_id
        and row_item.contractor_unit_code is null
    ),
    'consolidated_rows', jsonb_array_length(v_rows),
    'package_status', v_package_status,
    'status', v_package_status,
    'price_book_id', v_price_book_id
  );
end;
$$;

revoke all on function public.finalize_utility_packet_import(uuid)
  from public, anon;
grant execute on function public.finalize_utility_packet_import(uuid)
  to authenticated;

-- Snapshot the job's selected Price Book on the report at creation time. The
-- catalog's existing date-based fallback remains available when the job has no
-- selected Price Book.
create or replace function public.create_daily_report(
  p_job_id uuid,
  p_work_date date,
  p_regular_hours numeric default 0,
  p_overtime_hours numeric default 0,
  p_crew_name text default null,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_report_id uuid;
  v_foreman_name text;
  v_role text;
  v_contract_id uuid;
  v_price_book_id uuid;
begin
  select profile.company_id, profile.full_name,
    lower(coalesce(profile.role, ''))
  into v_company_id, v_foreman_name, v_role
  from public.profiles profile
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where profile.id = auth.uid()
    and profile.active is true;

  if v_company_id is null or v_role <> 'foreman' then
    raise exception using
      errcode = '42501',
      message = 'An active Foreman profile is required.';
  end if;

  select job.contract_id, job.price_book_id
  into v_contract_id, v_price_book_id
  from public.jobs job
  join public.contracts contract
    on contract.id = job.contract_id
   and contract.company_id = job.company_id
   and contract.active is true
  where job.id = p_job_id
    and job.company_id = v_company_id
    and job.active is true
    and public.linecrew_foreman_has_job_assignment(job.id);

  if v_contract_id is null then
    raise exception 'Active job not found';
  end if;

  if v_price_book_id is not null and not exists (
    select 1
    from public.price_books book
    where book.id = v_price_book_id
      and book.company_id = v_company_id
      and book.contract_id = v_contract_id
  ) then
    raise exception using
      errcode = '22023',
      message = 'The job Price Book does not belong to this company and contract.';
  end if;

  insert into public.daily_reports (
    company_id, job_id, work_date, foreman_id, created_by, foreman_name,
    crew_name, regular_hours, overtime_hours, notes, price_book_id
  ) values (
    v_company_id, p_job_id, coalesce(p_work_date, current_date), auth.uid(),
    auth.uid(), v_foreman_name, nullif(trim(p_crew_name), ''),
    coalesce(p_regular_hours, 0), coalesce(p_overtime_hours, 0),
    nullif(trim(p_notes), ''), v_price_book_id
  )
  returning id into v_report_id;

  return v_report_id;
end;
$$;

revoke all on function public.create_daily_report(
  uuid, date, numeric, numeric, text, text
) from public, anon;
grant execute on function public.create_daily_report(
  uuid, date, numeric, numeric, text, text
) to authenticated;

create or replace function public.update_daily_report(
  p_report_id uuid,
  p_job_id uuid,
  p_work_date date,
  p_regular_hours numeric,
  p_overtime_hours numeric,
  p_crew_name text,
  p_notes text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_contract_id uuid;
  v_price_book_id uuid;
begin
  select profile.company_id, lower(coalesce(profile.role, ''))
  into v_company_id, v_role
  from public.profiles profile
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where profile.id = auth.uid()
    and profile.active is true;

  if v_company_id is null or v_role <> 'foreman' then
    raise exception using
      errcode = '42501',
      message = 'An active Foreman profile is required.';
  end if;

  select job.contract_id, job.price_book_id
  into v_contract_id, v_price_book_id
  from public.jobs job
  join public.contracts contract
    on contract.id = job.contract_id
   and contract.company_id = job.company_id
   and contract.active is true
  where job.id = p_job_id
    and job.company_id = v_company_id
    and job.active is true
    and public.linecrew_foreman_has_job_assignment(job.id);

  if v_contract_id is null then
    raise exception using
      errcode = 'P0002',
      message = 'Active assigned job not found.';
  end if;

  if v_price_book_id is not null and not exists (
    select 1
    from public.price_books book
    where book.id = v_price_book_id
      and book.company_id = v_company_id
      and book.contract_id = v_contract_id
  ) then
    raise exception using
      errcode = '22023',
      message = 'The job Price Book does not belong to this company and contract.';
  end if;

  update public.daily_reports report
  set job_id = p_job_id,
      price_book_id = case
        when report.job_id is distinct from p_job_id then v_price_book_id
        else coalesce(report.price_book_id, v_price_book_id)
      end,
      work_date = p_work_date,
      regular_hours = coalesce(p_regular_hours, 0),
      overtime_hours = coalesce(p_overtime_hours, 0),
      crew_name = nullif(trim(p_crew_name), ''),
      notes = nullif(trim(p_notes), ''),
      updated_at = now()
  where report.id = p_report_id
    and report.company_id = v_company_id
    and report.status = 'draft'
    and report.foreman_id = auth.uid();

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Draft report not found or cannot be edited.';
  end if;
end;
$$;

revoke all on function public.update_daily_report(
  uuid, uuid, date, numeric, numeric, text, text
) from public, anon;
grant execute on function public.update_daily_report(
  uuid, uuid, date, numeric, numeric, text, text
) to authenticated;

-- Keep the browser's review result identical to the atomic import result. In
-- particular, a code in an older active contract book must not be shown as
-- valid when the job will use the newest active book.
create or replace function public.validate_job_package_import(
  p_package_id uuid,
  p_rows jsonb
)
returns table(
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
  v_contract_id uuid;
  v_job_id uuid;
  v_job_price_book_id uuid;
  v_price_book_id uuid;
  v_row jsonb;
  v_work_point text;
  v_unit_code text;
  v_error text;
  v_install numeric;
  v_transfer numeric;
  v_retirement numeric;
begin
  if not public.linecrew_can_manage_job_packages() then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to validate job packet imports.';
  end if;

  select profile.company_id
  into v_company_id
  from public.profiles profile
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where profile.id = auth.uid()
    and profile.active is true;

  select package.contract_id, package.job_id, job.price_book_id
  into v_contract_id, v_job_id, v_job_price_book_id
  from public.job_packages package
  join public.jobs job
    on job.id = package.job_id
   and job.company_id = package.company_id
   and job.contract_id = package.contract_id
  join public.contracts contract
    on contract.id = package.contract_id
   and contract.company_id = package.company_id
   and contract.active is true
  where package.id = p_package_id
    and package.company_id = v_company_id
    and package.status in ('draft', 'active')
    and job.active is true;

  if v_contract_id is null then
    raise exception using
      errcode = 'P0002',
      message = 'An editable utility package on an active company job is required.';
  end if;

  v_price_book_id := public.linecrew_resolve_job_price_book(
    v_company_id,
    v_job_id,
    v_contract_id
  );

  if v_price_book_id is null then
    if v_job_price_book_id is not null then
      raise exception using
        errcode = '22023',
        message = 'The job selected Price Book is not active for this contract.';
    else
      raise exception using
        errcode = 'P0002',
        message = 'No active Price Book is available for this job contract.';
    end if;
  end if;

  if coalesce(jsonb_typeof(p_rows), '') <> 'array' then
    raise exception using
      errcode = '22023',
      message = 'Import between 1 and 2,000 consolidated rows.';
  end if;

  if jsonb_array_length(p_rows) = 0 or jsonb_array_length(p_rows) > 2000 then
    raise exception using
      errcode = '22023',
      message = 'Import between 1 and 2,000 consolidated rows.';
  end if;

  for v_row in select value from jsonb_array_elements(p_rows)
  loop
    row_number := coalesce((v_row->>'row_number')::integer, 0);
    v_work_point := btrim(coalesce(v_row->>'work_point_code', ''));
    v_unit_code := btrim(coalesce(v_row->>'unit_code', ''));
    v_install := coalesce((v_row->>'install_quantity')::numeric, 0);
    v_transfer := coalesce((v_row->>'transfer_quantity')::numeric, 0);
    v_retirement := coalesce((v_row->>'retirement_quantity')::numeric, 0);
    v_error := null;

    if v_work_point = '' then
      v_error := 'Missing work point';
    elsif v_unit_code = '' then
      v_error := 'Missing unit code';
    elsif v_install < 0 or v_transfer < 0 or v_retirement < 0
       or v_install + v_transfer + v_retirement <= 0 then
      v_error := 'Authorized quantity must be greater than zero';
    elsif not exists (
      select 1
      from public.price_book_items item
      where item.company_id = v_company_id
        and item.price_book_id = v_price_book_id
        and item.active is true
        and lower(btrim(item.item_code)) = lower(v_unit_code)
    ) then
      v_error := 'Unit code was not found in the selected job Price Book';
    end if;

    is_valid := v_error is null;
    error_message := v_error;
    return next;
  end loop;
exception
  when invalid_text_representation or numeric_value_out_of_range then
    raise exception using
      errcode = '22023',
      message = 'One or more quantities are not valid numbers.';
end;
$$;

revoke all on function public.validate_job_package_import(uuid, jsonb)
  from public, anon;
grant execute on function public.validate_job_package_import(uuid, jsonb)
  to authenticated;

-- Spreadsheet imports use one deterministic active Price Book for the entire
-- payload. The selected book is also written to the job before package
-- activation, guaranteeing Foreman catalog rows use the same item IDs.
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
  v_contract_id uuid;
  v_job_id uuid;
  v_job_active boolean;
  v_existing_package_status text;
  v_job_price_book_id uuid;
  v_price_book_id uuid;
  v_row jsonb;
  v_row_number integer;
  v_work_point text;
  v_description text;
  v_unit_code text;
  v_install numeric;
  v_transfer numeric;
  v_retirement numeric;
  v_work_point_id uuid;
  v_item_id uuid;
  v_canonical_code text;
  v_imported integer := 0;
  v_package_status text;
begin
  if not public.linecrew_can_manage_job_packages() then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to import job packets.';
  end if;

  select profile.company_id
  into v_company_id
  from public.profiles profile
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where profile.id = auth.uid()
    and profile.active is true;

  if v_company_id is null then
    raise exception using
      errcode = '42501',
      message = 'An active company profile is required.';
  end if;

  select package.contract_id, package.job_id, job.active, package.status,
    job.price_book_id
  into v_contract_id, v_job_id, v_job_active, v_existing_package_status,
    v_job_price_book_id
  from public.job_packages package
  join public.jobs job
    on job.id = package.job_id
   and job.company_id = package.company_id
   and job.contract_id = package.contract_id
  join public.contracts contract
    on contract.id = package.contract_id
   and contract.company_id = package.company_id
   and contract.active is true
  where package.id = p_package_id
    and package.company_id = v_company_id
  for update of package, job;

  if v_contract_id is null then
    raise exception using
      errcode = 'P0002',
      message = 'Utility job package was not found in your company.';
  end if;

  if v_job_active is not true then
    raise exception using
      errcode = '22023',
      message = 'Reopen the job before importing its utility package.';
  end if;

  if v_existing_package_status not in ('draft', 'active') then
    raise exception using
      errcode = '22023',
      message = 'A closed utility package cannot be imported again.';
  end if;

  v_price_book_id := public.linecrew_resolve_job_price_book(
    v_company_id,
    v_job_id,
    v_contract_id
  );

  if v_price_book_id is null then
    if v_job_price_book_id is not null then
      raise exception using
        errcode = '22023',
        message = 'The job selected Price Book is not active for this contract.';
    else
      raise exception using
        errcode = 'P0002',
        message = 'No active Price Book is available for this job contract.';
    end if;
  end if;

  perform 1
  from public.price_books book
  where book.id = v_price_book_id
    and book.company_id = v_company_id
    and book.contract_id = v_contract_id
    and book.active is true
  for share;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'The selected job Price Book is no longer active.';
  end if;

  if coalesce(jsonb_typeof(p_rows), '') <> 'array' then
    raise exception using
      errcode = '22023',
      message = 'Import between 1 and 2,000 consolidated rows.';
  end if;

  if jsonb_array_length(p_rows) = 0 or jsonb_array_length(p_rows) > 2000 then
    raise exception using
      errcode = '22023',
      message = 'Import between 1 and 2,000 consolidated rows.';
  end if;

  -- Validate and lock every referenced item before the first write. This keeps
  -- validation and insertion on the same Price Book snapshot.
  for v_row, v_row_number in
    select row_item.value, row_item.ordinality::integer
    from jsonb_array_elements(p_rows) with ordinality as row_item(value, ordinality)
  loop
    v_work_point := btrim(coalesce(v_row->>'work_point_code', ''));
    v_unit_code := btrim(coalesce(v_row->>'unit_code', ''));
    v_install := coalesce((v_row->>'install_quantity')::numeric, 0);
    v_transfer := coalesce((v_row->>'transfer_quantity')::numeric, 0);
    v_retirement := coalesce((v_row->>'retirement_quantity')::numeric, 0);

    if v_work_point = '' then
      raise exception using
        errcode = '22023',
        message = format('Spreadsheet row %s is missing a work point.', v_row_number);
    end if;

    if v_unit_code = '' then
      raise exception using
        errcode = '22023',
        message = format('Spreadsheet row %s is missing a unit code.', v_row_number);
    end if;

    if v_install < 0 or v_transfer < 0 or v_retirement < 0
       or v_install + v_transfer + v_retirement <= 0 then
      raise exception using
        errcode = '22023',
        message = format(
          'Spreadsheet row %s must have a nonnegative authorized quantity greater than zero.',
          v_row_number
        );
    end if;

    v_item_id := null;
    select item.id
    into v_item_id
    from public.price_book_items item
    where item.company_id = v_company_id
      and item.price_book_id = v_price_book_id
      and item.active is true
      and lower(btrim(item.item_code)) = lower(v_unit_code)
    for share;

    if v_item_id is null then
      raise exception using
        errcode = 'P0002',
        message = format(
          'Unit code "%s" was not found in the selected job Price Book.',
          v_unit_code
        );
    end if;
  end loop;

  for v_row in select value from jsonb_array_elements(p_rows)
  loop
    v_work_point := btrim(v_row->>'work_point_code');
    v_description := nullif(btrim(coalesce(
      v_row->>'work_point_description', ''
    )), '');
    v_unit_code := btrim(v_row->>'unit_code');
    v_install := coalesce((v_row->>'install_quantity')::numeric, 0);
    v_transfer := coalesce((v_row->>'transfer_quantity')::numeric, 0);
    v_retirement := coalesce((v_row->>'retirement_quantity')::numeric, 0);

    v_work_point_id := null;
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
      set description = coalesce(description, v_description),
          updated_at = now()
      where id = v_work_point_id
        and company_id = v_company_id;
    end if;

    v_item_id := null;
    v_canonical_code := null;
    select item.id, item.item_code
    into v_item_id, v_canonical_code
    from public.price_book_items item
    where item.company_id = v_company_id
      and item.price_book_id = v_price_book_id
      and item.active is true
      and lower(btrim(item.item_code)) = lower(v_unit_code)
    for share;

    if v_item_id is null then
      raise exception using
        errcode = 'P0002',
        message = format(
          'Unit code "%s" is no longer available in the selected job Price Book.',
          v_unit_code
        );
    end if;

    insert into public.job_package_authorized_units (
      company_id, job_package_id, work_point_id, price_book_item_id, unit_code,
      authorized_install_quantity, authorized_transfer_quantity,
      authorized_retirement_quantity, created_by
    ) values (
      v_company_id, p_package_id, v_work_point_id, v_item_id, v_canonical_code,
      v_install, v_transfer, v_retirement, auth.uid()
    )
    on conflict (work_point_id, price_book_item_id) do update set
      authorized_install_quantity = excluded.authorized_install_quantity,
      authorized_transfer_quantity = excluded.authorized_transfer_quantity,
      authorized_retirement_quantity = excluded.authorized_retirement_quantity,
      unit_code = excluded.unit_code,
      updated_at = now();

    v_imported := v_imported + 1;
  end loop;

  update public.jobs job
  set price_book_id = v_price_book_id
  where job.id = v_job_id
    and job.company_id = v_company_id
    and job.active is true;

  if not found then
    raise exception using
      errcode = '22023',
      message = 'The job closed while its utility package was importing.';
  end if;

  update public.daily_reports report
  set price_book_id = v_price_book_id
  where report.company_id = v_company_id
    and report.job_id = v_job_id
    and report.price_book_id is null
    and lower(coalesce(report.status, 'draft')) = 'draft';

  update public.job_packages package
  set source_filename = nullif(btrim(coalesce(p_source_filename, '')), ''),
      updated_at = now()
  where package.id = p_package_id
    and package.company_id = v_company_id;

  -- This call enforces the shared status rules and fires the existing
  -- supersede_prior_job_package trigger in this transaction.
  v_package_status := public.set_job_package_status(p_package_id, 'active');

  return jsonb_build_object(
    'imported_rows', v_imported,
    'package_status', v_package_status,
    'status', v_package_status,
    'price_book_id', v_price_book_id
  );
exception
  when invalid_text_representation or numeric_value_out_of_range then
    raise exception using
      errcode = '22023',
      message = 'One or more quantities are not valid numbers. Nothing was imported.';
end;
$$;

revoke all on function public.import_job_package_units(uuid, jsonb, text)
  from public, anon;
grant execute on function public.import_job_package_units(uuid, jsonb, text)
  to authenticated;

create or replace function public.finalize_job_package_spreadsheet_import(
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
  v_result jsonb;
  v_package_status text;
begin
  if not public.linecrew_can_manage_job_packages() then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to import job packets.';
  end if;

  select profile.company_id
  into v_company_id
  from public.profiles profile
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where profile.id = auth.uid()
    and profile.active is true;

  perform 1
  from public.job_packages package
  join public.jobs job
    on job.id = package.job_id
   and job.company_id = package.company_id
   and job.contract_id = package.contract_id
  where package.id = p_package_id
    and package.company_id = v_company_id
    and package.status in ('draft', 'active')
    and job.active is true
  for update of package, job;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'An editable utility package on an active company job is required.';
  end if;

  -- A PostgreSQL RPC call is one transaction. Any validation, import, job
  -- Price Book update, activation or supersede failure rolls back every write.
  v_result := public.import_job_package_units(
    p_package_id,
    p_rows,
    p_source_filename
  );

  select package.status
  into v_package_status
  from public.job_packages package
  where package.id = p_package_id
    and package.company_id = v_company_id;

  if v_package_status is distinct from 'active' then
    raise exception using
      errcode = '23514',
      message = 'The spreadsheet imported but the utility package did not activate.';
  end if;

  return coalesce(v_result, '{}'::jsonb) || jsonb_build_object(
    'package_status', 'active',
    'status', 'active'
  );
end;
$$;

revoke all on function public.finalize_job_package_spreadsheet_import(
  uuid, jsonb, text
) from public, anon;
grant execute on function public.finalize_job_package_spreadsheet_import(
  uuid, jsonb, text
) to authenticated;

-- Pure internal rule used by every progress/remaining calculation. A new draft
-- reserves units so two Foremen cannot unknowingly claim the same work. Once a
-- report is returned for correction, it stops consuming authorization until it
-- is submitted again. Rejected and archived reports never count.
create or replace function public.linecrew_report_counts_toward_progress(
  p_status text,
  p_reviewed_at timestamptz,
  p_review_notes text,
  p_archived boolean
)
returns boolean
language sql
immutable
parallel safe
set search_path = ''
as $$
  select coalesce(p_archived, false) is false
    and (
      lower(coalesce(p_status, 'draft')) in ('submitted', 'approved')
      or (
        lower(coalesce(p_status, 'draft')) = 'draft'
        and p_reviewed_at is null
        and nullif(btrim(coalesce(p_review_notes, '')), '') is null
      )
    );
$$;

revoke all on function public.linecrew_report_counts_toward_progress(
  text, timestamptz, text, boolean
) from public, anon, authenticated;

create or replace function public.get_job_package_work_points(p_package_id uuid)
returns table(
  work_point_id uuid, work_point_code text, work_point_description text,
  authorized_unit_id uuid, unit_code text, unit_name text, unit_description text,
  authorized_install_quantity numeric, authorized_retirement_quantity numeric,
  reported_install_quantity numeric, reported_retirement_quantity numeric,
  approved_install_quantity numeric, approved_retirement_quantity numeric,
  authorized_value numeric, reported_value numeric, approved_value numeric
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
  v_job_id uuid;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or not v_active or
     v_role not in ('admin', 'gf', 'owner', 'superintendent') then
    raise exception using
      errcode = '42501',
      message = 'Only active company leadership can view package progress.';
  end if;

  if v_role = 'superintendent' and
     not public.linecrew_has_capability('job_packages') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have job packages permission.';
  end if;

  select package.job_id
  into v_job_id
  from public.job_packages package
  where package.id = p_package_id
    and package.company_id = v_company_id;

  if v_job_id is null then
    raise exception using
      errcode = 'P0002',
      message = 'Utility job package was not found in your company.';
  end if;

  return query
  select work_point.id, work_point.work_point_code, work_point.description,
    authorized.id, authorized.unit_code, item.item_name, item.description,
    coalesce(
      authorized.authorized_install_quantity +
      authorized.authorized_transfer_quantity,
      0
    ),
    coalesce(authorized.authorized_retirement_quantity, 0),
    coalesce(production.reported_install + production.reported_transfer, 0),
    coalesce(production.reported_retirement, 0),
    coalesce(production.approved_install + production.approved_transfer, 0),
    coalesce(production.approved_retirement, 0),
    coalesce(
      authorized.authorized_install_quantity * item.install_price +
      authorized.authorized_transfer_quantity * item.transfer_price +
      authorized.authorized_retirement_quantity * item.retirement_price,
      0
    ),
    coalesce(
      least(
        production.reported_install,
        authorized.authorized_install_quantity
      ) * item.install_price +
      least(
        production.reported_transfer,
        authorized.authorized_transfer_quantity
      ) * item.transfer_price +
      least(
        production.reported_retirement,
        authorized.authorized_retirement_quantity
      ) * item.retirement_price,
      0
    ),
    coalesce(
      least(
        production.approved_install,
        authorized.authorized_install_quantity
      ) * item.install_price +
      least(
        production.approved_transfer,
        authorized.authorized_transfer_quantity
      ) * item.transfer_price +
      least(
        production.approved_retirement,
        authorized.authorized_retirement_quantity
      ) * item.retirement_price,
      0
    )
  from public.job_package_work_points work_point
  left join public.job_package_authorized_units authorized
    on authorized.work_point_id = work_point.id
   and authorized.company_id = work_point.company_id
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
    where location.company_id = v_company_id
      and report.job_id = v_job_id
      and public.normalize_work_point_key(location.pole_location) =
          public.normalize_work_point_key(work_point.work_point_code)
      and location.price_book_item_id = authorized.price_book_item_id
      and public.linecrew_report_counts_toward_progress(
        report.status,
        report.reviewed_at,
        report.review_notes,
        report.archived
      )
  ) production on authorized.id is not null
  where work_point.job_package_id = p_package_id
    and work_point.company_id = v_company_id
  order by work_point.work_point_key, authorized.unit_code;
end;
$$;

revoke all on function public.get_job_package_work_points(uuid)
  from public, anon;
grant execute on function public.get_job_package_work_points(uuid)
  to authenticated;

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
  v_company_id uuid;
  v_job_id uuid;
begin
  if not public.linecrew_can_manage_job_packages() then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to view package progress.';
  end if;

  select profile.company_id
  into v_company_id
  from public.profiles profile
  where profile.id = auth.uid()
    and profile.active is true;

  select package.job_id
  into v_job_id
  from public.job_packages package
  where package.id = p_package_id
    and package.company_id = v_company_id;

  if v_job_id is null then
    raise exception using
      errcode = 'P0002',
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
      authorized.authorized_retirement_quantity * item.retirement_price,
      0
    ),
    coalesce(
      least(
        production.reported_install,
        authorized.authorized_install_quantity
      ) * item.install_price +
      least(
        production.reported_transfer,
        authorized.authorized_transfer_quantity
      ) * item.transfer_price +
      least(
        production.reported_retirement,
        authorized.authorized_retirement_quantity
      ) * item.retirement_price,
      0
    ),
    coalesce(
      least(
        production.approved_install,
        authorized.authorized_install_quantity
      ) * item.install_price +
      least(
        production.approved_transfer,
        authorized.authorized_transfer_quantity
      ) * item.transfer_price +
      least(
        production.approved_retirement,
        authorized.authorized_retirement_quantity
      ) * item.retirement_price,
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
    where location.company_id = v_company_id
      and report.job_id = v_job_id
      and public.normalize_work_point_key(location.pole_location) =
          public.normalize_work_point_key(point.work_point_code)
      and location.price_book_item_id = authorized.price_book_item_id
      and public.linecrew_report_counts_toward_progress(
        report.status,
        report.reviewed_at,
        report.review_notes,
        report.archived
      )
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

create or replace function public.get_daily_report_unit_locations_v2(
  p_report_id uuid
)
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
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_report_company_id uuid;
  v_report_creator uuid;
  v_report_job_id uuid;
  v_can_see_actual boolean;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or not v_active or
     v_role not in ('foreman', 'gf', 'superintendent', 'admin', 'owner') then
    raise exception using
      errcode = '42501',
      message = 'An active production profile is required.';
  end if;

  select report.company_id, report.created_by, report.job_id
  into v_report_company_id, v_report_creator, v_report_job_id
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

  v_can_see_actual := v_role in ('admin', 'gf', 'owner') or
    (
      v_role = 'superintendent'
      and public.linecrew_has_capability('actual_pricing')
    );

  return query
  select location.id, unit.price_book_item_id, unit.item_code, unit.item_name,
    unit.description, unit.unit_of_measure, unit.category, location.pole_location,
    case
      when v_can_see_actual then unit.actual_install_price
      else unit.adjusted_install_price
    end,
    case
      when v_can_see_actual then unit.actual_retirement_price
      else unit.adjusted_retirement_price
    end,
    case when v_can_see_actual then unit.actual_install_price else null end,
    case when v_can_see_actual then unit.actual_retirement_price else null end,
    unit.adjusted_install_price,
    unit.adjusted_retirement_price,
    unit.has_adjustment,
    location.install_quantity,
    location.transfer_quantity,
    location.retirement_quantity,
    case when v_can_see_actual then round(
      location.install_quantity * unit.actual_install_price +
      location.transfer_quantity * unit.actual_transfer_price +
      location.retirement_quantity * unit.actual_retirement_price,
      2
    ) else null end,
    round(
      location.install_quantity * unit.adjusted_install_price +
      location.transfer_quantity * unit.adjusted_transfer_price +
      location.retirement_quantity * unit.adjusted_retirement_price,
      2
    ),
    case when v_can_see_actual then round(
      location.install_quantity * unit.actual_install_price +
      location.transfer_quantity * unit.actual_transfer_price +
      location.retirement_quantity * unit.actual_retirement_price,
      2
    ) else round(
      location.install_quantity * unit.adjusted_install_price +
      location.transfer_quantity * unit.adjusted_transfer_price +
      location.retirement_quantity * unit.adjusted_retirement_price,
      2
    ) end,
    case
      when packages.package_count = 0 then 'pending_packet'
      when authorizations.authorized_unit_count = 0 then 'redline'
      when production.reported_install > authorizations.authorized_install or
           production.reported_transfer > authorizations.authorized_transfer or
           production.reported_retirement > authorizations.authorized_retirement
        then 'redline'
      else 'authorized'
    end,
    case
      when packages.package_count = 0 then
        'No active utility job packet has been added yet. This entry will reconcile when a packet is imported.'
      when authorizations.authorized_unit_count = 0 then
        'This unit is not authorized at this pole or work point in the active utility job packet.'
      when production.reported_install > authorizations.authorized_install or
           production.reported_transfer > authorizations.authorized_transfer or
           production.reported_retirement > authorizations.authorized_retirement
        then 'Reported quantity exceeds the active utility-authorized quantity at this pole or work point.'
      else null
    end
  from public.daily_production_unit_locations location
  join public.daily_production_units unit
    on unit.id = location.daily_production_unit_id
   and unit.company_id = location.company_id
   and unit.daily_report_id = location.daily_report_id
   and unit.price_book_item_id = location.price_book_item_id
  cross join lateral (
    select count(*)::integer package_count
    from public.job_packages package
    where package.company_id = v_company_id
      and package.job_id = v_report_job_id
      and package.status = 'active'
  ) packages
  cross join lateral (
    select count(authorized.id)::integer authorized_unit_count,
      coalesce(sum(authorized.authorized_install_quantity), 0) authorized_install,
      coalesce(sum(authorized.authorized_transfer_quantity), 0) authorized_transfer,
      coalesce(sum(authorized.authorized_retirement_quantity), 0) authorized_retirement
    from public.job_packages package
    join public.job_package_work_points work_point
      on work_point.job_package_id = package.id
     and work_point.company_id = package.company_id
    join public.job_package_authorized_units authorized
      on authorized.work_point_id = work_point.id
     and authorized.company_id = work_point.company_id
    where package.company_id = v_company_id
      and package.job_id = v_report_job_id
      and package.status = 'active'
      and public.normalize_work_point_key(work_point.work_point_code) =
          public.normalize_work_point_key(location.pole_location)
      and authorized.price_book_item_id = location.price_book_item_id
  ) authorizations
  cross join lateral (
    select
      coalesce(sum(other.install_quantity), 0) reported_install,
      coalesce(sum(other.transfer_quantity), 0) reported_transfer,
      coalesce(sum(other.retirement_quantity), 0) reported_retirement
    from public.daily_production_unit_locations other
    join public.daily_reports report
      on report.id = other.daily_report_id
     and report.company_id = other.company_id
    where other.company_id = v_company_id
      and report.job_id = v_report_job_id
      and public.linecrew_report_counts_toward_progress(
        report.status,
        report.reviewed_at,
        report.review_notes,
        report.archived
      )
      and other.price_book_item_id = location.price_book_item_id
      and public.normalize_work_point_key(other.pole_location) =
          public.normalize_work_point_key(location.pole_location)
  ) production
  where location.daily_report_id = p_report_id
    and location.company_id = v_company_id
  order by location.pole_location_key, unit.item_code;
end;
$$;

revoke all on function public.get_daily_report_unit_locations_v2(uuid)
  from public, anon;
grant execute on function public.get_daily_report_unit_locations_v2(uuid)
  to authenticated;

-- Keep the Foreman picker on the exact same definition of consumed work as
-- the Admin progress dashboard.
create or replace function public.get_remaining_job_units_for_field(
  p_job_id uuid
)
returns table (
  package_id uuid,
  package_name text,
  work_point_id uuid,
  work_point_code text,
  work_point_description text,
  authorized_unit_id uuid,
  unit_code text,
  unit_name text,
  unit_description text,
  work_type text,
  authorized_quantity numeric,
  draft_quantity numeric,
  submitted_quantity numeric,
  approved_quantity numeric,
  remaining_quantity numeric
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
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('foreman', 'gf', 'superintendent', 'admin', 'owner') then
    raise exception using
      errcode = '42501',
      message = 'An active company field or leadership profile is required.';
  end if;

  if v_role = 'superintendent' and
     not public.linecrew_has_capability('job_packages') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have job package permission.';
  end if;

  if not exists (
    select 1
    from public.jobs job
    where job.id = p_job_id
      and job.company_id = v_company_id
      and job.active is true
      and (
        v_role <> 'foreman'
        or public.linecrew_foreman_has_job_assignment(job.id)
      )
  ) then
    raise exception using
      errcode = 'P0002',
      message = 'Active job was not found or is not assigned to this Foreman.';
  end if;

  return query
  with authorized_rows as (
    select
      package.id as package_id,
      package.package_name,
      point.id as work_point_id,
      point.work_point_code,
      point.description as work_point_description,
      authorized.id as authorized_unit_id,
      authorized.price_book_item_id,
      authorized.unit_code,
      item.item_name as unit_name,
      item.description as unit_description,
      work.work_type,
      work.authorized_quantity
    from public.job_packages package
    join public.job_package_work_points point
      on point.job_package_id = package.id
     and point.company_id = package.company_id
    join public.job_package_authorized_units authorized
      on authorized.work_point_id = point.id
     and authorized.company_id = point.company_id
    left join public.price_book_items item
      on item.id = authorized.price_book_item_id
     and item.company_id = authorized.company_id
    cross join lateral (
      values
        ('install'::text, coalesce(authorized.authorized_install_quantity, 0)),
        ('transfer'::text, coalesce(authorized.authorized_transfer_quantity, 0)),
        ('remove'::text, coalesce(authorized.authorized_retirement_quantity, 0))
    ) work(work_type, authorized_quantity)
    where package.company_id = v_company_id
      and package.job_id = p_job_id
      and package.status = 'active'
      and work.authorized_quantity > 0
  ), usage as (
    select
      authorized.authorized_unit_id,
      authorized.work_type,
      coalesce(sum(
        case
          when lower(coalesce(report.status, 'draft')) = 'draft'
          then case authorized.work_type
            when 'install' then location.install_quantity
            when 'transfer' then location.transfer_quantity
            else location.retirement_quantity
          end
          else 0
        end
      ), 0)::numeric as draft_quantity,
      coalesce(sum(
        case when lower(coalesce(report.status, '')) = 'submitted'
          then case authorized.work_type
            when 'install' then location.install_quantity
            when 'transfer' then location.transfer_quantity
            else location.retirement_quantity
          end
          else 0
        end
      ), 0)::numeric as submitted_quantity,
      coalesce(sum(
        case when lower(coalesce(report.status, '')) = 'approved'
          then case authorized.work_type
            when 'install' then location.install_quantity
            when 'transfer' then location.transfer_quantity
            else location.retirement_quantity
          end
          else 0
        end
      ), 0)::numeric as approved_quantity
    from authorized_rows authorized
    join public.daily_production_unit_locations location
      on location.company_id = v_company_id
     and location.price_book_item_id = authorized.price_book_item_id
     and public.normalize_work_point_key(location.pole_location) =
         public.normalize_work_point_key(authorized.work_point_code)
    join public.daily_production_units line
      on line.id = location.daily_production_unit_id
     and line.company_id = location.company_id
     and line.job_id = p_job_id
    join public.daily_reports report
      on report.id = location.daily_report_id
     and report.company_id = location.company_id
     and report.job_id = p_job_id
     and public.linecrew_report_counts_toward_progress(
       report.status,
       report.reviewed_at,
       report.review_notes,
       report.archived
     )
    group by authorized.authorized_unit_id, authorized.work_type
  )
  select
    authorized.package_id,
    authorized.package_name,
    authorized.work_point_id,
    authorized.work_point_code,
    authorized.work_point_description,
    authorized.authorized_unit_id,
    authorized.unit_code,
    authorized.unit_name,
    authorized.unit_description,
    authorized.work_type,
    authorized.authorized_quantity,
    coalesce(usage.draft_quantity, 0),
    coalesce(usage.submitted_quantity, 0),
    coalesce(usage.approved_quantity, 0),
    greatest(
      authorized.authorized_quantity -
      coalesce(usage.draft_quantity, 0) -
      coalesce(usage.submitted_quantity, 0) -
      coalesce(usage.approved_quantity, 0),
      0
    )::numeric as remaining_quantity
  from authorized_rows authorized
  left join usage
    on usage.authorized_unit_id = authorized.authorized_unit_id
   and usage.work_type = authorized.work_type
  order by
    public.normalize_work_point_key(authorized.work_point_code),
    authorized.unit_code,
    authorized.work_type;
end;
$$;

revoke all on function public.get_remaining_job_units_for_field(uuid)
  from public, anon;
grant execute on function public.get_remaining_job_units_for_field(uuid)
  to authenticated;

create or replace function public.get_job_progress_dashboard()
returns table(
  job_id uuid, package_count bigint, work_point_count bigint,
  authorized_value numeric, reported_value numeric, approved_value numeric,
  remaining_value numeric, reported_percent numeric, approved_percent numeric,
  report_count bigint, redline_count bigint, pending_packet_count bigint
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
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin', 'gf', 'owner', 'superintendent') then
    raise exception using
      errcode = '42501',
      message = 'Only active company leadership can view job progress.';
  end if;

  if v_role = 'superintendent' and
     not public.linecrew_has_capability('reporting') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have reporting permission.';
  end if;

  return query
  with package_totals as (
    select
      package.job_id,
      count(distinct package.id)::bigint package_count,
      count(distinct progress.work_point_id)::bigint work_point_count,
      coalesce(sum(progress.authorized_value), 0)::numeric authorized_value,
      coalesce(sum(progress.reported_value), 0)::numeric reported_value,
      coalesce(sum(progress.approved_value), 0)::numeric approved_value
    from public.job_packages package
    left join lateral
      public.get_job_package_work_points(package.id) progress on true
    where package.company_id = v_company_id
      and package.status = 'active'
    group by package.job_id
  ), report_totals as (
    select
      report.job_id,
      count(distinct report.id)::bigint report_count
    from public.daily_reports report
    where report.company_id = v_company_id
      and public.linecrew_report_counts_toward_progress(
        report.status,
        report.reviewed_at,
        report.review_notes,
        report.archived
      )
    group by report.job_id
  ), exception_totals as (
    select report.job_id,
      count(*) filter (
        where location.authorization_status = 'redline'
      )::bigint redline_count,
      count(*) filter (
        where location.authorization_status = 'pending_packet'
      )::bigint pending_packet_count
    from public.daily_reports report
    cross join lateral
      public.get_daily_report_unit_locations_v2(report.id) location
    where report.company_id = v_company_id
      and public.linecrew_report_counts_toward_progress(
        report.status,
        report.reviewed_at,
        report.review_notes,
        report.archived
      )
    group by report.job_id
  )
  select
    job.id,
    coalesce(package.package_count, 0),
    coalesce(package.work_point_count, 0),
    coalesce(package.authorized_value, 0),
    coalesce(package.reported_value, 0),
    coalesce(package.approved_value, 0),
    greatest(
      coalesce(package.authorized_value, 0) -
      coalesce(package.reported_value, 0),
      0
    ),
    case
      when coalesce(package.authorized_value, 0) > 0 then round(
        least(package.reported_value / package.authorized_value * 100, 100),
        1
      )
      else 0
    end,
    case
      when coalesce(package.authorized_value, 0) > 0 then round(
        least(package.approved_value / package.authorized_value * 100, 100),
        1
      )
      else 0
    end,
    coalesce(report.report_count, 0),
    coalesce(exception.redline_count, 0),
    coalesce(exception.pending_packet_count, 0)
  from public.jobs job
  left join package_totals package
    on package.job_id = job.id
  left join report_totals report
    on report.job_id = job.id
  left join exception_totals exception
    on exception.job_id = job.id
  where job.company_id = v_company_id
  order by job.active desc, job.created_at desc;
end;
$$;

revoke all on function public.get_job_progress_dashboard()
  from public, anon;
grant execute on function public.get_job_progress_dashboard()
  to authenticated;

-- Fail the migration rather than install drifted normalization/progress rules.
do $integrity_check$
begin
  if public.normalize_work_point_key('Pole 0020') <> '20'
     or public.normalize_work_point_key('WP-000') <> '0'
     or public.normalize_work_point_key('A-002') <> 'a002' then
    raise exception 'Work-point normalization integrity check failed.';
  end if;

  if not public.linecrew_report_counts_toward_progress(
    'draft', null, null, false
  )
  or public.linecrew_report_counts_toward_progress(
    'draft', now(), 'Returned for correction', false
  )
  or public.linecrew_report_counts_toward_progress(
    'draft', null, 'Legacy return marker', false
  )
  or public.linecrew_report_counts_toward_progress(
    'rejected', null, null, false
  )
  or not public.linecrew_report_counts_toward_progress(
    'submitted', now(), 'Correction history', false
  )
  or not public.linecrew_report_counts_toward_progress(
    'approved', now(), null, false
  )
  or public.linecrew_report_counts_toward_progress(
    'approved', now(), null, true
  ) then
    raise exception 'Daily Report progress-state integrity check failed.';
  end if;
end;
$integrity_check$;

commit;
