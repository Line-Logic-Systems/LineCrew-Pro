-- Let an Admin map a utility's packet code to a contract Price Book unit.
--
-- A utility writes units in its own vocabulary. United calls #4 ACSR "C4 7/1",
-- copper "C6A" and "C8A", and a 5 kVA transformer "DTran5Kva". None of those
-- are Price Book codes, so every one of them lands on the review screen as
-- "Needs Price Book match" and blocks the import.
--
-- Until now there were two ways out, both bad. Editing the box inline works but
-- overwrites what the utility actually authorized, so the audit trail stops
-- matching the packet, and it has to be redone on every future job. Adding the
-- code to the Price Book means an export, a spreadsheet edit, a re-import as a
-- new version and deactivating the old one -- and it fills the contract's Price
-- Book with codes that are not contract units at all.
--
-- A mapping is the missing piece: the packet keeps its own code, the Price Book
-- keeps only real contract units, and the join between them is a separate,
-- visible, auditable record scoped to one contract. United's vocabulary never
-- touches an Oncor book.
--
-- The alias stores the TARGET CODE rather than a price_book_items row id on
-- purpose. Price Books are versioned -- a revised book is a new row with new
-- item ids -- so an id would silently break the first time a contract's pricing
-- was revised. Resolving by code against whichever book is active survives that.

create table if not exists public.utility_packet_unit_aliases (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  contract_id uuid not null references public.contracts(id) on delete cascade,
  -- What the packet displays, kept verbatim so the screen can show the
  -- reviewer the code they actually saw.
  packet_code text not null,
  -- The match key, built exactly like linecrew_utility_packet_import_matches
  -- builds it, so punctuation and case never decide whether a mapping applies.
  normalized_code text not null,
  -- The Price Book item this means, by code rather than by id.
  target_item_code text not null,
  normalized_target text not null,
  created_by uuid references auth.users(id) on delete set null,
  updated_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint utility_packet_unit_aliases_packet_code_check
    check (btrim(packet_code) <> ''),
  constraint utility_packet_unit_aliases_target_code_check
    check (btrim(target_item_code) <> ''),
  constraint utility_packet_unit_aliases_normalized_check
    check (normalized_code ~ '^[A-Z0-9]+$' and normalized_target ~ '^[A-Z0-9]+$'),
  -- A packet code cannot mean two different units on the same contract.
  constraint utility_packet_unit_aliases_unique
    unique (company_id, contract_id, normalized_code)
);

alter table public.utility_packet_unit_aliases enable row level security;
revoke all on public.utility_packet_unit_aliases from public, anon, authenticated;

create index if not exists utility_packet_unit_aliases_lookup
  on public.utility_packet_unit_aliases (company_id, contract_id, normalized_code);

comment on table public.utility_packet_unit_aliases is
  'Maps a utility packet''s own unit code to a contract Price Book unit code. Scoped to one contract so each utility keeps its own vocabulary. Resolved by code, not id, so a Price Book revision does not break existing mappings.';

-- Resolving a mapping is a pricing decision, so it is Owner/Admin only. That is
-- deliberately narrower than linecrew_can_manage_job_packages(), which also
-- admits a GF and a capability-enabled Superintendent: importing a packet the
-- Price Book already priced is a different act from deciding what a code is
-- worth.
create or replace function public.linecrew_can_manage_packet_unit_aliases()
returns boolean
language sql
stable
security definer
set search_path to ''
as $function$
  select exists (
    select 1
    from public.profiles profile
    join public.companies company
      on company.id = profile.company_id
     and company.active is true
    where profile.id = auth.uid()
      and profile.active is true
      and lower(coalesce(profile.role, '')) in ('owner', 'admin')
  );
$function$;

revoke all on function public.linecrew_can_manage_packet_unit_aliases()
  from public, anon;
grant execute on function public.linecrew_can_manage_packet_unit_aliases()
  to authenticated;

