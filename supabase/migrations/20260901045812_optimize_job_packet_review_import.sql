begin;

-- Smart-PDF packets can contain hundreds of source rows. The previous review
-- and finalization functions called resolve_utility_packet_price_item once per
-- row. Each call rebuilt and rescanned the selected Price Book, so a normal
-- 860-row Oncor jacket could exceed the Data API statement timeout. Normalize
-- active unit codes once and match every distinct source code as one set.

-- Every downstream progress query already treats common work-point aliases as
-- one location. Enforce that same identity at the storage boundary so imports
-- cannot split authorization between "Pole 0020", "WP-20" and "20".
do $$
begin
  if exists (
    select 1
    from public.job_package_work_points point
    group by point.job_package_id,
      public.normalize_work_point_key(point.work_point_code)
    having count(*) > 1
  ) then
    raise exception using
      errcode = '23505',
      message = 'Canonical duplicate job-package work points must be merged before applying the packet timeout fix.';
  end if;
end;
$$;

create unique index if not exists
  job_package_work_points_package_canonical_key_idx
  on public.job_package_work_points (
    job_package_id,
    (public.normalize_work_point_key(work_point_code))
  );

-- Serialize every child-unit mutation with package activation. Without the
-- parent row lock, a concurrent manual edit could validate the old draft
-- snapshot, wait on its foreign key, and then land after the package became an
-- immutable active baseline.
create or replace function public.enforce_draft_job_package_unit_mutation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old_package_id uuid;
  v_new_package_id uuid;
  v_status text;
begin
  if auth.uid() is null then
    if tg_op = 'DELETE' then
      return old;
    end if;
    return new;
  end if;

  if tg_op in ('UPDATE', 'DELETE') then
    v_old_package_id := old.job_package_id;
    select package.status
    into v_status
    from public.job_packages package
    where package.id = v_old_package_id
    for update;

    if found and v_status is distinct from 'draft' then
      raise exception using
        errcode = '23514',
        message = 'Active job-jacket revisions are read-only. Upload a new revision.';
    elsif not found and tg_op <> 'DELETE' then
      raise exception using
        errcode = 'P0002',
        message = 'The job-jacket package was not found.';
    end if;
  end if;

  if tg_op in ('INSERT', 'UPDATE') then
    v_new_package_id := new.job_package_id;
    v_status := null;
    select package.status
    into v_status
    from public.job_packages package
    where package.id = v_new_package_id
    for update;

    if not found then
      raise exception using
        errcode = 'P0002',
        message = 'The job-jacket package was not found.';
    elsif v_status is distinct from 'draft' then
      raise exception using
        errcode = '23514',
        message = 'Active job-jacket revisions are read-only. Upload a new revision.';
    end if;
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

revoke all on function public.enforce_draft_job_package_unit_mutation()
  from public, anon, authenticated;

