begin;

create table if not exists public.platform_owners (
  user_id uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  created_by uuid null references auth.users(id) on delete set null
);

alter table public.platform_owners enable row level security;
revoke all on public.platform_owners from anon, authenticated;
grant all on public.platform_owners to service_role;

create table if not exists public.company_subscriptions (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null unique references public.companies(id) on delete cascade,
  plan_code text not null default 'pilot',
  monthly_price_cents integer not null default 0 check (monthly_price_cents >= 0),
  currency text not null default 'usd',
  status text not null default 'trialing' check (status in ('trialing','active','past_due','paused','canceled','incomplete')),
  access_enabled boolean not null default true,
  access_override boolean null,
  trial_ends_at timestamptz null,
  current_period_start timestamptz null,
  current_period_end timestamptz null,
  past_due_since timestamptz null,
  cancel_at_period_end boolean not null default false,
  stripe_customer_id text null unique,
  stripe_subscription_id text null unique,
  stripe_price_id text null,
  billing_interval text null check (billing_interval is null or billing_interval in ('day','week','month','year')),
  billing_interval_count integer null check (billing_interval_count is null or billing_interval_count > 0),
  provider text not null default 'manual' check (provider in ('manual','stripe')),
  notes text null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.company_subscriptions enable row level security;
revoke all on public.company_subscriptions from anon, authenticated;
grant all on public.company_subscriptions to service_role;

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
grant all on public.billing_events to service_role;

create table if not exists public.platform_owner_audit_events (
  id uuid primary key default gen_random_uuid(),
  actor_user_id uuid null references auth.users(id) on delete set null,
  company_id uuid null references public.companies(id) on delete set null,
  action text not null,
  before_state jsonb null,
  after_state jsonb null,
  created_at timestamptz not null default now()
);

create index if not exists platform_owner_audit_company_created_idx
  on public.platform_owner_audit_events(company_id, created_at desc);

alter table public.platform_owner_audit_events enable row level security;
revoke all on public.platform_owner_audit_events from anon, authenticated;
grant all on public.platform_owner_audit_events to service_role;

-- Preserve every existing contractor's access when billing is first installed.
insert into public.company_subscriptions (
  company_id, plan_code, monthly_price_cents, status, access_enabled, provider
)
select c.id, 'pilot', 0, 'trialing', true, 'manual'
from public.companies c
on conflict (company_id) do nothing;

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
  contact_email text,
  company_created_at timestamptz,
  active_users bigint,
  active_jobs bigint,
  total_reports bigint,
  last_report_at timestamptz,
  plan_code text,
  monthly_price_cents integer,
  subscription_status text,
  access_enabled boolean,
  access_override boolean,
  trial_ends_at timestamptz,
  current_period_end timestamptz,
  cancel_at_period_end boolean,
  provider text,
  stripe_customer_linked boolean,
  stripe_subscription_linked boolean,
  internal_notes text
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
    c.contact_email,
    c.created_at,
    (select count(*) from public.profiles p where p.company_id = c.id and coalesce(p.active, true) = true),
    (select count(*) from public.jobs j where j.company_id = c.id and coalesce(j.active, true) = true),
    (select count(*) from public.daily_reports dr where dr.company_id = c.id),
    (select max(dr.created_at) from public.daily_reports dr where dr.company_id = c.id),
    coalesce(cs.plan_code, 'pilot'),
    coalesce(cs.monthly_price_cents, 0),
    coalesce(cs.status, 'trialing'),
    coalesce(cs.access_override, cs.access_enabled, true),
    cs.access_override,
    cs.trial_ends_at,
    cs.current_period_end,
    coalesce(cs.cancel_at_period_end, false),
    coalesce(cs.provider, 'manual'),
    cs.stripe_customer_id is not null,
    cs.stripe_subscription_id is not null,
    cs.notes
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
  p_access_override boolean default null,
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
  v_before jsonb;
  v_provider text;
  v_base_access boolean;
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

  select to_jsonb(cs), cs.provider
  into v_before, v_provider
  from public.company_subscriptions cs
  where cs.company_id = p_company_id;

  v_base_access := p_status in ('trialing','active','past_due');

  if v_provider = 'stripe' then
    -- Stripe remains the source of truth for price/status/period data. Platform
    -- owners may still change the internal plan label, notes, or force an access
    -- override without a later webhook silently undoing that support decision.
    update public.company_subscriptions cs
    set
      plan_code = coalesce(nullif(trim(p_plan_code), ''), cs.plan_code),
      access_override = p_access_override,
      notes = p_notes,
      updated_at = now()
    where cs.company_id = p_company_id
    returning cs.* into result;
  else
    insert into public.company_subscriptions (
      company_id, plan_code, monthly_price_cents, status, access_enabled,
      access_override, trial_ends_at, notes, provider, updated_at
    ) values (
      p_company_id,
      coalesce(nullif(trim(p_plan_code), ''), 'custom'),
      p_monthly_price_cents,
      p_status,
      v_base_access,
      p_access_override,
      p_trial_ends_at,
      p_notes,
      'manual',
      now()
    )
    on conflict (company_id) do update set
      plan_code = excluded.plan_code,
      monthly_price_cents = excluded.monthly_price_cents,
      status = excluded.status,
      access_enabled = excluded.access_enabled,
      access_override = excluded.access_override,
      trial_ends_at = excluded.trial_ends_at,
      notes = excluded.notes,
      updated_at = now()
    returning * into result;
  end if;

  insert into public.platform_owner_audit_events (
    actor_user_id, company_id, action, before_state, after_state
  ) values (
    auth.uid(), p_company_id, 'subscription_settings_updated', v_before, to_jsonb(result)
  );

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
    coalesce(cs.access_override, cs.access_enabled, true),
    cs.trial_ends_at,
    cs.current_period_end
  from (select 1) x
  left join public.company_subscriptions cs on cs.company_id = v_company_id;
end;
$$;

revoke all on function public.my_company_subscription_access() from public, anon;
grant execute on function public.my_company_subscription_access() to authenticated;

create or replace function public.my_company_billing_summary()
returns table (
  plan_code text,
  monthly_price_cents integer,
  currency text,
  status text,
  access_enabled boolean,
  provider text,
  trial_ends_at timestamptz,
  current_period_end timestamptz,
  cancel_at_period_end boolean,
  stripe_customer_linked boolean,
  stripe_subscription_linked boolean
)
language plpgsql
security definer
set search_path = public
stable
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  select p.company_id, lower(coalesce(p.role,'')), coalesce(p.active, true)
  into v_company_id, v_role, v_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or not v_active or v_role <> 'admin' then
    raise exception 'Company Admin access required';
  end if;

  return query
  select
    coalesce(cs.plan_code, 'pilot'),
    coalesce(cs.monthly_price_cents, 0),
    coalesce(cs.currency, 'usd'),
    coalesce(cs.status, 'trialing'),
    coalesce(cs.access_override, cs.access_enabled, true),
    coalesce(cs.provider, 'manual'),
    cs.trial_ends_at,
    cs.current_period_end,
    coalesce(cs.cancel_at_period_end, false),
    cs.stripe_customer_id is not null,
    cs.stripe_subscription_id is not null
  from (select 1) x
  left join public.company_subscriptions cs on cs.company_id = v_company_id;
end;
$$;

revoke all on function public.my_company_billing_summary() from public, anon;
grant execute on function public.my_company_billing_summary() to authenticated;

commit;