-- The Price Book units an Admin can choose from when mapping a packet code.
-- Scoped to the book the import's own job actually resolves to, so the list can
-- never offer a unit from another contract.
create or replace function public.linecrew_price_book_units_for_import(
  p_import_id uuid
)
returns table (
  item_code text,
  item_name text,
  description text,
  install_price numeric,
  transfer_price numeric,
  retirement_price numeric
)
language sql
stable
security definer
set search_path to ''
as $function$
  select item.item_code,
    item.item_name,
    item.description,
    item.install_price,
    item.transfer_price,
    item.retirement_price
  from public.utility_packet_imports packet_import
  join public.job_packages package
    on package.id = packet_import.job_package_id
   and package.company_id = packet_import.company_id
  join public.profiles profile
    on profile.id = auth.uid()
   and profile.company_id = packet_import.company_id
   and profile.active is true
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  join public.price_book_items item
    on item.price_book_id = public.linecrew_resolve_job_price_book(
         packet_import.company_id, package.job_id, package.contract_id
       )
   and item.company_id = packet_import.company_id
   and item.active is true
  where packet_import.id = p_import_id
    and public.linecrew_can_manage_job_packages()
  order by item.item_code;
$function$;

revoke all on function public.linecrew_price_book_units_for_import(uuid)
  from public, anon;
grant execute on function public.linecrew_price_book_units_for_import(uuid)
  to authenticated;

-- Existing mappings for the contract behind an import, so the review screen can
-- show what is already mapped rather than only what is broken.
create or replace function public.linecrew_packet_unit_aliases_for_import(
  p_import_id uuid
)
returns table (
  packet_code text,
  normalized_code text,
  target_item_code text,
  target_exists boolean,
  updated_at timestamptz
)
language sql
stable
security definer
set search_path to ''
as $function$
  select alias.packet_code,
    alias.normalized_code,
    alias.target_item_code,
    exists (
      select 1
      from public.price_book_items item
      where item.price_book_id = public.linecrew_resolve_job_price_book(
              packet_import.company_id, package.job_id, package.contract_id
            )
        and item.company_id = packet_import.company_id
        and item.active is true
        and regexp_replace(upper(btrim(item.item_code)), '[^A-Z0-9]', '', 'g')
            = alias.normalized_target
    ),
    alias.updated_at
  from public.utility_packet_imports packet_import
  join public.job_packages package
    on package.id = packet_import.job_package_id
   and package.company_id = packet_import.company_id
  join public.profiles profile
    on profile.id = auth.uid()
   and profile.company_id = packet_import.company_id
   and profile.active is true
  join public.utility_packet_unit_aliases alias
    on alias.company_id = packet_import.company_id
   and alias.contract_id = package.contract_id
  where packet_import.id = p_import_id
    and public.linecrew_can_manage_job_packages()
  order by alias.packet_code;
$function$;

revoke all on function public.linecrew_packet_unit_aliases_for_import(uuid)
  from public, anon;
grant execute on function public.linecrew_packet_unit_aliases_for_import(uuid)
  to authenticated;

-- Create or change one mapping. Passing a blank target removes it, so the same
-- call both maps and unmaps and the screen needs no second verb.
create or replace function public.linecrew_set_packet_unit_alias(
  p_import_id uuid,
  p_packet_code text,
  p_target_item_code text
)
returns jsonb
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_company_id uuid;
  v_contract_id uuid;
  v_price_book_id uuid;
  v_normalized_code text;
  v_normalized_target text;
  v_resolved_code text;
  v_existing public.utility_packet_unit_aliases%rowtype;
  v_removing boolean;
