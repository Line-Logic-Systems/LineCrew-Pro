begin;

-- Increase fallback company-code entropy from 32 bits to 64 bits. Email-bound,
-- one-time invitations remain the preferred onboarding path.
alter table public.companies
  alter column join_code
  set default upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16));

-- Existing short codes are credentials. Rotate them in place without changing
-- company membership or any operational company data.
update public.companies
set join_code = upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16))
where length(join_code) < 16;

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
  select p.company_id, lower(coalesce(p.role, '')), p.active
  into v_company_id, v_role, v_profile_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null
     or v_profile_active is not true
     or v_role not in ('owner', 'admin', 'superintendent') then
    raise exception using
      errcode = '42501',
      message = 'Only active company leadership can generate a new company code.';
  end if;

  if v_role = 'superintendent'
     and not public.linecrew_has_capability('team_management') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have team management permission.';
  end if;

  loop
    v_new_code := upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 16));
    exit when not exists (
      select 1
      from public.companies c
      where upper(btrim(c.join_code)) = v_new_code
    );
  end loop;

  update public.companies c
  set join_code = v_new_code
  where c.id = v_company_id;

  if not found then
    raise exception using errcode = 'P0002', message = 'Company was not found.';
  end if;

  return v_new_code;
end;
$$;

revoke all on function public.rotate_company_join_code() from public, anon;
grant execute on function public.rotate_company_join_code() to authenticated, service_role;

commit;
