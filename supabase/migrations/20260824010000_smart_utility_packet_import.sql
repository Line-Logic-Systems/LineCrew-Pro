begin;

-- Utility-neutral staging keeps model extraction separate from authorized production.
-- A human must review and finalize every packet before it changes the job baseline.
create table if not exists public.utility_packet_imports (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  job_package_id uuid not null references public.job_packages(id) on delete cascade,
  provider_key text not null,
  format_key text not null,
  profile_version text not null,
  source_filename text not null,
  source_sha256 text not null,
  detected_work_order text null,
  extraction_confidence numeric(5,4) null,
  status text not null default 'review',
  extraction_summary jsonb not null default '{}'::jsonb,
  created_by uuid not null default auth.uid() references auth.users(id) on delete restrict,
  reviewed_by uuid null references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  reviewed_at timestamptz null,
  constraint utility_packet_imports_status_check
    check (status in ('review','imported','cancelled','failed')),
  constraint utility_packet_imports_confidence_check
    check (extraction_confidence is null or extraction_confidence between 0 and 1),
  constraint utility_packet_imports_source_unique
    unique (job_package_id, source_sha256)
);

create table if not exists public.utility_packet_import_rows (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  import_id uuid not null references public.utility_packet_imports(id) on delete cascade,
  source_page integer null,
  source_row integer not null,
  work_point_code text not null,
  work_point_description text null,
  work_type text not null,
  material_cu text null,
  contractor_unit_code text null,
  estimated_quantity numeric(12,2) not null,
  description text null,
  confidence numeric(5,4) null,
  include_in_import boolean not null default true,
  review_note text null,
  created_at timestamptz not null default now(),
  constraint utility_packet_import_rows_type_check
    check (work_type in ('install','remove')),
  constraint utility_packet_import_rows_quantity_check
    check (estimated_quantity > 0),
  constraint utility_packet_import_rows_confidence_check
    check (confidence is null or confidence between 0 and 1),
  constraint utility_packet_import_rows_number_unique
    unique (import_id, source_row)
);

create index if not exists utility_packet_imports_company_package_idx
  on public.utility_packet_imports(company_id, job_package_id, created_at desc);
create index if not exists utility_packet_import_rows_import_idx
  on public.utility_packet_import_rows(import_id, work_point_code, contractor_unit_code);
create index if not exists utility_packet_import_rows_company_idx
  on public.utility_packet_import_rows(company_id, import_id);

alter table public.utility_packet_imports enable row level security;
alter table public.utility_packet_import_rows enable row level security;
revoke all on public.utility_packet_imports from public, anon, authenticated;
revoke all on public.utility_packet_import_rows from public, anon, authenticated;

create or replace function public.linecrew_can_manage_jobs()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and p.active is true
      and (
        lower(coalesce(p.role,'')) in ('owner','admin','gf')
        or (
          lower(coalesce(p.role,'')) = 'superintendent'
          and public.linecrew_has_capability('jobs')
        )
      )
  );
$$;

create or replace function public.linecrew_can_manage_job_packages()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and p.active is true
      and (
        lower(coalesce(p.role,'')) in ('owner','admin','gf')
        or (
          lower(coalesce(p.role,'')) = 'superintendent'
          and public.linecrew_has_capability('job_packages')
        )
      )
  );
$$;

revoke all on function public.linecrew_can_manage_jobs() from public, anon;
revoke all on function public.linecrew_can_manage_job_packages() from public, anon;
grant execute on function public.linecrew_can_manage_jobs() to authenticated;
grant execute on function public.linecrew_can_manage_job_packages() to authenticated;

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
    raise exception using errcode = '42501',
      message = 'Only an active Admin, General Foreman, or authorized Superintendent can add job packets.';
  end if;

  select profile.company_id into v_company_id
  from public.profiles profile where profile.id = auth.uid();

  select job.contract_id into v_contract_id
  from public.jobs job
  join public.contracts contract on contract.id = job.contract_id and contract.company_id = job.company_id
  where job.id = p_job_id and job.company_id = v_company_id and job.active is true;

  if v_contract_id is null then
    raise exception using errcode = 'P0002', message = 'Select an active job tied to a company contract.';
  end if;
  if length(trim(coalesce(p_source_filename,''))) = 0 then
    raise exception using errcode = '22023', message = 'A packet filename is required.';
  end if;

  v_name := regexp_replace(trim(p_source_filename), '\.[^.]+$', '');
  insert into public.job_packages (
    company_id, job_id, contract_id, package_name, package_number,
    source_filename, status, created_by
  ) values (
    v_company_id, p_job_id, v_contract_id, v_name,
    case
      when nullif(trim(coalesce(p_detected_reference,'')), '') is not null
       and not exists (
         select 1 from public.job_packages existing
         where existing.company_id = v_company_id and existing.job_id = p_job_id
           and lower(trim(existing.package_number)) = lower(trim(p_detected_reference))
       )
      then trim(p_detected_reference)
      else null
    end,
    trim(p_source_filename),
    'draft', auth.uid()
  ) returning id into v_package_id;

  return v_package_id;
end;
$$;