begin
  if not public.linecrew_can_manage_packet_unit_aliases() then
    raise exception using
      errcode = '42501',
      message = 'Only an Owner or Admin can map a packet unit to the Price Book.';
  end if;

  select packet_import.company_id, package.contract_id
  into v_company_id, v_contract_id
  from public.utility_packet_imports packet_import
  join public.job_packages package
    on package.id = packet_import.job_package_id
   and package.company_id = packet_import.company_id
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
    and packet_import.status = 'review';

  if v_company_id is null then
    raise exception using
      errcode = 'P0002',
      message = 'Packet review was not found or is no longer editable.';
  end if;

  v_normalized_code := regexp_replace(
    upper(btrim(coalesce(p_packet_code, ''))), '[^A-Z0-9]', '', 'g'
  );
  if nullif(v_normalized_code, '') is null then
    raise exception using
      errcode = '22023',
      message = 'A packet unit code is required.';
  end if;

  v_removing := nullif(btrim(coalesce(p_target_item_code, '')), '') is null;
  v_normalized_target := regexp_replace(
    upper(btrim(coalesce(p_target_item_code, ''))), '[^A-Z0-9]', '', 'g'
  );

  select alias.* into v_existing
  from public.utility_packet_unit_aliases alias
  where alias.company_id = v_company_id
    and alias.contract_id = v_contract_id
    and alias.normalized_code = v_normalized_code
  for update;

  if v_removing then
    if v_existing.id is null then
      return jsonb_build_object('mapped', false, 'removed', false);
    end if;
    delete from public.utility_packet_unit_aliases alias
    where alias.id = v_existing.id;

    insert into public.audit_log (
      company_id, user_id, action, table_name, record_id, old_data, new_data
    ) values (
      v_company_id, auth.uid(), 'packet_unit_alias_removed',
      'utility_packet_unit_aliases', v_existing.id,
      jsonb_build_object(
        'packet_code', v_existing.packet_code,
        'target_item_code', v_existing.target_item_code,
        'contract_id', v_contract_id
      ),
      null
    );
    return jsonb_build_object('mapped', false, 'removed', true);
  end if;

  if nullif(v_normalized_target, '') is null then
    raise exception using
      errcode = '22023',
      message = 'The Price Book unit code is not a usable code.';
  end if;

  -- A mapping that points at nothing would fail silently at import time, so the
  -- target is verified against the book this import actually resolves to, and
  -- the stored code is the book's own spelling rather than whatever was typed.
  select package.contract_id,
    public.linecrew_resolve_job_price_book(
      packet_import.company_id, package.job_id, package.contract_id
    )
  into v_contract_id, v_price_book_id
  from public.utility_packet_imports packet_import
  join public.job_packages package
    on package.id = packet_import.job_package_id
   and package.company_id = packet_import.company_id
  where packet_import.id = p_import_id;

  select item.item_code into v_resolved_code
  from public.price_book_items item
  where item.price_book_id = v_price_book_id
    and item.company_id = v_company_id
    and item.active is true
    and regexp_replace(upper(btrim(item.item_code)), '[^A-Z0-9]', '', 'g')
        = v_normalized_target
  order by item.updated_at desc nulls last, item.id desc
  limit 1;

  if v_resolved_code is null then
    raise exception using
      errcode = 'P0002',
      message = 'That unit is not in the Price Book for this job contract.';
  end if;

  -- Mapping a code to itself would be a no-op that hides a real mismatch.
  if v_normalized_code = v_normalized_target then
    raise exception using
      errcode = '22023',
      message = 'A packet unit cannot be mapped to itself.';
  end if;

  insert into public.utility_packet_unit_aliases as alias (
    company_id, contract_id, packet_code, normalized_code,
    target_item_code, normalized_target, created_by, updated_by
  ) values (
    v_company_id, v_contract_id, btrim(p_packet_code), v_normalized_code,
    v_resolved_code, v_normalized_target, auth.uid(), auth.uid()
  )
  on conflict (company_id, contract_id, normalized_code) do update
  set packet_code = excluded.packet_code,
    target_item_code = excluded.target_item_code,
    normalized_target = excluded.normalized_target,
    updated_by = auth.uid(),
    updated_at = now();

  insert into public.audit_log (
    company_id, user_id, action, table_name, record_id, old_data, new_data
  ) values (
    v_company_id, auth.uid(), 'packet_unit_alias_set',
    'utility_packet_unit_aliases',
    (select alias.id from public.utility_packet_unit_aliases alias
      where alias.company_id = v_company_id
        and alias.contract_id = v_contract_id
        and alias.normalized_code = v_normalized_code),
    case when v_existing.id is null then null
      else jsonb_build_object('target_item_code', v_existing.target_item_code) end,
    jsonb_build_object(
      'packet_code', btrim(p_packet_code),
      'target_item_code', v_resolved_code,
      'contract_id', v_contract_id
    )
  );

  return jsonb_build_object(
    'mapped', true,
    'removed', false,
    'packet_code', btrim(p_packet_code),
    'target_item_code', v_resolved_code
  );
