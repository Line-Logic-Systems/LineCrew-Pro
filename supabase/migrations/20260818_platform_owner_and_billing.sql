begin;

create table if not exists public.platform_owners (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  created_by uuid null references auth.users(id) on delete set null
);

alter table public.platform_owners enable row level security;
revoke all on public.platform_owners from anon, authenticated;

create table if not exists public.company_subscriptions (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null unique references public.companies(id) on delete cascade,
  plan_code text not null default 'pilot',
  monthly_price_cents integer not null default 0 check (monthly_price_cents >= 0),
  currency text not null default 'usd',
  status text not null default 'trialing' check (status in ('trialing','active','past_due','paused','canceled','incomplete')),
  access_enabled boolean not null default true,
  trial_ends_at timestamptz null,
  current_period_start timestamptz null,
  current_period_end timestamptz null,
  cancel_at_period_end boolean not null default false,
  stripe_customer_id text null unique,
  stripe_subscription_id text null unique,
  stripe_price_id text null,
  provider text not null default 'manual' check (provider in ('manual','stripe')),
  notes text null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.company_subscriptions enable row level security;
revoke all on public.company_subscriptions from anon, authenticated;

create table if not exists public.billing_events (
  id uuid primary key default gen_random_uuid(),
  company_id uuid null references public.companies(id) on delete set null,
  provider text not null default 'stripe',
  provider_event_id text null unique,
  event_type text not null,
  payload jsonb not null default '{}'::jsonb,
  processed_at timestamptz null,
  error_text text null,
  created_at timestamptz not null default now()
);

alter table public.billing_events enable row level security;
revoke all on public.billing_events from anon, authenticated;

create or replace function public.is_platform_owner()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1
    from public.platform_owners po
    where po.user_id = auth.uid()
  );
$$;

revoke all on function public.is_platform_owner() from public, anon;
grant execute on function public.is_platform_owner() to authenticated;