-- A timeout used to occur after staging committed. Re-uploading that exact
-- file must resume the saved draft instead of failing the duplicate-file guard
-- and encouraging an Admin to create a second package.
create or replace function public.create_and_stage_utility_packet_import(
  p_job_id uuid,
  p_provider_key text,
  p_format_key text,
  p_profile_version text,
  p_source_filename text,
  p_source_sha256 text,
  p_detected_work_order text,
  p_extraction_confidence numeric,
  p_summary jsonb,
  p_rows jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_existing_package_id uuid;
  v_existing_import_id uuid;
  v_existing_package_status text;
  v_existing_import_status text;
  v_package_id uuid;
  v_import_id uuid;
begin
  if not public.linecrew_can_manage_job_packages() then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to add utility job packages.';
  end if;

  if lower(btrim(coalesce(p_source_sha256, ''))) !~ '^[0-9a-f]{64}$' then
    raise exception using
      errcode = '22023',
      message = 'The packet file fingerprint is invalid.';
  end if;

  select profile.company_id
  into v_company_id
  from public.profiles profile
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  join public.jobs job
    on job.id = p_job_id
   and job.company_id = profile.company_id
   and job.active is true
  join public.contracts contract
    on contract.id = job.contract_id
   and contract.company_id = job.company_id
   and contract.active is true
  where profile.id = auth.uid()
    and profile.active is true
  for update of job;

  if v_company_id is null then
    raise exception using
      errcode = 'P0002',
      message = 'Select an active job tied to an active company contract.';
  end if;

  select package.id,
    packet_import.id,
    package.status,
    packet_import.status
  into v_existing_package_id,
    v_existing_import_id,
    v_existing_package_status,
    v_existing_import_status
  from public.utility_packet_imports packet_import
  join public.job_packages package
    on package.id = packet_import.job_package_id
   and package.company_id = packet_import.company_id
  where packet_import.company_id = v_company_id
    and package.job_id = p_job_id
    and packet_import.source_sha256 = lower(btrim(p_source_sha256))
  order by packet_import.created_at desc, packet_import.id desc
  limit 1
  for update of packet_import, package;

  if v_existing_import_id is not null then
    if v_existing_package_status = 'draft'
       and v_existing_import_status = 'review' then
      return jsonb_build_object(
        'package_id', v_existing_package_id,
        'import_id', v_existing_import_id,
        'resumed', true
      );
    end if;

    raise exception using
      errcode = '23505',
      message = 'This exact packet file is already attached to this job.';
  end if;

  v_package_id := public.create_job_package_from_file(
    p_job_id,
    p_source_filename,
    p_detected_work_order
  );
  v_import_id := public.stage_utility_packet_import(
    v_package_id,
    p_provider_key,
    p_format_key,
    p_profile_version,
    p_source_filename,
    p_source_sha256,
    p_detected_work_order,
    p_extraction_confidence,
    p_summary,
    p_rows
  );

  return jsonb_build_object(
    'package_id', v_package_id,
    'import_id', v_import_id,
    'resumed', false
  );
end;
$$;

revoke all on function public.create_and_stage_utility_packet_import(
  uuid, text, text, text, text, text, text, numeric, jsonb, jsonb
) from public, anon;
grant execute on function public.create_and_stage_utility_packet_import(
  uuid, text, text, text, text, text, text, numeric, jsonb, jsonb
) to authenticated;

-- These are implementation details of the resumable wrapper above. Keeping
-- them server-internal prevents direct callers from bypassing same-job/SHA
-- duplicate protection.
revoke all on function public.create_job_package_from_file(uuid, text, text)
  from public, anon, authenticated;
revoke all on function public.stage_utility_packet_import(
  uuid, text, text, text, text, text, text, numeric, jsonb, jsonb
) from public, anon, authenticated;

create or replace function public.linecrew_utility_packet_import_matches(
  p_import_id uuid
)
returns table (
  row_id uuid,
  price_book_item_id uuid,
  canonical_unit_code text
)
language sql
stable
security definer
set search_path = ''
as $$
  with context as materialized (
    select packet_import.company_id,
      package.contract_id,
      package.job_id,
      public.linecrew_resolve_job_price_book(
        packet_import.company_id,
        package.job_id,
        package.contract_id
      ) price_book_id
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
      and public.linecrew_can_manage_job_packages()
  ), source_rows as materialized (
    select row_item.id row_id,
      regexp_replace(
        upper(btrim(row_item.contractor_unit_code)),
        '[^A-Z0-9]',
        '',
        'g'
      ) base_code,
      case lower(btrim(coalesce(row_item.work_type, '')))
        when 'install' then 'I'
        when 'transfer' then 'T'
        when 'remove' then 'R'
        else ''
      end work_suffix
    from public.utility_packet_import_rows row_item
    join context
      on context.company_id = row_item.company_id
    where row_item.import_id = p_import_id
      and nullif(btrim(coalesce(row_item.contractor_unit_code, '')), '')
          is not null
      and nullif(
        regexp_replace(
          upper(btrim(row_item.contractor_unit_code)),
          '[^A-Z0-9]',
          '',
          'g'
        ),
        ''
      ) is not null
  ), source_keys as materialized (
    select distinct source_row.base_code, source_row.work_suffix
    from source_rows source_row
  ), candidates as materialized (
    select item.id,
      item.item_code,
      item.updated_at,
      regexp_replace(
        upper(btrim(item.item_code)),
        '[^A-Z0-9]',
        '',
        'g'
      ) normalized_item_code
    from context
    join public.price_book_items item
      on item.price_book_id = context.price_book_id
     and item.company_id = context.company_id
     and item.active is true
  ), alternate_counts as materialized (
    select source_key.base_code,
      source_key.work_suffix,
      count(distinct candidate.normalized_item_code) alternate_count
    from source_keys source_key
    join candidates candidate
      on length(candidate.normalized_item_code) =
         length(source_key.base_code) + 1
     and left(
       candidate.normalized_item_code,
       length(source_key.base_code)
     ) = source_key.base_code
    group by source_key.base_code, source_key.work_suffix
  ), eligible as materialized (
    select source_key.base_code,
      source_key.work_suffix,
      candidate.id,
      candidate.item_code,
      candidate.updated_at,
      case
        when candidate.normalized_item_code = source_key.base_code then 0
        when candidate.normalized_item_code =
          source_key.base_code || source_key.work_suffix then 1
        else 2
      end match_rank
    from source_keys source_key
    join candidates candidate
      on candidate.normalized_item_code = source_key.base_code
      or candidate.normalized_item_code =
         source_key.base_code || source_key.work_suffix
      or (
        length(candidate.normalized_item_code) =
          length(source_key.base_code) + 1
        and left(
          candidate.normalized_item_code,
          length(source_key.base_code)
        ) = source_key.base_code
      )
    left join alternate_counts alternate
      on alternate.base_code = source_key.base_code
     and alternate.work_suffix = source_key.work_suffix
    where candidate.normalized_item_code = source_key.base_code
       or candidate.normalized_item_code =
          source_key.base_code || source_key.work_suffix
       or coalesce(alternate.alternate_count, 0) = 1
  ), best_match as materialized (
    select distinct on (eligible.base_code, eligible.work_suffix)
      eligible.base_code,
      eligible.work_suffix,
      eligible.id,
      eligible.item_code
    from eligible
    order by eligible.base_code,
      eligible.work_suffix,
      eligible.match_rank,
      eligible.updated_at desc nulls last,
      eligible.id desc
  )
  select source_row.row_id,
    best_match.id,
    best_match.item_code
  from source_rows source_row
  left join best_match
    on best_match.base_code = source_row.base_code
   and best_match.work_suffix = source_row.work_suffix;
$$;

revoke all on function public.linecrew_utility_packet_import_matches(uuid)
  from public, anon, authenticated;

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
stable
security definer
set search_path = ''
as $$
  with matches as materialized (
    select *
    from public.linecrew_utility_packet_import_matches(p_import_id)
  )
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
    matches.price_book_item_id is not null
  from public.utility_packet_import_rows row_item
  join public.utility_packet_imports packet_import
    on packet_import.id = row_item.import_id
   and packet_import.company_id = row_item.company_id
   and packet_import.status = 'review'
  join public.profiles profile
    on profile.id = auth.uid()
   and profile.company_id = packet_import.company_id
   and profile.active is true
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  left join matches
    on matches.row_id = row_item.id
  where row_item.import_id = p_import_id
    and public.linecrew_can_manage_job_packages()
  order by row_item.source_page nulls last, row_item.source_row;
$$;

revoke all on function public.get_utility_packet_import_review(uuid)
  from public, anon;
grant execute on function public.get_utility_packet_import_review(uuid)
  to authenticated;

-- Save the complete review in one atomic request. The former browser loop made
-- one RPC for every source row (860 requests for the reproduced packet).
create or replace function public.update_utility_packet_import_rows_bulk(
  p_import_id uuid,
  p_rows jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_input_count integer;
  v_distinct_count integer;
  v_expected_count integer;
  v_updated_count integer;
begin
  if not public.linecrew_can_manage_job_packages() then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to review job packets.';
  end if;

  select packet_import.company_id
  into v_company_id
  from public.utility_packet_imports packet_import
  join public.job_packages package
    on package.id = packet_import.job_package_id
   and package.company_id = packet_import.company_id
   and package.status = 'draft'
  join public.profiles profile
    on profile.id = auth.uid()
   and profile.company_id = packet_import.company_id
   and profile.active is true
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where packet_import.id = p_import_id
    and packet_import.status = 'review'
  for update of packet_import, package;

  if v_company_id is null then
    raise exception using
      errcode = 'P0002',
      message = 'Packet review was not found or is no longer editable.';
  end if;

  if jsonb_typeof(p_rows) is distinct from 'array' then
    raise exception using
      errcode = '22023',
      message = 'Packet review rows must be a JSON array.';
  end if;

  v_input_count := jsonb_array_length(p_rows);
  if v_input_count < 1 or v_input_count > 4000 then
    raise exception using
      errcode = '22023',
      message = 'Review between 1 and 4,000 packet rows at a time.';
  end if;

  with input_rows as (
    select *
    from jsonb_to_recordset(p_rows) as input_row(
      row_id uuid,
      work_point_code text,
      work_type text,
      contractor_unit_code text,
      estimated_quantity numeric,
      include_in_import boolean,
      review_note text
    )
  )
  select count(distinct input_row.row_id)
  into v_distinct_count
  from input_rows input_row;

  if v_distinct_count <> v_input_count then
    raise exception using
      errcode = '22023',
      message = 'Packet review rows contain a missing or duplicate row identifier.';
  end if;

  if exists (
    select 1
    from jsonb_to_recordset(p_rows) as input_row(
      row_id uuid,
      work_point_code text,
      work_type text,
      contractor_unit_code text,
      estimated_quantity numeric,
      include_in_import boolean,
      review_note text
    )
    where lower(btrim(coalesce(input_row.work_type, '')))
          not in ('install', 'transfer', 'remove')
       or nullif(btrim(coalesce(input_row.work_point_code, '')), '') is null
       or nullif(
         public.normalize_work_point_key(input_row.work_point_code),
         ''
       ) is null
       or (
         nullif(
           btrim(coalesce(input_row.contractor_unit_code, '')),
           ''
         ) is not null
         and nullif(
           regexp_replace(
             upper(btrim(input_row.contractor_unit_code)),
             '[^A-Z0-9]',
             '',
             'g'
           ),
           ''
         ) is null
       )
       or coalesce(input_row.estimated_quantity, 0) <= 0
  ) then
    raise exception using
      errcode = '22023',
      message = 'Every review row needs a valid work point, work type, Contractor Unit format, and quantity greater than zero.';
  end if;

  select count(*)
  into v_expected_count
  from public.utility_packet_import_rows row_item
  where row_item.import_id = p_import_id
    and row_item.company_id = v_company_id;

  if v_expected_count <> v_input_count then
    raise exception using
      errcode = '23514',
      message = 'The packet review changed. Reopen it before saving.';
  end if;

  with input_rows as (
    select *
    from jsonb_to_recordset(p_rows) as input_row(
      row_id uuid,
      work_point_code text,
      work_type text,
      contractor_unit_code text,
      estimated_quantity numeric,
      include_in_import boolean,
      review_note text
    )
  )
  update public.utility_packet_import_rows row_item
  set work_point_code = btrim(input_row.work_point_code),
      work_type = lower(btrim(input_row.work_type)),
      contractor_unit_code = nullif(
        btrim(coalesce(input_row.contractor_unit_code, '')),
        ''
      ),
      estimated_quantity = input_row.estimated_quantity,
      include_in_import = coalesce(input_row.include_in_import, false),
      review_note = nullif(
        btrim(coalesce(input_row.review_note, '')),
        ''
      )
  from input_rows input_row
  where row_item.id = input_row.row_id
    and row_item.import_id = p_import_id
    and row_item.company_id = v_company_id;

  get diagnostics v_updated_count = row_count;
  if v_updated_count <> v_input_count then
    raise exception using
      errcode = '23514',
      message = 'One or more packet review rows changed before saving.';
  end if;

  return jsonb_build_object(
    'updated_rows', v_updated_count,
    'status', 'review'
  );
end;
$$;

revoke all on function public.update_utility_packet_import_rows_bulk(
  uuid, jsonb
) from public, anon, authenticated;

-- Keep cached clients safe during deployment. The former one-row RPC updated
-- a child row without locking its parent import, so it could change review
-- data while another session was finalizing the same packet.
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
  v_company_id uuid;
  v_import_id uuid;
  v_work_type text := lower(btrim(coalesce(p_work_type, '')));
  v_contractor_unit_code text := nullif(
    btrim(coalesce(p_contractor_unit_code, '')),
    ''
  );
begin
  if not public.linecrew_can_manage_job_packages() then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to review job packets.';
  end if;

  if v_work_type not in ('install', 'transfer', 'remove') then
    raise exception using
      errcode = '22023',
      message = 'Work type must be Install, Transfer or Remove.';
  end if;
  if nullif(
    public.normalize_work_point_key(p_work_point_code),
    ''
  ) is null then
    raise exception using
      errcode = '22023',
      message = 'A valid work point is required.';
  end if;
  if v_contractor_unit_code is not null and nullif(
    regexp_replace(
      upper(v_contractor_unit_code),
      '[^A-Z0-9]',
      '',
      'g'
    ),
    ''
  ) is null then
    raise exception using
      errcode = '22023',
      message = 'Enter a Contractor Unit containing a letter or number.';
  end if;
  if coalesce(p_estimated_quantity, 0) <= 0 then
    raise exception using
      errcode = '22023',
      message = 'Estimated quantity must be greater than zero.';
  end if;

  select row_item.company_id, row_item.import_id
  into v_company_id, v_import_id
  from public.utility_packet_import_rows row_item
  join public.utility_packet_imports packet_import
    on packet_import.id = row_item.import_id
   and packet_import.company_id = row_item.company_id
   and packet_import.status = 'review'
  join public.job_packages package
    on package.id = packet_import.job_package_id
   and package.company_id = packet_import.company_id
   and package.status = 'draft'
  join public.profiles profile
    on profile.id = auth.uid()
   and profile.company_id = row_item.company_id
   and profile.active is true
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where row_item.id = p_row_id
  for update of packet_import, package;

  if v_company_id is null then
    raise exception using
      errcode = 'P0002',
      message = 'Review row was not found or is no longer editable.';
  end if;

  update public.utility_packet_import_rows row_item
  set work_point_code = btrim(p_work_point_code),
      work_type = v_work_type,
      contractor_unit_code = v_contractor_unit_code,
      estimated_quantity = p_estimated_quantity,
      include_in_import = coalesce(p_include_in_import, false),
      review_note = nullif(btrim(coalesce(p_review_note, '')), '')
  where row_item.id = p_row_id
    and row_item.import_id = v_import_id
    and row_item.company_id = v_company_id;

  if not found then
    raise exception using
      errcode = 'P0002',
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
  v_package_status text;
  v_imported_rows integer;
  v_unmatched_count integer;
begin
  if not public.linecrew_can_manage_job_packages() then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to import job packets.';
  end if;

  -- Match the resumable staging lock order even for cached clients that still
  -- call this lower-level finalizer directly: job first, then import/package.
  perform 1
  from public.utility_packet_imports packet_import
  join public.job_packages package
    on package.id = packet_import.job_package_id
   and package.company_id = packet_import.company_id
   and package.status = 'draft'
  join public.jobs job
    on job.id = package.job_id
   and job.company_id = package.company_id
   and job.active is true
  join public.profiles profile
    on profile.id = auth.uid()
   and profile.company_id = packet_import.company_id
   and profile.active is true
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where packet_import.id = p_import_id
    and packet_import.status = 'review'
  for update of job;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Packet review was not found, is not editable, or was already finalized.';
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
   and package.status = 'draft'
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

  with matches as materialized (
    select *
    from public.linecrew_utility_packet_import_matches(p_import_id)
  ), included as materialized (
    select row_item.*,
      matches.price_book_item_id matched_price_book_item_id,
      matches.canonical_unit_code matched_unit_code
    from public.utility_packet_import_rows row_item
    left join matches
      on matches.row_id = row_item.id
    where row_item.import_id = p_import_id
      and row_item.include_in_import
      and row_item.contractor_unit_code is not null
  ), match_summary as materialized (
    select count(*) filter (
      where included.matched_price_book_item_id is null
    )::integer unmatched_count
    from included
  ), grouped as materialized (
    select min(btrim(included.work_point_code)) work_point_code,
      max(included.work_point_description) work_point_description,
      included.matched_price_book_item_id price_book_item_id,
      included.matched_unit_code canonical_unit_code,
      sum(
        case when lower(included.work_type) = 'install'
          then included.estimated_quantity else 0 end
      ) install_quantity,
      sum(
        case when lower(included.work_type) = 'transfer'
          then included.estimated_quantity else 0 end
      ) transfer_quantity,
      sum(
        case when lower(included.work_type) = 'remove'
          then included.estimated_quantity else 0 end
      ) retirement_quantity
    from included
    where included.matched_price_book_item_id is not null
    group by
      public.normalize_work_point_key(included.work_point_code),
      included.matched_price_book_item_id,
      included.matched_unit_code
  ), aggregated as materialized (
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
    ) rows
    from grouped
  )
  select match_summary.unmatched_count,
    aggregated.rows
  into v_unmatched_count,
    v_rows
  from match_summary
  cross join aggregated;

  if coalesce(v_unmatched_count, 0) > 0 then
    raise exception using
      errcode = 'P0002',
      message = 'One or more Contractor Units were not found in the selected job Price Book. Correct the unmatched rows before importing.';
  end if;

  if v_rows is null or jsonb_array_length(v_rows) = 0 then
    raise exception using
      errcode = '22023',
      message = 'No reviewed Contractor Unit rows are selected for import.';
  end if;

  -- Preserve the original canonical work-point behavior without relying on
  -- the table's older lower(trim()) key. A jacket may spell the same location
  -- as "Pole 0020", "WP-20" or "20".
  with packet_rows as materialized (
    select public.normalize_work_point_key(value->>'work_point_code') point_key,
      min(btrim(value->>'work_point_code')) work_point_code,
      max(nullif(btrim(coalesce(value->>'work_point_description', '')), ''))
        work_point_description
    from jsonb_array_elements(v_rows)
    group by public.normalize_work_point_key(value->>'work_point_code')
  )
  insert into public.job_package_work_points (
    company_id, job_package_id, job_id, work_point_code, description,
    created_by
  )
  select v_company_id,
    v_package_id,
    v_job_id,
    packet_row.work_point_code,
    packet_row.work_point_description,
    auth.uid()
  from packet_rows packet_row
  on conflict (
    job_package_id,
    (public.normalize_work_point_key(work_point_code))
  ) do update
  set description = coalesce(
        public.job_package_work_points.description,
        excluded.description
      ),
      updated_at = now();

  with packet_rows as materialized (
    select value,
      public.normalize_work_point_key(value->>'work_point_code') point_key
    from jsonb_array_elements(v_rows)
  )
  insert into public.job_package_authorized_units (
    company_id, job_package_id, work_point_id, price_book_item_id, unit_code,
    authorized_install_quantity, authorized_transfer_quantity,
    authorized_retirement_quantity, created_by
  )
  select v_company_id,
    v_package_id,
    work_point.id,
    (packet_row.value->>'price_book_item_id')::uuid,
    packet_row.value->>'unit_code',
    (packet_row.value->>'install_quantity')::numeric,
    (packet_row.value->>'transfer_quantity')::numeric,
    (packet_row.value->>'retirement_quantity')::numeric,
    auth.uid()
  from packet_rows packet_row
  join public.job_package_work_points work_point
    on work_point.company_id = v_company_id
   and work_point.job_package_id = v_package_id
   and public.normalize_work_point_key(work_point.work_point_code) =
       packet_row.point_key
  on conflict (work_point_id, price_book_item_id) do update
  set authorized_install_quantity = excluded.authorized_install_quantity,
      authorized_transfer_quantity = excluded.authorized_transfer_quantity,
      authorized_retirement_quantity =
        excluded.authorized_retirement_quantity,
      unit_code = excluded.unit_code,
      updated_at = now();

  get diagnostics v_imported_rows = row_count;

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
    'imported_rows', v_imported_rows,
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
    'consolidated_rows', v_imported_rows,
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

-- The browser submits the complete edited review and finalizes it through one
-- RPC transaction. The parent import/package locks acquired by the bulk save
-- remain held until finalization commits, eliminating the save/finalize gap.
create or replace function public.finalize_utility_packet_import_review(
  p_import_id uuid,
  p_rows jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_saved jsonb;
  v_finalized jsonb;
begin
  if not public.linecrew_can_manage_job_packages() then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to import job packets.';
  end if;

  -- Use the same job -> import/package lock order as resumable staging. This
  -- prevents a same-file retry from deadlocking a confirmation in progress.
  perform 1
  from public.utility_packet_imports packet_import
  join public.job_packages package
    on package.id = packet_import.job_package_id
   and package.company_id = packet_import.company_id
   and package.status = 'draft'
  join public.jobs job
    on job.id = package.job_id
   and job.company_id = package.company_id
   and job.active is true
  join public.profiles profile
    on profile.id = auth.uid()
   and profile.company_id = packet_import.company_id
   and profile.active is true
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where packet_import.id = p_import_id
    and packet_import.status = 'review'
  for update of job;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Packet review was not found or is no longer editable.';
  end if;

  v_saved := public.update_utility_packet_import_rows_bulk(
    p_import_id,
    p_rows
  );
  v_finalized := public.finalize_utility_packet_import(p_import_id);

  return coalesce(v_finalized, '{}'::jsonb) || jsonb_build_object(
    'updated_rows', coalesce((v_saved->>'updated_rows')::integer, 0)
  );
end;
$$;

revoke all on function public.finalize_utility_packet_import_review(
  uuid, jsonb
) from public, anon;
grant execute on function public.finalize_utility_packet_import_review(
  uuid, jsonb
) to authenticated;

commit;
