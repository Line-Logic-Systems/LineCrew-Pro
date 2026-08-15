begin;

-- Stop instead of guessing if old data already contains two active versions
-- in the same company/contract/name family. Resolve those rows manually, then
-- run this migration again.
do $$
begin
  if exists (
    select 1
    from public.price_books
    where active is true
    group by
      company_id,
      coalesce(
        contract_id,
        '00000000-0000-0000-0000-000000000000'::uuid
      ),
      coalesce(lower(btrim(name)), '')
    having count(*) > 1
  ) then
    raise exception
      'Multiple active Price Book versions already exist in one or more version families. Deactivate the older duplicate before rerunning this migration.';
  end if;
end;
$$;

-- Database-level protection against concurrent requests creating two active
-- versions. company_id is the first key so separate contractors never affect
-- one another.
create unique index if not exists
  price_books_one_active_version_per_family
on public.price_books (
  company_id,
  coalesce(
    contract_id,
    '00000000-0000-0000-0000-000000000000'::uuid
  ),
  coalesce(lower(btrim(name)), '')
)
where active is true;

create or replace function public.set_price_book_active(
  p_price_book_id uuid,
  p_active boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_target public.price_books%rowtype;
begin
  if p_price_book_id is null or p_active is null then
    raise exception using
      errcode = '22004',
      message = 'Price Book ID and active status are required.';
  end if;

  select company_id, role
  into v_company_id, v_role
  from public.profiles
  where id = auth.uid();

  if v_company_id is null then
    raise exception using
      errcode = '42501',
      message = 'A company profile is required.';
  end if;

  if lower(coalesce(v_role, '')) <> 'admin' then
    raise exception using
      errcode = '42501',
      message = 'Only a company admin can change Price Book status.';
  end if;

  select *
  into v_target
  from public.price_books
  where id = p_price_book_id
    and company_id = v_company_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Price Book not found for the current company.';
  end if;

  if p_active then
    update public.price_books
    set
      active = false,
      updated_at = now()
    where company_id = v_company_id
      and id <> v_target.id
      and contract_id is not distinct from v_target.contract_id
      and coalesce(lower(btrim(name)), '') =
        coalesce(lower(btrim(v_target.name)), '')
      and active is true;
  end if;

  update public.price_books
  set
    active = p_active,
    updated_at = now()
  where id = v_target.id
    and company_id = v_company_id;
end;
$$;

revoke all on function public.set_price_book_active(uuid, boolean)
from public;

revoke all on function public.set_price_book_active(uuid, boolean)
from anon;

grant execute on function public.set_price_book_active(uuid, boolean)
to authenticated;

commit;