create or replace function public.platform_owner_company_dashboard()
returns table (
  company_id uuid,
  company_name text,
  active_users bigint,
  active_jobs bigint,
  total_reports bigint,
  last_report_at timestamptz,
  plan_code text,
  monthly_price_cents integer,
  subscription_status text,
  access_enabled boolean,
  trial_ends_at timestamptz,
  current_period_end timestamptz,
  provider text,
  stripe_customer_id text,
  stripe_subscription_id text
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.is_platform_owner() then
    raise exception 'Platform owner access required';
  end if;

  return query
  select
    c.id,
    c.name,
    (select count(*) from public.profiles p where p.company_id = c.id and coalesce(p.active, true) = true),
    (select count(*) from public.jobs j where j.company_id = c.id and coalesce(j.active, true) = true),
    (select count(*) from public.daily_reports dr where dr.company_id = c.id),
    (select max(dr.created_at) from public.daily_reports dr where dr.company_id = c.id),
    coalesce(cs.plan_code, 'unconfigured'),
    coalesce(cs.monthly_price_cents, 0),
    coalesce(cs.status, 'incomplete'),
    coalesce(cs.access_enabled, false),
    cs.trial_ends_at,
    cs.current_period_end,
    coalesce(cs.provider, 'manual'),
    cs.stripe_customer_id,
    cs.stripe_subscription_id
  from public.companies c
  left join public.company_subscriptions cs on cs.company_id = c.id
  order by lower(c.name), c.created_at;
end;
$$;

revoke all on function public.platform_owner_company_dashboard() from public, anon;
grant execute on function public.platform_owner_company_dashboard() to authenticated;

create or replace function public.platform_owner_set_subscription(
  p_company_id uuid,
  p_plan_code text,
  p_monthly_price_cents integer,
  p_status text,
  p_access_enabled boolean,
  p_trial_ends_at timestamptz default null,
  p_notes text default null
)
returns public.company_subscriptions
language plpgsql
security definer
set search_path = public
as $$
declare
  result public.company_subscriptions;
begin
  if not public.is_platform_owner() then
    raise exception 'Platform owner access required';
  end if;

  if p_monthly_price_cents < 0 then
    raise exception 'Monthly price cannot be negative';
  end if;

  if p_status not in ('trialing','active','past_due','paused','canceled','incomplete') then
    raise exception 'Invalid subscription status';
  end if;

  if not exists (select 1 from public.companies c where c.id = p_company_id) then
    raise exception 'Company not found';
  end if;

  insert into public.company_subscriptions (
    company_id, plan_code, monthly_price_cents, status, access_enabled,
    trial_ends_at, notes, provider, updated_at
  ) values (
    p_company_id, coalesce(nullif(trim(p_plan_code), ''), 'custom'), p_monthly_price_cents,
    p_status, p_access_enabled, p_trial_ends_at, p_notes, 'manual', now()
  )
  on conflict (company_id) do update set
    plan_code = excluded.plan_code,
    monthly_price_cents = excluded.monthly_price_cents,
    status = excluded.status,
    access_enabled = excluded.access_enabled,
    trial_ends_at = excluded.trial_ends_at,
    notes = excluded.notes,
    updated_at = now()
  returning * into result;

  return result;
end;
$$;

revoke all on function public.platform_owner_set_subscription(uuid,text,integer,text,boolean,timestamptz,text) from public, anon;
grant execute on function public.platform_owner_set_subscription(uuid,text,integer,text,boolean,timestamptz,text) to authenticated;

create or replace function public.my_company_subscription_access()
returns table (
  company_id uuid,
  plan_code text,
  status text,
  access_enabled boolean,
  trial_ends_at timestamptz,
  current_period_end timestamptz
)
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_company_id uuid;
begin
  select p.company_id into v_company_id
  from public.profiles p
  where p.id = auth.uid() and coalesce(p.active, true) = true;

  if v_company_id is null then
    return;
  end if;

  return query
  select
    v_company_id,
    coalesce(cs.plan_code, 'pilot'),
    coalesce(cs.status, 'trialing'),
    coalesce(cs.access_enabled, true),
    cs.trial_ends_at,
    cs.current_period_end
  from (select 1) x
  left join public.company_subscriptions cs on cs.company_id = v_company_id;
end;
$$;

revoke all on function public.my_company_subscription_access() from public, anon;
grant execute on function public.my_company_subscription_access() to authenticated;

create or replace function public.billing_service_upsert_subscription(
  p_company_id uuid,
  p_stripe_customer_id text,
  p_stripe_subscription_id text,
  p_stripe_price_id text,
  p_status text,
  p_current_period_start timestamptz,
  p_current_period_end timestamptz,
  p_cancel_at_period_end boolean,
  p_access_enabled boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if current_setting('request.jwt.claim.role', true) is distinct from 'service_role' then
    raise exception 'Service role required';
  end if;

  insert into public.company_subscriptions (
    company_id, provider, stripe_customer_id, stripe_subscription_id, stripe_price_id,
    status, current_period_start, current_period_end, cancel_at_period_end,
    access_enabled, updated_at
  ) values (
    p_company_id, 'stripe', p_stripe_customer_id, p_stripe_subscription_id, p_stripe_price_id,
    p_status, p_current_period_start, p_current_period_end, p_cancel_at_period_end,
    p_access_enabled, now()
  )
  on conflict (company_id) do update set
    provider = 'stripe',
    stripe_customer_id = excluded.stripe_customer_id,
    stripe_subscription_id = excluded.stripe_subscription_id,
    stripe_price_id = excluded.stripe_price_id,
    status = excluded.status,
    current_period_start = excluded.current_period_start,
    current_period_end = excluded.current_period_end,
    cancel_at_period_end = excluded.cancel_at_period_end,
    access_enabled = excluded.access_enabled,
    updated_at = now();
end;
$$;

revoke all on function public.billing_service_upsert_subscription(uuid,text,text,text,text,timestamptz,timestamptz,boolean,boolean) from public, anon, authenticated;
grant execute on function public.billing_service_upsert_subscription(uuid,text,text,text,text,timestamptz,timestamptz,boolean,boolean) to service_role;

commit;
