begin;

create or replace function public.rotate_company_join_code()
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_profile_active boolean;
  v_new_code text;
begin
  select company_id, lower(coalesce(role, '')), active
  into v_company_id, v_role, v_profile_active
  from public.profiles
  where id = auth.uid();

  if v_company_id is null or
     v_role <> 'admin' or
     v_profile_active is not true then
    raise exception using
      errcode = '42501',
      message = 'Only an active company Admin can generate a new company code.';
  end if;

  loop
    v_new_code := upper(
      substr(
        replace(gen_random_uuid()::text, '-', ''),
        1,
        8
      )
    );

    exit when not exists (
      select 1
      from public.companies
      where upper(btrim(join_code)) = v_new_code
    );
  end loop;

  update public.companies
  set join_code = v_new_code
  where id = v_company_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Company was not found.';
  end if;

  return v_new_code;
end;
$$;

revoke all on function public.rotate_company_join_code() from public;
revoke all on function public.rotate_company_join_code() from anon;
grant execute on function public.rotate_company_join_code()
to authenticated;

commit;
