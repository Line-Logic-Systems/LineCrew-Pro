create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  endpoint text not null,
  p256dh text not null,
  auth text not null,
  user_agent text,
  created_at timestamptz not null default now(),
  last_success_at timestamptz,
  failure_count integer not null default 0,
  constraint push_subscriptions_endpoint_unique unique (endpoint)
);

alter table public.push_subscriptions enable row level security;
revoke all on public.push_subscriptions from public, anon, authenticated;
grant select, update, delete on public.push_subscriptions to service_role;

create index if not exists push_subscriptions_user_idx
  on public.push_subscriptions (user_id);
create index if not exists push_subscriptions_company_idx
  on public.push_subscriptions (company_id);

create or replace function public.linecrew_save_push_subscription(
  p_endpoint text,
  p_p256dh text,
  p_auth text,
  p_user_agent text
) returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_company_id uuid;
  v_endpoint text := btrim(coalesce(p_endpoint, ''));
  v_p256dh text := btrim(coalesce(p_p256dh, ''));
  v_auth text := btrim(coalesce(p_auth, ''));
  v_user_agent text := nullif(left(btrim(coalesce(p_user_agent, '')), 300), '');
begin
  if v_user_id is null then
    raise exception using errcode = '42501', message = 'Authentication required.';
  end if;
  if v_endpoint = '' or length(v_endpoint) > 4096 or v_endpoint !~ '^https://' then
    raise exception using errcode = '22023', message = 'A valid push endpoint is required.';
  end if;
  if v_p256dh = '' or length(v_p256dh) > 512 or v_auth = '' or length(v_auth) > 512 then
    raise exception using errcode = '22023', message = 'Valid push subscription keys are required.';
  end if;

  select profile.company_id
  into v_company_id
  from public.profiles profile
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where profile.id = v_user_id
    and profile.active is true;

  if v_company_id is null then
    raise exception using errcode = '42501', message = 'An active company profile is required.';
  end if;

  insert into public.push_subscriptions (
    company_id,
    user_id,
    endpoint,
    p256dh,
    auth,
    user_agent,
    failure_count
  ) values (
    v_company_id,
    v_user_id,
    v_endpoint,
    v_p256dh,
    v_auth,
    v_user_agent,
    0
  )
  on conflict (endpoint) do update
  set company_id = excluded.company_id,
      user_id = excluded.user_id,
      p256dh = excluded.p256dh,
      auth = excluded.auth,
      user_agent = excluded.user_agent,
      failure_count = 0;
end;
$$;

create or replace function public.linecrew_delete_push_subscription(
  p_endpoint text
) returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception using errcode = '42501', message = 'Authentication required.';
  end if;

  delete from public.push_subscriptions subscription
  where subscription.endpoint = btrim(coalesce(p_endpoint, ''))
    and subscription.user_id = v_user_id;
end;
$$;

create or replace function public.linecrew_my_push_status()
returns table(subscription_count integer)
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then
    raise exception using errcode = '42501', message = 'Authentication required.';
  end if;

  return query
  select count(*)::integer
  from public.push_subscriptions subscription
  where subscription.user_id = v_user_id;
end;
$$;

revoke all on function public.linecrew_save_push_subscription(text, text, text, text) from public, anon;
revoke all on function public.linecrew_delete_push_subscription(text) from public, anon;
revoke all on function public.linecrew_my_push_status() from public, anon;

grant execute on function public.linecrew_save_push_subscription(text, text, text, text) to authenticated;
grant execute on function public.linecrew_delete_push_subscription(text) to authenticated;
grant execute on function public.linecrew_my_push_status() to authenticated;
