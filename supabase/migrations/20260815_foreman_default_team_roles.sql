begin;

-- The base LineCrew Pro product currently supports field leaders only.
-- Convert any profiles created under the earlier Employee default before
-- enforcing the supported role list.
update public.profiles
set role = 'foreman'
where lower(coalesce(role, '')) = 'employee';

alter table public.profiles
  drop constraint if exists profiles_role_supported;

alter table public.profiles
  add constraint profiles_role_supported
  check (lower(role) in ('foreman', 'gf', 'admin'));

-- A person joining with a contractor's company code always starts as a
-- Foreman. Only a company Admin may promote that person afterward.
create or replace function public.join_company(
  company_code text,
  user_name text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
begin
  if auth.uid() is null then
    raise exception using
      errcode = '42501',
      message = 'Sign in before joining a company.';
  end if;

  if nullif(btrim(company_code), '') is null or
     nullif(btrim(user_name), '') is null then
    raise exception using
      errcode = '22004',
      message = 'Company code and name are required.';
  end if;

  if exists (
    select 1
    from public.profiles
    where id = auth.uid()
  ) then
    raise exception using
      errcode = '23505',
      message = 'This account already belongs to a company.';
  end if;

  select id
  into v_company_id
  from public.companies
  where upper(btrim(join_code)) = upper(btrim(company_code))
  limit 1;

  if v_company_id is null then
    raise exception using
      errcode = 'P0002',
      message = 'Company code was not found.';
  end if;

  insert into public.profiles (
    id,
    company_id,
    full_name,
    role
  ) values (
    auth.uid(),
    v_company_id,
    btrim(user_name),
    'foreman'
  );
end;
$$;

revoke all on function public.join_company(text, text) from public;
revoke all on function public.join_company(text, text) from anon;
grant execute on function public.join_company(text, text) to authenticated;

-- Role changes are enforced in the database so a manipulated browser cannot
-- edit another contractor's team or remove the final company Admin.
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

  select company_id, lower(coalesce(role, ''))
  into v_caller_company_id, v_caller_role
  from public.profiles
  where id = auth.uid();

  if v_caller_company_id is null or v_caller_role <> 'admin' then
    raise exception using
      errcode = '42501',
      message = 'Only a company Admin can change team roles.';
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
      and lower(coalesce(role, '')) = 'admin';

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

revoke all on function public.set_company_member_role(uuid, text) from public;
revoke all on function public.set_company_member_role(uuid, text) from anon;
grant execute on function public.set_company_member_role(uuid, text)
to authenticated;

commit;
