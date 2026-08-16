begin;

alter table public.profiles
  add column if not exists active boolean not null default true;

update public.profiles
set active = true
where active is null;

-- Used by restrictive RLS policies. SECURITY DEFINER avoids recursive policy
-- evaluation when the protected table is public.profiles itself.
create or replace function public.current_user_has_active_profile()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.profiles
    where id = auth.uid()
      and active is true
  );
$$;

revoke all on function public.current_user_has_active_profile() from public;
revoke all on function public.current_user_has_active_profile() from anon;
grant execute on function public.current_user_has_active_profile()
to authenticated;

-- The app uses this before loading the profile so a suspended user receives a
-- clear message instead of being mistaken for an account with no company.
create or replace function public.is_my_profile_suspended()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.profiles
    where id = auth.uid()
      and active is false
  );
$$;

revoke all on function public.is_my_profile_suspended() from public;
revoke all on function public.is_my_profile_suspended() from anon;
grant execute on function public.is_my_profile_suspended()
to authenticated;

-- Re-secure the current Team role RPC so suspended Admins cannot call it
-- directly. This preserves the company and last-Admin protections introduced
-- by the foreman-first migration.
create or replace function public.set_company_member_role(
  p_member_id uuid,
  p_role text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_caller_company_id uuid;
  v_caller_role text;
  v_caller_active boolean;
  v_target_role text;
  v_next_role text;
  v_admin_count integer;
begin
  v_next_role := lower(btrim(coalesce(p_role, '')));

  if p_member_id is null or
     v_next_role not in ('foreman', 'gf', 'admin') then
    raise exception using
      errcode = '22023',
      message = 'Choose Foreman, General Foreman, or Admin.';
  end if;

  select company_id, lower(coalesce(role, '')), active
  into v_caller_company_id, v_caller_role, v_caller_active
  from public.profiles
  where id = auth.uid();

  if v_caller_company_id is null or
     v_caller_role <> 'admin' or
     v_caller_active is not true then
    raise exception using
      errcode = '42501',
      message = 'Only an active company Admin can change team roles.';
  end if;

  select lower(coalesce(role, ''))
  into v_target_role
  from public.profiles
  where id = p_member_id
    and company_id = v_caller_company_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Team member was not found in your company.';
  end if;

  if v_target_role = 'admin' and v_next_role <> 'admin' then
    select count(*)
    into v_admin_count
    from public.profiles
    where company_id = v_caller_company_id
      and lower(coalesce(role, '')) = 'admin'
      and active is true;

    if v_admin_count <= 1 then
      raise exception using
        errcode = '23514',
        message = 'Assign another Admin before changing the last Admin role.';
    end if;
  end if;

  update public.profiles
  set role = v_next_role
  where id = p_member_id
    and company_id = v_caller_company_id;
end;
$$;

revoke all on function public.set_company_member_role(uuid, text)
from public;
revoke all on function public.set_company_member_role(uuid, text)
from anon;
grant execute on function public.set_company_member_role(uuid, text)
to authenticated;

-- Re-secure Price Book activation because SECURITY DEFINER functions bypass
-- table RLS. Suspended Admins must not be able to change pricing state.
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
  v_profile_active boolean;
  v_target public.price_books%rowtype;
begin
  if p_price_book_id is null or p_active is null then
    raise exception using
      errcode = '22004',
      message = 'Price Book ID and active status are required.';
  end if;

  select company_id, role, active
  into v_company_id, v_role, v_profile_active
  from public.profiles
  where id = auth.uid();

  if v_company_id is null or
     lower(coalesce(v_role, '')) <> 'admin' or
     v_profile_active is not true then
    raise exception using
      errcode = '42501',
      message = 'Only an active company Admin can change Price Book status.';
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
    set active = false, updated_at = now()
    where company_id = v_company_id
      and id <> v_target.id
      and contract_id is not distinct from v_target.contract_id
      and coalesce(lower(btrim(name)), '') =
        coalesce(lower(btrim(v_target.name)), '')
      and active is true;
  end if;

  update public.price_books
  set active = p_active, updated_at = now()
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

-- Add a restrictive access gate to every current company-data table. Existing
-- tenant policies must still pass; this adds the requirement that the caller's
-- profile is active. SECURITY DEFINER management RPCs remain available to the
-- active company Admin for restoring a suspended member.
do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'companies',
    'profiles',
    'customers',
    'contracts',
    'price_books',
    'price_book_items',
    'jobs',
    'daily_reports'
  ]
  loop
    if to_regclass('public.' || v_table) is not null then
      execute format(
        'alter table public.%I enable row level security',
        v_table
      );

      execute format(
        'drop policy if exists active_profile_required on public.%I',
        v_table
      );

      execute format(
        'create policy active_profile_required on public.%I as restrictive for all to authenticated using ((select public.current_user_has_active_profile())) with check ((select public.current_user_has_active_profile()))',
        v_table
      );
    end if;
  end loop;
end;
$$;

create or replace function public.set_company_member_active(
  p_member_id uuid,
  p_active boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_caller_company_id uuid;
  v_caller_role text;
  v_caller_active boolean;
  v_target_role text;
  v_active_admin_count integer;
begin
  if p_member_id is null or p_active is null then
    raise exception using
      errcode = '22004',
      message = 'Team member and access status are required.';
  end if;

  select company_id, lower(coalesce(role, '')), active
  into v_caller_company_id, v_caller_role, v_caller_active
  from public.profiles
  where id = auth.uid();

  if v_caller_company_id is null or
     v_caller_role <> 'admin' or
     v_caller_active is not true then
    raise exception using
      errcode = '42501',
      message = 'Only an active company Admin can change team access.';
  end if;

  if p_member_id = auth.uid() then
    raise exception using
      errcode = '42501',
      message = 'Admins cannot suspend their own account.';
  end if;

  select lower(coalesce(role, ''))
  into v_target_role
  from public.profiles
  where id = p_member_id
    and company_id = v_caller_company_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Team member was not found in your company.';
  end if;

  if p_active is false and v_target_role = 'admin' then
    select count(*)
    into v_active_admin_count
    from public.profiles
    where company_id = v_caller_company_id
      and lower(coalesce(role, '')) = 'admin'
      and active is true;

    if v_active_admin_count <= 1 then
      raise exception using
        errcode = '23514',
        message = 'The last active company Admin cannot be suspended.';
    end if;
  end if;

  update public.profiles
  set active = p_active
  where id = p_member_id
    and company_id = v_caller_company_id;
end;
$$;

revoke all on function public.set_company_member_active(uuid, boolean)
from public;
revoke all on function public.set_company_member_active(uuid, boolean)
from anon;
grant execute on function public.set_company_member_active(uuid, boolean)
to authenticated;

commit;