revoke all on function public.create_job_package_from_file(uuid,text,text) from public, anon;
grant execute on function public.create_job_package_from_file(uuid,text,text) to authenticated;

create or replace function public.stage_utility_packet_import(
  p_package_id uuid,
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
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_import_id uuid;
  v_row jsonb;
  v_row_number integer := 0;
begin
  if not public.linecrew_can_manage_job_packages() then
    raise exception using errcode = '42501',
      message = 'Only an active Admin, General Foreman, or authorized Superintendent can add job packets.';
  end if;

  select p.company_id into v_company_id
  from public.job_packages p
  where p.id = p_package_id
    and p.company_id = (select profile.company_id from public.profiles profile where profile.id = auth.uid());

  if v_company_id is null then
    raise exception using errcode = 'P0002', message = 'Job packet was not found in your company.';
  end if;
  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 or jsonb_array_length(p_rows) > 4000 then
    raise exception using errcode = '22023', message = 'Packet extraction must contain between 1 and 4,000 source rows.';
  end if;

  insert into public.utility_packet_imports (
    company_id, job_package_id, provider_key, format_key, profile_version,
    source_filename, source_sha256, detected_work_order, extraction_confidence,
    extraction_summary, created_by
  ) values (
    v_company_id, p_package_id, lower(trim(p_provider_key)), trim(p_format_key),
    trim(p_profile_version), trim(p_source_filename), lower(trim(p_source_sha256)),
    nullif(trim(coalesce(p_detected_work_order,'')), ''), p_extraction_confidence,
    coalesce(p_summary, '{}'::jsonb), auth.uid()
  ) returning id into v_import_id;

  for v_row in select value from jsonb_array_elements(p_rows)
  loop
    v_row_number := v_row_number + 1;
    insert into public.utility_packet_import_rows (
      company_id, import_id, source_page, source_row, work_point_code,
      work_point_description, work_type, material_cu, contractor_unit_code,
      estimated_quantity, description, confidence, include_in_import, review_note
    ) values (
      v_company_id, v_import_id, nullif(v_row->>'source_page','')::integer, v_row_number,
      trim(coalesce(v_row->>'work_point_code','')),
      nullif(trim(coalesce(v_row->>'work_point_description','')), ''),
      lower(trim(coalesce(v_row->>'work_type',''))),
      nullif(trim(coalesce(v_row->>'material_cu','')), ''),
      nullif(trim(coalesce(v_row->>'contractor_unit_code','')), ''),
      (v_row->>'estimated_quantity')::numeric,
      nullif(trim(coalesce(v_row->>'description','')), ''),
      nullif(v_row->>'confidence','')::numeric,
      coalesce((v_row->>'include_in_import')::boolean, true),
      nullif(trim(coalesce(v_row->>'review_note','')), '')
    );
  end loop;

  return v_import_id;
exception
  when unique_violation then
    raise exception using errcode = '23505', message = 'This exact file was already staged for this job packet.';
  when invalid_text_representation or check_violation then
    raise exception using errcode = '22023', message = 'The extracted packet contains an invalid page, work type, quantity, or confidence value.';
end;
$$;

revoke all on function public.stage_utility_packet_import(uuid,text,text,text,text,text,text,numeric,jsonb,jsonb)
  from public, anon;
grant execute on function public.stage_utility_packet_import(uuid,text,text,text,text,text,text,numeric,jsonb,jsonb)
  to authenticated;

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
  v_package_id uuid;
  v_import_id uuid;
begin
  if exists (
    select 1
    from public.utility_packet_imports i
    join public.job_packages p on p.id = i.job_package_id and p.company_id = i.company_id
    join public.profiles profile on profile.id = auth.uid() and profile.company_id = i.company_id
    where p.job_id = p_job_id and i.source_sha256 = lower(trim(p_source_sha256))
  ) then
    raise exception using errcode = '23505',
      message = 'This exact packet file is already attached to this job.';
  end if;

  v_package_id := public.create_job_package_from_file(
    p_job_id, p_source_filename, p_detected_work_order
  );
  v_import_id := public.stage_utility_packet_import(
    v_package_id, p_provider_key, p_format_key, p_profile_version,
    p_source_filename, p_source_sha256, p_detected_work_order,
    p_extraction_confidence, p_summary, p_rows
  );
  return jsonb_build_object('package_id', v_package_id, 'import_id', v_import_id);
end;
$$;

revoke all on function public.create_and_stage_utility_packet_import(uuid,text,text,text,text,text,text,numeric,jsonb,jsonb)
  from public, anon;
grant execute on function public.create_and_stage_utility_packet_import(uuid,text,text,text,text,text,text,numeric,jsonb,jsonb)
  to authenticated;

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
    exists (
      select 1
      from public.utility_packet_imports i
      join public.job_packages p on p.id = i.job_package_id and p.company_id = i.company_id
      join public.price_books b on b.contract_id = p.contract_id and b.company_id = i.company_id and b.active is true
      join public.price_book_items item on item.price_book_id = b.id and item.company_id = i.company_id and item.active is true
      where i.id = r.import_id
        and lower(trim(item.item_code)) = lower(trim(r.contractor_unit_code))
    )
  from public.utility_packet_import_rows r
  join public.utility_packet_imports i on i.id = r.import_id and i.company_id = r.company_id
  join public.profiles profile on profile.id = auth.uid() and profile.company_id = i.company_id and profile.active is true
  where r.import_id = p_import_id
  order by r.source_page nulls last, r.source_row;
$$;

revoke all on function public.get_utility_packet_import_review(uuid) from public, anon;
grant execute on function public.get_utility_packet_import_review(uuid) to authenticated;

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
begin
  if not public.linecrew_can_manage_job_packages() then
    raise exception using errcode = '42501', message = 'You do not have permission to review job packets.';
  end if;

  update public.utility_packet_import_rows r
  set work_point_code = trim(p_work_point_code),
      work_type = lower(trim(p_work_type)),
      contractor_unit_code = nullif(trim(coalesce(p_contractor_unit_code,'')), ''),
      estimated_quantity = p_estimated_quantity,
      include_in_import = coalesce(p_include_in_import, false),
      review_note = nullif(trim(coalesce(p_review_note,'')), '')
  from public.utility_packet_imports i, public.profiles profile
  where r.id = p_row_id
    and i.id = r.import_id
    and profile.id = auth.uid()
    and profile.company_id = r.company_id
    and i.company_id = r.company_id
    and i.status = 'review';

  if not found then
    raise exception using errcode = 'P0002', message = 'Review row was not found or is no longer editable.';
  end if;
end;
$$;

revoke all on function public.update_utility_packet_import_row(uuid,text,text,text,numeric,boolean,text)
  from public, anon;
grant execute on function public.update_utility_packet_import_row(uuid,text,text,text,numeric,boolean,text)
  to authenticated;

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
  v_contract_id uuid;
  v_job_id uuid;
  v_rows jsonb;
  v_row jsonb;
  v_work_point_id uuid;
  v_price_book_item_id uuid;
  v_canonical_unit_code text;
  v_result jsonb;
begin
  if not public.linecrew_can_manage_job_packages() then
    raise exception using errcode = '42501', message = 'You do not have permission to import job packets.';
  end if;

  select i.job_package_id, i.source_filename, i.company_id, p.contract_id, p.job_id
  into v_package_id, v_source_filename, v_company_id, v_contract_id, v_job_id
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

  select jsonb_agg(jsonb_build_object(
    'row_number', grouped.first_source_row,
    'work_point_code', grouped.work_point_code,
    'work_point_description', grouped.work_point_description,
    'unit_code', grouped.contractor_unit_code,
    'install_quantity', grouped.install_quantity,
    'retirement_quantity', grouped.retirement_quantity
  ) order by grouped.work_point_code, grouped.contractor_unit_code)
  into v_rows
  from (
    select min(r.source_row) first_source_row,
      min(trim(r.work_point_code)) work_point_code,
      max(r.work_point_description) work_point_description,
      min(trim(r.contractor_unit_code)) contractor_unit_code,
      sum(case when r.work_type = 'install' then r.estimated_quantity else 0 end) install_quantity,
      sum(case when r.work_type = 'remove' then r.estimated_quantity else 0 end) retirement_quantity
    from public.utility_packet_import_rows r
    where r.import_id = p_import_id
      and r.include_in_import
      and r.contractor_unit_code is not null
    group by public.normalize_work_point_key(r.work_point_code),
      lower(trim(r.contractor_unit_code))
  ) grouped;

  if v_rows is null or jsonb_array_length(v_rows) = 0 then
    raise exception using errcode = '22023', message = 'No reviewed Contractor Unit rows are selected for import.';
  end if;

  -- Validate the full consolidated set before writing any authorized units.
  for v_row in select value from jsonb_array_elements(v_rows)
  loop
    if not exists (
      select 1 from public.price_book_items item
      join public.price_books book on book.id = item.price_book_id and book.company_id = item.company_id
      where item.company_id = v_company_id
        and book.contract_id = v_contract_id and book.active is true and item.active is true
        and lower(trim(item.item_code)) = lower(trim(v_row->>'unit_code'))
    ) then
      raise exception using errcode = 'P0002',
        message = 'Contractor Unit ' || (v_row->>'unit_code') ||
          ' was not found in the active Price Book. Correct it in review before importing.';
    end if;
  end loop;

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

    select item.id, item.item_code into v_price_book_item_id, v_canonical_unit_code
    from public.price_book_items item
    join public.price_books book on book.id = item.price_book_id and book.company_id = item.company_id
    where item.company_id = v_company_id
      and book.contract_id = v_contract_id and book.active is true and item.active is true
      and lower(trim(item.item_code)) = lower(trim(v_row->>'unit_code'))
    order by book.effective_start desc nulls last, book.updated_at desc nulls last
    limit 1;

    insert into public.job_package_authorized_units (
      company_id, job_package_id, work_point_id, price_book_item_id, unit_code,
      authorized_install_quantity, authorized_retirement_quantity, created_by
    ) values (
      v_company_id, v_package_id, v_work_point_id, v_price_book_item_id,
      v_canonical_unit_code, (v_row->>'install_quantity')::numeric,
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
