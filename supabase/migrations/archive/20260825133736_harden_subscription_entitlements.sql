begin;

-- C-4: retire the legacy status setter. The v2 RPC is the only browser-facing
-- status transition surface because it protects credit/rebill relationships.
do $$
begin
  if to_regprocedure('public.set_billing_export_batch_status(uuid,text)') is not null then
    execute 'revoke all on function public.set_billing_export_batch_status(uuid,text) from public, anon, authenticated';
  end if;
end;
$$;

-- C-2: company settings are already changed through narrowly-scoped SECURITY
-- DEFINER RPCs. Remove direct table UPDATE so leadership cannot rewrite access,
-- join-code, or lifecycle columns through PostgREST.
revoke update on table public.companies from authenticated;

-- C-3: a self-created company receives a short, bounded evaluation instead of
-- a permanent, unlimited pilot. Approved pilots can be extended explicitly by
-- a platform owner through the existing audited subscription RPC.
create or replace function public.plan_crew_limit(p_plan_code text)
returns integer
language sql
immutable
set search_path = ''
as $$
  select case lower(coalesce(p_plan_code,''))
    when 'pilot' then 5
    when 'starter' then 5
    when 'business' then 10
    when 'pro' then 20
    when 'enterprise' then 40
    else null
  end;
$$;

create or replace function public.ensure_company_subscription()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.company_subscriptions (
    company_id,
    plan_code,
    monthly_price_cents,
    status,
    access_enabled,
    provider,
    included_crew_limit,
    trial_ends_at
  ) values (
    new.id,
    'pilot',
    0,
    'trialing',
    true,
    'manual',
    5,
    now() + interval '14 days'
  )
  on conflict (company_id) do nothing;
  return new;
end;
$$;

revoke all on function public.ensure_company_subscription()
  from public, anon, authenticated;
grant execute on function public.ensure_company_subscription() to service_role;

-- Preserve current internal/pilot access during rollout, but make the window
-- explicit and finite. Platform Owner can approve and extend a real beta.
update public.company_subscriptions
set trial_ends_at = now() + interval '30 days',
    included_crew_limit = coalesce(included_crew_limit, 5),
    updated_at = now()
where provider = 'manual'
  and lower(plan_code) = 'pilot'
  and lower(status) = 'trialing'
  and trial_ends_at is null;

create or replace function public.enforce_active_crew_plan_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_plan text;
  v_limit integer;
  v_active_crews integer;
begin
  if coalesce(new.active, true) = false then
    return new;
  end if;

  if tg_op = 'UPDATE'
     and coalesce(old.active, true) = true
     and old.company_id = new.company_id then
    return new;
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(new.company_id::text, 487921)
  );

  select lower(cs.plan_code),
         coalesce(cs.included_crew_limit, public.plan_crew_limit(cs.plan_code))
    into v_plan, v_limit
  from public.company_subscriptions cs
  where cs.company_id = new.company_id;

  if v_plan is null then
    raise exception 'This company does not have a subscription plan. Contact LineCrew Pro support.';
  end if;

  -- Custom/41+ plans remain support-managed and may intentionally have no cap.
  if v_plan = 'custom' and v_limit is null then
    return new;
  end if;

  if v_limit is null or v_limit < 1 then
    raise exception 'This company does not have a valid crew limit. Contact LineCrew Pro support.';
  end if;

  select count(*)::integer
    into v_active_crews
  from public.crews c
  where c.company_id = new.company_id
    and coalesce(c.active, true) = true
    and c.id is distinct from new.id;

  if v_active_crews >= v_limit then
    raise exception '% includes up to % active crews. Deactivate an existing crew or upgrade the company plan before activating another crew.',
      initcap(v_plan), v_limit;
  end if;

  return new;
end;
$$;

revoke all on function public.enforce_active_crew_plan_limit()
  from public, anon, authenticated;
grant execute on function public.enforce_active_crew_plan_limit() to service_role;

-- C-1/H-15: company_subscriptions is the entitlement source of truth.
-- Support overrides are explicit. Otherwise active/trial/grace states are
-- evaluated dynamically, and missing subscription state fails closed.
create or replace function public.enforce_linecrew_company_access()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_profile_active boolean;
  v_role text;
  v_is_support boolean;
  v_has_profile boolean;
  v_subscription_found boolean;
  v_status text;
  v_access_enabled boolean;
  v_access_override boolean;
  v_trial_ends_at timestamptz;
  v_past_due_since timestamptz;
  v_effective_access boolean;
  v_request_path text := coalesce(current_setting('request.path', true), '');
  v_aal text := coalesce((select auth.jwt() ->> 'aal'), 'aal1');
