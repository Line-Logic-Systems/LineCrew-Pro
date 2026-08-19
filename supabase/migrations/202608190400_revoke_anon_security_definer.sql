-- Security hardening: LineCrew Pro's SECURITY DEFINER RPCs are authenticated app
-- operations. Anonymous users should never be able to invoke them through the
-- Data API. This preserves grants for authenticated/service roles and only
-- removes EXECUTE from anon.

do $$
declare
  fn record;
begin
  for fn in
    select p.oid::regprocedure as signature
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.prosecdef is true
  loop
    execute format('revoke execute on function %s from anon', fn.signature);
  end loop;
end;
$$;
