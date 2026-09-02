begin;

create table if not exists public.contract_field_settings (
  contract_id uuid primary key
    references public.contracts(id) on delete cascade,
  company_id uuid not null
    references public.companies(id) on delete cascade,
  field_value_percent numeric(5,2) not null,
  updated_by uuid null references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint contract_field_value_percent_range
    check (field_value_percent >= 0 and field_value_percent <= 100)
);

alter table public.contract_field_settings enable row level security;

-- Settings are intentionally available only through the protected functions
-- below. Foremen must not receive the percentage because it could be used to
-- reverse-calculate confidential contract prices.
revoke all on public.contract_field_settings from public;
revoke all on public.contract_field_settings from anon;
revoke all on public.contract_field_settings from authenticated;

create or replace function public.set_contract_field_value_percent(
  p_contract_id uuid,
  p_field_value_percent numeric
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_profile_active boolean;
begin
  if p_contract_id is null then
    raise exception using
      errcode = '22004',
      message = 'Contract is required.';
  end if;

  if p_field_value_percent is not null and
     (p_field_value_percent < 0 or p_field_value_percent > 100) then
    raise exception using
      errcode = '22023',
      message = 'Field Value must be between 0% and 100%.';
  end if;

  select company_id, lower(coalesce(role, '')), active
  into v_company_id, v_role, v_profile_active
  from public.profiles
  where id = auth.uid();

  if v_company_id is null or
     v_role <> 'admin' or
     v_profile_active is not true then
    raise exception using
      errcode = '42501',
      message = 'Only an active company Admin can change Field Value settings.';
  end if;

  if not exists (
    select 1
    from public.contracts
    where id = p_contract_id
      and company_id = v_company_id
  ) then
    raise exception using
      errcode = 'P0002',
      message = 'Contract was not found in your company.';
  end if;

  if p_field_value_percent is null then
    delete from public.contract_field_settings
    where contract_id = p_contract_id
      and company_id = v_company_id;
  else
    insert into public.contract_field_settings (
      contract_id,
      company_id,
      field_value_percent,
      updated_by,
      updated_at
    ) values (
      p_contract_id,
      v_company_id,
      p_field_value_percent,
      auth.uid(),
      now()
    )
    on conflict (contract_id) do update
    set
      field_value_percent = excluded.field_value_percent,
      updated_by = excluded.updated_by,
      updated_at = now()
    where public.contract_field_settings.company_id = v_company_id;
  end if;
end;
$$;

revoke all on function public.set_contract_field_value_percent(uuid, numeric)
from public;
revoke all on function public.set_contract_field_value_percent(uuid, numeric)
from anon;
grant execute on function public.set_contract_field_value_percent(uuid, numeric)
to authenticated;

create or replace function public.get_contract_field_settings()
returns table (
  contract_id uuid,
  field_value_percent numeric
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_profile_active boolean;
begin
  select p.company_id, lower(coalesce(p.role, '')), p.active
  into v_company_id, v_role, v_profile_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or
     v_role <> 'admin' or
     v_profile_active is not true then
    raise exception using
      errcode = '42501',
      message = 'Only an active company Admin can view Field Value settings.';
  end if;

  return query
  select s.contract_id, s.field_value_percent
  from public.contract_field_settings s
  where s.company_id = v_company_id;
end;
$$;

revoke all on function public.get_contract_field_settings() from public;
revoke all on function public.get_contract_field_settings() from anon;
grant execute on function public.get_contract_field_settings()
to authenticated;

create or replace function public.get_price_book_items_for_user(
  p_price_book_id uuid
)
returns table (
  id uuid,
  company_id uuid,
  price_book_id uuid,
  item_code text,
  item_name text,
  description text,
  install_price numeric,
  retirement_price numeric,
  unit_of_measure text,
  category text,
  extra_data jsonb,
  active boolean,
  created_at timestamptz,
  updated_at timestamptz,
  actual_install_price numeric,
  actual_retirement_price numeric,
  adjusted_install_price numeric,
  adjusted_retirement_price numeric,
  has_adjustment boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_profile_active boolean;
  v_can_see_actual boolean;
begin
  if p_price_book_id is null then
    raise exception using
      errcode = '22004',
      message = 'Price Book is required.';
  end if;

  select p.company_id, lower(coalesce(p.role, '')), p.active
  into v_company_id, v_role, v_profile_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_profile_active is not true then
    raise exception using
      errcode = '42501',
      message = 'An active company profile is required.';
  end if;

  if v_role not in ('foreman', 'gf', 'admin') then
    raise exception using
      errcode = '42501',
      message = 'Your role cannot view contract unit values.';
  end if;

  if not exists (
    select 1
    from public.price_books pb
    where pb.id = p_price_book_id
      and pb.company_id = v_company_id
  ) then
    raise exception using
      errcode = 'P0002',
      message = 'Price Book was not found in your company.';
  end if;

  v_can_see_actual := v_role in ('admin', 'gf');

  return query
  select
    i.id,
    i.company_id,
    i.price_book_id,
    i.item_code,
    i.item_name,
    i.description,
    case
      when v_can_see_actual then i.install_price
      else round(
        i.install_price * coalesce(s.field_value_percent, 100) / 100,
        2
      )
    end,
    case
      when v_can_see_actual then i.retirement_price
      else round(
        i.retirement_price * coalesce(s.field_value_percent, 100) / 100,
        2
      )
    end,
    i.unit_of_measure,
    i.category,
    i.extra_data,
    i.active,
    i.created_at,
    i.updated_at,
    case when v_can_see_actual then i.install_price else null end,
    case when v_can_see_actual then i.retirement_price else null end,
    round(
      i.install_price * coalesce(s.field_value_percent, 100) / 100,
      2
    ),
    round(
      i.retirement_price * coalesce(s.field_value_percent, 100) / 100,
      2
    ),
    s.field_value_percent is not null
  from public.price_book_items i
  join public.price_books pb
    on pb.id = i.price_book_id
   and pb.company_id = i.company_id
  left join public.contract_field_settings s
    on s.contract_id = pb.contract_id
   and s.company_id = i.company_id
  where i.price_book_id = p_price_book_id
    and i.company_id = v_company_id
  order by i.active desc, i.item_code asc;
end;
$$;

revoke all on function public.get_price_book_items_for_user(uuid) from public;
revoke all on function public.get_price_book_items_for_user(uuid) from anon;
grant execute on function public.get_price_book_items_for_user(uuid)
to authenticated;

-- Remove direct access to confidential price columns. Authenticated users may
-- still read unit identity/details needed by existing admin workflows, while
-- all price reads must pass through the role-aware function above.
revoke select on public.price_book_items from authenticated;
revoke select on public.price_book_items from anon;
revoke select on public.price_book_items from public;

grant select (
  id,
  company_id,
  price_book_id,
  item_code,
  item_name,
  description,
  unit_of_measure,
  category,
  extra_data,
  active,
  created_at,
  updated_at
) on public.price_book_items to authenticated;

commit;
