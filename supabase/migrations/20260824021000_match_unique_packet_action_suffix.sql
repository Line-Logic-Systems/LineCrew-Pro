begin;

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
    select packet_import.id import_id, packet_import.company_id,
      package.contract_id, job.price_book_id,
      regexp_replace(upper(btrim(p_contractor_unit_code)), '[^A-Z0-9]', '', 'g') base_code,
      case lower(btrim(coalesce(p_work_type, '')))
        when 'install' then 'I'
        when 'remove' then 'R'
        else ''
      end work_suffix
    from public.utility_packet_imports packet_import
    join public.job_packages package
      on package.id = packet_import.job_package_id
     and package.company_id = packet_import.company_id
    join public.jobs job
      on job.id = package.job_id and job.company_id = packet_import.company_id
    where packet_import.id = p_import_id
      and nullif(btrim(coalesce(p_contractor_unit_code, '')), '') is not null
  ), candidates as (
    select item.id, item.item_code, book.effective_start, book.updated_at book_updated_at,
      item.updated_at item_updated_at,
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
        when candidate.normalized_item_code = candidate.base_code || candidate.work_suffix then 1
        when length(candidate.normalized_item_code) = length(candidate.base_code) + 1
         and left(candidate.normalized_item_code, length(candidate.base_code)) = candidate.base_code
         and 1 = (
           select count(distinct alternate.normalized_item_code)
           from candidates alternate
           where length(alternate.normalized_item_code) = length(candidate.base_code) + 1
             and left(alternate.normalized_item_code, length(candidate.base_code)) = candidate.base_code
         ) then 2
        else 99
      end match_rank
    from candidates candidate
  )
  select eligible.id
  from eligible
  where eligible.match_rank < 99
  order by eligible.match_rank,
    eligible.effective_start desc nulls last,
    eligible.book_updated_at desc nulls last,
    eligible.item_updated_at desc nulls last
  limit 1;
$$;

revoke all on function public.resolve_utility_packet_price_item(uuid,text,text) from public, anon;
grant execute on function public.resolve_utility_packet_price_item(uuid,text,text) to authenticated;

commit;
