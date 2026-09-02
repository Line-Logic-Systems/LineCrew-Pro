begin;

create or replace function public.backup_public_table_inventory()
returns table(table_name text)
language sql
stable
security definer
set search_path to ''
as $$
  select c.relname::text
  from pg_catalog.pg_class c
  join pg_catalog.pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r'
  order by c.relname;
$$;

revoke all on function public.backup_public_table_inventory() from public, anon, authenticated;
grant execute on function public.backup_public_table_inventory() to service_role;

commit;
