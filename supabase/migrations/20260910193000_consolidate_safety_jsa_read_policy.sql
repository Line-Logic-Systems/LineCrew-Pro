-- Fold Safety read access into the existing JSA SELECT policy so PostgreSQL
-- evaluates one permissive policy instead of two for every JSA query.
do $do$
declare pol record; combined_qual text; role_sql text;
begin
  select * into pol from pg_policies
  where schemaname='public' and tablename='daily_report_jsas'
    and policyname='daily_report_jsas_role_scoped_select';
  if pol.policyname is null then
    raise exception 'daily_report_jsas_role_scoped_select policy is missing';
  end if;
  combined_qual := '(' || pol.qual || ') or (' ||
    'company_id = (select public.my_company_id()) and ' ||
    '(select public.current_user_has_active_profile()) and ' ||
    'lower(coalesce((select public.my_role()),'''')) = ''safety'')';
  role_sql := array_to_string(array(select quote_ident(r) from unnest(pol.roles) r), ', ');
  execute format('drop policy %I on public.daily_report_jsas', pol.policyname);
  execute format('create policy %I on public.daily_report_jsas as %s for select to %s using (%s)',
    pol.policyname, pol.permissive, role_sql, combined_qual);
end;
$do$;

drop policy if exists safety_read_company_jsas on public.daily_report_jsas;
