-- Price Book unit items for LineCrew Pro
-- Review this migration against the live Supabase schema before applying it.

create extension if not exists pgcrypto;

create table if not exists public.price_book_items (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete restrict,
  price_book_id uuid not null references public.price_books(id) on delete restrict,
  unit_code text not null,
  unit_description text not null,
  category text,
  unit_type text,
  unit_of_measure text,
  install_price numeric(14,2) not null default 0
    check (install_price >= 0),
  retirement_price numeric(14,2) not null default 0
    check (retirement_price >= 0),
  active boolean not null default true,
  sort_order integer not null default 0,
  created_by uuid not null default auth.uid()
    references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint price_book_items_unit_code_not_blank
    check (length(trim(unit_code)) > 0),
  constraint price_book_items_description_not_blank
    check (length(trim(unit_description)) > 0),
  constraint price_book_items_book_unit_unique
    unique (price_book_id, unit_code)
);

create index if not exists price_book_items_company_idx
  on public.price_book_items(company_id);

create index if not exists price_book_items_price_book_idx
  on public.price_book_items(price_book_id);

create index if not exists price_book_items_search_idx
  on public.price_book_items(
    company_id,
    price_book_id,
    active,
    category,
    unit_code
  );

create or replace function public.enforce_price_book_item_company()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  parent_company_id uuid;
begin
  select company_id
    into parent_company_id
    from public.price_books
   where id = new.price_book_id;

  if parent_company_id is null then
    raise exception 'Price Book does not exist.';
  end if;

  if new.company_id is null then
    new.company_id := parent_company_id;
  end if;

  if new.company_id <> parent_company_id then
    raise exception 'Price Book item company must match its Price Book.';
  end if;

  return new;
end;
$$;

drop trigger if exists enforce_price_book_item_company
  on public.price_book_items;

create trigger enforce_price_book_item_company
before insert or update of company_id, price_book_id
on public.price_book_items
for each row
execute function public.enforce_price_book_item_company();

create or replace function public.set_price_book_item_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists set_price_book_item_updated_at
  on public.price_book_items;

create trigger set_price_book_item_updated_at
before update
on public.price_book_items
for each row
execute function public.set_price_book_item_updated_at();

alter table public.price_book_items enable row level security;

drop policy if exists price_book_items_select_company
  on public.price_book_items;

create policy price_book_items_select_company
on public.price_book_items
for select
to authenticated
using (
  exists (
    select 1
      from public.profiles
     where profiles.id = auth.uid()
       and profiles.company_id = price_book_items.company_id
  )
);

drop policy if exists price_book_items_insert_manager
  on public.price_book_items;

create policy price_book_items_insert_manager
on public.price_book_items
for insert
to authenticated
with check (
  created_by = auth.uid()
  and exists (
    select 1
      from public.profiles
     where profiles.id = auth.uid()
       and profiles.company_id = price_book_items.company_id
       and lower(profiles.role) in ('admin', 'gf')
  )
  and exists (
    select 1
      from public.price_books
     where price_books.id = price_book_items.price_book_id
       and price_books.company_id = price_book_items.company_id
  )
);

drop policy if exists price_book_items_update_manager
  on public.price_book_items;

create policy price_book_items_update_manager
on public.price_book_items
for update
to authenticated
using (
  exists (
    select 1
      from public.profiles
     where profiles.id = auth.uid()
       and profiles.company_id = price_book_items.company_id
       and lower(profiles.role) in ('admin', 'gf')
  )
)
with check (
  exists (
    select 1
      from public.profiles
     where profiles.id = auth.uid()
       and profiles.company_id = price_book_items.company_id
       and lower(profiles.role) in ('admin', 'gf')
  )
  and exists (
    select 1
      from public.price_books
     where price_books.id = price_book_items.price_book_id
       and price_books.company_id = price_book_items.company_id
  )
);

drop policy if exists price_book_items_delete_manager
  on public.price_book_items;

create policy price_book_items_delete_manager
on public.price_book_items
for delete
to authenticated
using (
  exists (
    select 1
      from public.profiles
     where profiles.id = auth.uid()
       and profiles.company_id = price_book_items.company_id
       and lower(profiles.role) in ('admin', 'gf')
  )
);

grant select, insert, update, delete
  on public.price_book_items
  to authenticated;

comment on table public.price_book_items is
  'Version-specific utility unit pricing. Each row belongs to one company and one Price Book version.';

comment on column public.price_book_items.retirement_price is
  'Price paid for retirement or removal of the unit.';
