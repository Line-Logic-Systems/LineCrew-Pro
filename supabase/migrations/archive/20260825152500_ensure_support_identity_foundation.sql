begin;

-- The privileged access hook resolves support identity on every authenticated
-- request. Keep this smallest support identity object present even in a
-- disposable environment that has not yet replayed the full support-console
-- migration. Production already has this table, so this is idempotent there.
create table if not exists public.platform_support_users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  active boolean not null default true,
  display_name text not null,
  created_at timestamptz not null default now()
);

alter table public.platform_support_users enable row level security;
revoke all on table public.platform_support_users from public, anon, authenticated;
grant all on table public.platform_support_users to service_role;

create or replace function public.is_platform_support()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.platform_support_users support_user
    where support_user.user_id = (select auth.uid())
      and support_user.active is true
  );
$$;

revoke all on function public.is_platform_support() from public, anon;
grant execute on function public.is_platform_support() to authenticated;

commit;
