-- Extract the authoritative company-level billing predicate from the Data API
-- request gate. This intentionally does not include profile, MFA, support-user,
-- or request-path logic.
create or replace function public.linecrew_company_access_enabled(p_company_id uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $function$
  select coalesce((
    select case
      when subscription.access_override is not null then subscription.access_override
      else coalesce(subscription.access_enabled, false) and (
        lower(coalesce(subscription.status, '')) = 'active'
        or (
          lower(coalesce(subscription.status, '')) = 'trialing'
          and subscription.trial_ends_at is not null
          and subscription.trial_ends_at > now()
        )
        or (
          lower(coalesce(subscription.status, '')) = 'past_due'
          and subscription.past_due_since is not null
          and subscription.past_due_since > now() - interval '7 days'
        )
      )
    end
    from public.company_subscriptions subscription
    where subscription.company_id = p_company_id
  ), false);
$function$;

revoke all on function public.linecrew_company_access_enabled(uuid)
  from public, anon, authenticated, service_role;

create or replace function public.my_company_subscription_access()
returns table(
  company_id uuid,
  plan_code text,
  status text,
  access_enabled boolean,
  trial_ends_at timestamptz,
  current_period_end timestamptz
)
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_company_id uuid;
begin
  select profile.company_id into v_company_id
  from public.profiles profile
  where profile.id = auth.uid()
    and coalesce(profile.active, true) = true;

  if v_company_id is null then return; end if;

  return query
  select
    subscription.company_id,
    subscription.plan_code,
    subscription.status,
    public.linecrew_company_access_enabled(subscription.company_id),
    subscription.trial_ends_at,
    subscription.current_period_end
  from public.company_subscriptions subscription
  where subscription.company_id = v_company_id;
end;
$function$;

-- Deliberately do not alter this existing function's ACL. CREATE OR REPLACE
-- preserves the caller environment byte-for-byte: production remains
-- service_role-only, while the known test ACL drift is left for the separate
-- billing cleanup that owns its browser and CI callers.

create or replace function public.enforce_linecrew_company_access()
returns void
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_company_id uuid;
  v_profile_active boolean;
  v_role text;
  v_is_support boolean;
  v_has_profile boolean;
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
    profile.company_id,
    coalesce(profile.active, true),
    lower(coalesce(profile.role, ''))
  into
    v_company_id,
    v_profile_active,
    v_role
  from public.profiles profile
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
    v_effective_access := public.linecrew_company_access_enabled(v_company_id);
    if v_effective_access is not true then
      raise exception using errcode = '42501',
        message = 'LineCrew company access is inactive.';
    end if;
  end if;
end;
$function$;
