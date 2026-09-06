-- Server-side Utility Portal rollout controls. Access requires both the one
-- global row and a company row to exist with enabled = true. Missing rows are
-- deliberately interpreted as disabled by portal access helpers.
create table public.utility_portal_feature_flags (
  id uuid primary key default gen_random_uuid(),
  company_id uuid references public.companies(id) on delete cascade,
  enabled boolean not null default false,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null,
  updated_at timestamptz not null default now()
);

comment on table public.utility_portal_feature_flags is
  'Fail-closed Utility Portal rollout controls: NULL company_id is the global kill switch; non-NULL company_id is a company opt-in.';

create unique index utility_portal_feature_flags_global_uidx
  on public.utility_portal_feature_flags ((true))
  where company_id is null;

create unique index utility_portal_feature_flags_company_uidx
  on public.utility_portal_feature_flags (company_id)
  where company_id is not null;

alter table public.utility_portal_feature_flags enable row level security;

create policy utility_portal_flags_platform_owner_select
  on public.utility_portal_feature_flags
  for select
  to authenticated
  using ((select public.is_platform_owner()));

create policy utility_portal_flags_platform_owner_insert
  on public.utility_portal_feature_flags
  for insert
  to authenticated
  with check ((select public.is_platform_owner()));

create policy utility_portal_flags_platform_owner_update
  on public.utility_portal_feature_flags
  for update
  to authenticated
  using ((select public.is_platform_owner()))
  with check ((select public.is_platform_owner()));

create policy utility_portal_flags_platform_owner_delete
  on public.utility_portal_feature_flags
  for delete
  to authenticated
  using ((select public.is_platform_owner()));

revoke all on table public.utility_portal_feature_flags from public, anon, authenticated;
grant select, insert, update, delete on table public.utility_portal_feature_flags to authenticated;

insert into public.utility_portal_feature_flags (company_id, enabled)
values (null, false);
