begin;

-- Defense in depth: inactive profiles must not resolve tenant or role context,
-- even if a future table policy accidentally omits the restrictive active gate.
create or replace function public.my_company_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select profile.company_id
  from public.profiles profile
  where profile.id = auth.uid()
    and profile.active is true
  limit 1;
$$;

create or replace function public.my_role()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select profile.role
  from public.profiles profile
  where profile.id = auth.uid()
    and profile.active is true
  limit 1;
$$;

revoke all on function public.my_company_id() from public, anon;
revoke all on function public.my_role() from public, anon;
grant execute on function public.my_company_id() to authenticated;
grant execute on function public.my_role() to authenticated;

-- Rebuild the existing suspension gates explicitly as restrictive policies.
-- Restrictive policies are ANDed with every tenant/role policy, so no
-- permissive same-company rule can keep a suspended session alive.
do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'companies',
    'profiles',
    'customers',
    'contracts',
    'price_books',
    'price_book_items',
    'jobs',
    'daily_reports'
  ]
  loop
    if to_regclass('public.' || v_table) is not null then
      execute format('alter table public.%I enable row level security', v_table);
      execute format('drop policy if exists active_profile_required on public.%I', v_table);
      execute format(
        'create policy active_profile_required on public.%I as restrictive for all to authenticated using ((select public.current_user_has_active_profile())) with check ((select public.current_user_has_active_profile()))',
        v_table
      );
    end if;
  end loop;
end;
$$;

commit;
