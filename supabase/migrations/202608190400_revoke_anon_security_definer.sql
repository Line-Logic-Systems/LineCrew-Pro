-- Security hardening: LineCrew Pro's SECURITY DEFINER RPCs are authenticated app
-- operations. Anonymous users should never be able to invoke them through the
-- Data API. PostgreSQL grants EXECUTE to PUBLIC by default, so preserve explicit
-- authenticated access first, then remove PUBLIC/anon execution.

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
    execute format('grant execute on function %s to authenticated', fn.signature);
    execute format('revoke execute on function %s from public', fn.signature);
    execute format('revoke execute on function %s from anon', fn.signature);
  end loop;
end;
$$;
