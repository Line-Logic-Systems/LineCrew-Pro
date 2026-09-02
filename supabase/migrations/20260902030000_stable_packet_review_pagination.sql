-- Give the packet review a deterministic total order so it can be paged.
--
-- get_utility_packet_import_review returns every staged row for an import.
-- PostgREST caps a response at its max-rows setting, and the browser asked for
-- the whole set in one request, so a packet larger than that cap was silently
-- truncated: a 1203-row import rendered 1000 rows, and the 203 the reviewer
-- never saw were still imported by finalize_utility_packet_import, which reads
-- the table rather than the rows the browser sent. On a workflow whose entire
-- purpose is mandatory human review, that is a hole.
--
-- The client now pages through the rows. Paging is only correct over a total
-- order: the previous "order by source_page nulls last, source_row" leaves ties
-- whenever two rows share a page and row number, and Postgres may order tied
-- rows differently between requests, which would duplicate some rows across
-- page boundaries and drop others entirely.
--
-- Adding the primary key as the final sort key makes the order total, so every
-- row appears in exactly one page. The visible ordering is unchanged for rows
-- that were already distinct.
--
-- Nothing else about the function changes: same signature, same columns, same
-- permission checks, same live Price Book matching.

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
set search_path to ''
as $function$
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
  order by row_item.source_page nulls last,
    row_item.source_row,
    row_item.id;
$function$;

revoke all on function public.get_utility_packet_import_review(uuid)
  from public, anon;
grant execute on function public.get_utility_packet_import_review(uuid)
  to authenticated;

comment on function public.get_utility_packet_import_review(uuid) is
  'Returns every staged packet row with live Price Book matching, in a total order (source page, source row, id) so the reviewer can page through the full set without duplicating or skipping rows.';

notify pgrst, 'reload schema';
