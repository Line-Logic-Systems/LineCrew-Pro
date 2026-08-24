\set ON_ERROR_STOP on

do $$
begin
  if to_regprocedure('public.enforce_linecrew_company_access()') is null then
    raise exception 'Recovery security gate function is missing; apply repository migrations before enabling the recovered app.';
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticator') then
    raise exception 'Recovery database is missing the authenticator role.';
  end if;
end;
$$;

alter role authenticator
  set pgrst.db_pre_request = 'public.enforce_linecrew_company_access';
notify pgrst, 'reload config';
notify pgrst, 'reload schema';
