begin;

create table if not exists public.user_dashboard_preferences (
  user_id uuid primary key
    references public.profiles(id) on delete cascade,
  company_id uuid not null
    references public.companies(id) on delete cascade,
  tile_order text[] not null default '{}'::text[],
  updated_at timestamptz not null default now(),
  constraint user_dashboard_preferences_tile_limit
    check (cardinality(tile_order) <= 32)
);

create index if not exists user_dashboard_preferences_company_idx
  on public.user_dashboard_preferences(company_id);

alter table public.user_dashboard_preferences enable row level security;

revoke all on table public.user_dashboard_preferences from public, anon;
grant select, insert, update on table public.user_dashboard_preferences
  to authenticated;

drop policy if exists user_dashboard_preferences_select_own
  on public.user_dashboard_preferences;
create policy user_dashboard_preferences_select_own
  on public.user_dashboard_preferences
  for select
  to authenticated
  using (
    (select auth.uid()) = user_id
    and exists (
      select 1
      from public.profiles profile
      where profile.id = (select auth.uid())
        and profile.company_id = user_dashboard_preferences.company_id
        and profile.active is true
        and lower(coalesce(profile.role, '')) in ('admin', 'owner')
    )
  );

drop policy if exists user_dashboard_preferences_insert_own
  on public.user_dashboard_preferences;
create policy user_dashboard_preferences_insert_own
  on public.user_dashboard_preferences
  for insert
  to authenticated
  with check (
    (select auth.uid()) = user_id
    and exists (
      select 1
      from public.profiles profile
      where profile.id = (select auth.uid())
        and profile.company_id = user_dashboard_preferences.company_id
        and profile.active is true
        and lower(coalesce(profile.role, '')) in ('admin', 'owner')
    )
  );

drop policy if exists user_dashboard_preferences_update_own
  on public.user_dashboard_preferences;
create policy user_dashboard_preferences_update_own
  on public.user_dashboard_preferences
  for update
  to authenticated
  using (
    (select auth.uid()) = user_id
    and exists (
      select 1
      from public.profiles profile
      where profile.id = (select auth.uid())
        and profile.company_id = user_dashboard_preferences.company_id
        and profile.active is true
        and lower(coalesce(profile.role, '')) in ('admin', 'owner')
    )
  )
  with check (
    (select auth.uid()) = user_id
    and exists (
      select 1
      from public.profiles profile
      where profile.id = (select auth.uid())
        and profile.company_id = user_dashboard_preferences.company_id
        and profile.active is true
        and lower(coalesce(profile.role, '')) in ('admin', 'owner')
    )
  );

comment on table public.user_dashboard_preferences is
  'Per-account dashboard card order for active company Admin and Owner users.';

commit;
