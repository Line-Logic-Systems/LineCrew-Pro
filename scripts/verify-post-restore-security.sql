\set ON_ERROR_STOP on

do $$
declare
  v_setting text;
begin
  select setting
  into v_setting
  from (
    select split_part(item, '=', 2) as setting
    from pg_db_role_setting role_setting
    join pg_roles role_entry on role_entry.oid = role_setting.setrole
    cross join lateral unnest(role_setting.setconfig) item
    where role_entry.rolname = 'authenticator'
      and split_part(item, '=', 1) = 'pgrst.db_pre_request'
  ) configured
  limit 1;

  if v_setting is distinct from 'public.enforce_linecrew_company_access' then
    raise exception 'Recovery security gate is not active for authenticator.';
  end if;
end;
$$;

select true as recovery_security_gate_verified;