end;
$function$;

revoke all on function public.linecrew_set_packet_unit_alias(uuid, text, text)
  from public, anon;
grant execute on function public.linecrew_set_packet_unit_alias(uuid, text, text)
  to authenticated;

comment on function public.linecrew_set_packet_unit_alias(uuid, text, text) is
  'Maps a packet unit code to a Price Book unit for the import''s contract, or removes the mapping when the target is blank. Owner/Admin only; every change is written to audit_log.';

notify pgrst, 'reload schema';

-- Teach the matcher to consult the mappings.
--
-- An Admin mapping replaces the packet's code for matching purposes only. The
-- packet row keeps its own contractor_unit_code, so the review screen and the
-- audit trail still show what the utility actually authorized; only the key
-- used to find a Price Book unit changes. Everything downstream -- the rank
-- order, the single-alternate fallback, the tie-breaks -- is unchanged, and a
-- code with no mapping behaves exactly as it did before.

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
set search_path to ''
as $function$
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
  ), resolved_keys as materialized (
    select source_key.base_code,
      source_key.work_suffix,
      coalesce(alias.normalized_target, source_key.base_code) effective_code
    from source_keys source_key
    cross join context
    left join public.utility_packet_unit_aliases alias
      on alias.company_id = context.company_id
     and alias.contract_id = context.contract_id
     and alias.normalized_code = source_key.base_code
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
    select resolved_key.base_code,
      resolved_key.work_suffix,
      count(distinct candidate.normalized_item_code) alternate_count
    from resolved_keys resolved_key
    join candidates candidate
      on length(candidate.normalized_item_code) =
         length(resolved_key.effective_code) + 1
     and left(
       candidate.normalized_item_code,
       length(resolved_key.effective_code)
     ) = resolved_key.effective_code
    group by resolved_key.base_code, resolved_key.work_suffix
  ), eligible as materialized (
    select resolved_key.base_code,
      resolved_key.work_suffix,
      candidate.id,
      candidate.item_code,
      candidate.updated_at,
      case
        when candidate.normalized_item_code = resolved_key.effective_code then 0
        when candidate.normalized_item_code =
          resolved_key.effective_code || resolved_key.work_suffix then 1
        else 2
      end match_rank
    from resolved_keys resolved_key
    join candidates candidate
      on candidate.normalized_item_code = resolved_key.effective_code
      or candidate.normalized_item_code =
         resolved_key.effective_code || resolved_key.work_suffix
      or (
        length(candidate.normalized_item_code) =
          length(resolved_key.effective_code) + 1
        and left(
          candidate.normalized_item_code,
          length(resolved_key.effective_code)
        ) = resolved_key.effective_code
      )
    left join alternate_counts alternate
      on alternate.base_code = resolved_key.base_code
     and alternate.work_suffix = resolved_key.work_suffix
    where candidate.normalized_item_code = resolved_key.effective_code
       or candidate.normalized_item_code =
          resolved_key.effective_code || resolved_key.work_suffix
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
$function$;

revoke all on function public.linecrew_utility_packet_import_matches(uuid)
  from public, anon, authenticated;

comment on function public.linecrew_utility_packet_import_matches(uuid) is
  'Matches staged packet rows to the job contract Price Book, consulting any Admin-created packet unit mappings for the contract before falling back to the direct and single-alternate code matches.';

notify pgrst, 'reload schema';