begin
  if auth.uid() is null then return; end if;

  select exists (
    select 1
    from public.platform_support_users support_user
    where support_user.user_id = auth.uid()
      and support_user.active is true
  ) into v_is_support;

  select
    coalesce(profile.active, true),
    lower(coalesce(profile.role, '')),
    lower(coalesce(subscription.status, '')),
    coalesce(subscription.access_enabled, false),
    subscription.access_override,
    subscription.trial_ends_at,
    subscription.past_due_since,
    subscription.company_id is not null
  into
    v_profile_active,
    v_role,
    v_status,
    v_access_enabled,
    v_access_override,
    v_trial_ends_at,
    v_past_due_since,
    v_subscription_found
  from public.profiles profile
  left join public.company_subscriptions subscription
    on subscription.company_id = profile.company_id
  where profile.id = auth.uid();
  v_has_profile := found;

  -- Brand-new authenticated users must be able to create their profile/company.
  if not v_has_profile and not v_is_support then return; end if;

  if v_has_profile and v_profile_active is not true then
    raise exception using errcode = '42501',
      message = 'LineCrew profile access is inactive.';
  end if;

  -- MFA bootstrap must remain reachable even when company access is inactive.
  if v_request_path = '/rpc/linecrew_mfa_bootstrap_identity' then return; end if;

  if (v_is_support or v_role in ('owner', 'admin')) and v_aal <> 'aal2' then
    raise exception using errcode = '42501',
      message = 'Authenticator verification is required for privileged access.',
      hint = 'Complete the LineCrew Pro authenticator challenge and retry.';
  end if;

  -- The billing summary is the sole Data API recovery surface for a blocked
  -- company. Its SECURITY DEFINER body independently requires Owner/Admin.
  if v_request_path = '/rpc/my_company_billing_summary' then return; end if;

  if v_has_profile then
    if v_access_override is not null then
      v_effective_access := v_access_override;
    else
      v_effective_access := v_subscription_found
        and v_access_enabled
        and (
          v_status = 'active'
          or (
            v_status = 'trialing'
            and v_trial_ends_at is not null
            and v_trial_ends_at > now()
          )
          or (
            v_status = 'past_due'
            and v_past_due_since is not null
            and v_past_due_since > now() - interval '7 days'
          )
        );
    end if;

    if v_effective_access is not true then
      raise exception using errcode = '42501',
        message = 'LineCrew company access is inactive.';
    end if;
  end if;
end;
$$;

revoke all on function public.enforce_linecrew_company_access()
  from public, anon, authenticated;
grant execute on function public.enforce_linecrew_company_access()
  to authenticated, service_role;

-- Keep the browser-visible access summary aligned with the same fail-closed
-- rules used by the pre-request gate.
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
set search_path = ''
stable
as $$
declare
  v_company_id uuid;
begin
  select p.company_id into v_company_id
  from public.profiles p
  where p.id = auth.uid() and coalesce(p.active, true) = true;

  if v_company_id is null then return; end if;

  return query
  select
    cs.company_id,
    cs.plan_code,
    cs.status,
    case
      when cs.access_override is not null then cs.access_override
      else cs.access_enabled and (
        cs.status = 'active'
        or (cs.status = 'trialing' and cs.trial_ends_at is not null and cs.trial_ends_at > now())
        or (cs.status = 'past_due' and cs.past_due_since is not null and cs.past_due_since > now() - interval '7 days')
      )
    end,
    cs.trial_ends_at,
    cs.current_period_end
  from public.company_subscriptions cs
  where cs.company_id = v_company_id;
end;
$$;

revoke all on function public.my_company_subscription_access()
  from public, anon;
grant execute on function public.my_company_subscription_access()
  to authenticated;

-- H-1: the documented Owner role has the same company billing authority as
-- Admin. Keep the summary's effective-access calculation fail closed.
drop function if exists public.my_company_billing_summary();
create function public.my_company_billing_summary()
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
  stripe_subscription_linked boolean,
  included_crew_limit integer,
  rolling_peak_billable_crews integer,
  rolling_overage_crew_days integer,
  crew_overage_status text,
  recommended_plan_code text,
  company_name text,
  contact_email text
)
language plpgsql
security definer
set search_path = ''
stable
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  select p.company_id, lower(coalesce(p.role,'')), coalesce(p.active,true)
    into v_company_id, v_role, v_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or not v_active or v_role not in ('owner','admin') then
    raise exception 'Company Owner or Admin access required'
      using errcode = '42501';
  end if;

  return query
  select
    cs.plan_code,
    cs.monthly_price_cents,
    cs.currency,
    cs.status,
    case
      when cs.access_override is not null then cs.access_override
      else cs.access_enabled and (
        cs.status = 'active'
        or (cs.status = 'trialing' and cs.trial_ends_at is not null and cs.trial_ends_at > now())
        or (cs.status = 'past_due' and cs.past_due_since is not null and cs.past_due_since > now() - interval '7 days')
      )
    end,
    cs.provider,
    cs.trial_ends_at,
    cs.current_period_end,
    cs.cancel_at_period_end,
    cs.stripe_customer_id is not null,
    cs.stripe_subscription_id is not null,
    cs.included_crew_limit,
    coalesce(cs.rolling_peak_billable_crews,0),
    coalesce(cs.rolling_overage_crew_days,0),
    coalesce(cs.crew_overage_status,'within_plan'),
    coalesce(cs.recommended_plan_code,cs.plan_code),
    c.name,
    c.contact_email
  from public.companies c
  join public.company_subscriptions cs on cs.company_id = c.id
  where c.id = v_company_id;
end;
$$;

revoke all on function public.my_company_billing_summary()
  from public, anon;
grant execute on function public.my_company_billing_summary()
  to authenticated;

commit;
