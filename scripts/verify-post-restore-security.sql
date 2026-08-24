\set ON_ERROR_STOP on

do $$
declare
  v_setting text;
  v_anon_definer_functions text[];
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

  if not has_function_privilege(
    'authenticator',
    'public.enforce_linecrew_company_access()',
    'EXECUTE'
  ) then
    raise exception 'Authenticator cannot execute the recovery security gate.';
  end if;

  select array_agg(proc.oid::regprocedure::text order by proc.oid::regprocedure::text)
  into v_anon_definer_functions
  from pg_proc proc
  join pg_namespace namespace_entry on namespace_entry.oid = proc.pronamespace
  where namespace_entry.nspname = 'public'
    and proc.prosecdef is true
    and has_function_privilege('anon', proc.oid, 'EXECUTE');

  if coalesce(cardinality(v_anon_definer_functions), 0) > 0 then
    raise exception 'Anonymous EXECUTE remains on SECURITY DEFINER functions: %',
      array_to_string(v_anon_definer_functions, ', ');
  end if;

  if to_regprocedure('public.admin_update_user(uuid,text,boolean)') is not null
     and has_function_privilege(
       'authenticated',
       'public.admin_update_user(uuid,text,boolean)',
       'EXECUTE'
     ) then
    raise exception 'Legacy admin_update_user is executable by authenticated after restore.';
  end if;
end;
$$;

select true as recovery_security_gate_and_function_acls_verified;
