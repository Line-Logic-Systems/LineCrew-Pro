begin;

alter table public.companies
  add column if not exists subscription_status text not null default 'trial',
  add column if not exists subscription_expires_at timestamptz;

alter table public.companies
  drop constraint if exists companies_subscription_status_supported;

alter table public.companies
  add constraint companies_subscription_status_supported
  check (subscription_status in ('trial','active','past_due','suspended','cancelled'));

create table if not exists public.training_videos (
  id uuid primary key default gen_random_uuid(),
  slug text not null unique,
  title text not null,
  description text,
  category text not null,
  sort_order integer not null default 0,
  storage_path text not null unique,
  duration_seconds integer,
  minimum_role text not null default 'foreman',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint training_video_role_supported
    check (minimum_role in ('foreman','gf','superintendent','admin','owner'))
);

create table if not exists public.training_progress (
  company_id uuid not null references public.companies(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  video_id uuid not null references public.training_videos(id) on delete cascade,
  started_at timestamptz,
  completed_at timestamptz,
  last_position_seconds integer not null default 0,
  updated_at timestamptz not null default now(),
  primary key (user_id, video_id)
);

alter table public.training_videos enable row level security;
alter table public.training_progress enable row level security;

create or replace function public.training_role_rank(p_role text)
returns integer
language sql
immutable
as $$
  select case lower(coalesce(p_role,''))
    when 'owner' then 5
    when 'admin' then 4
    when 'superintendent' then 3
    when 'gf' then 2
    when 'general foreman' then 2
    when 'foreman' then 1
    else 0
  end;
$$;

create or replace function public.current_training_access()
returns table (
  company_id uuid,
  role text,
  subscription_status text,
  can_train boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    p.company_id,
    lower(coalesce(p.role,'')) as role,
    c.subscription_status,
    (
      coalesce(p.active, true) is true
      and c.subscription_status in ('trial','active')
      and (c.subscription_expires_at is null or c.subscription_expires_at > now())
    ) as can_train
  from public.profiles p
  join public.companies c on c.id = p.company_id
  where p.id = auth.uid();
$$;

revoke all on function public.current_training_access() from public, anon;
grant execute on function public.current_training_access() to authenticated;

create policy training_videos_subscriber_read
on public.training_videos
for select
to authenticated
using (
  active is true
  and exists (
    select 1
    from public.current_training_access() a
    where a.can_train is true
      and public.training_role_rank(a.role) >= public.training_role_rank(training_videos.minimum_role)
  )
);

create policy training_progress_read_own_company
on public.training_progress
for select
to authenticated
using (
  user_id = auth.uid()
  or exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.company_id = training_progress.company_id
      and lower(coalesce(p.role,'')) in ('owner','admin')
      and coalesce(p.active, true) is true
  )
);

create policy training_progress_write_own
on public.training_progress
for insert
to authenticated
with check (
  user_id = auth.uid()
  and exists (
    select 1
    from public.current_training_access() a
    where a.company_id = training_progress.company_id
      and a.can_train is true
  )
);

create policy training_progress_update_own
on public.training_progress
for update
to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

insert into storage.buckets (id, name, public)
values ('training-videos', 'training-videos', false)
on conflict (id) do update set public = false;

commit;