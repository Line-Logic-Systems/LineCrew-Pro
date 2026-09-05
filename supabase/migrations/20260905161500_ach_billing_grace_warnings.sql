-- ACH Direct Debit support: surface the grace clock and warn before lockout.
--
-- ACH takes up to four business days to confirm. Stripe starts a bank-debit
-- subscription as `active` while the debit processes and moves it to
-- `past_due` if it fails, so the existing seven-day grace in
-- enforce_linecrew_company_access already covers the failure case and is not
-- changed here. What was missing is any warning at all: a company whose
-- payment failed learned about it only by being locked out on day seven.
--
-- The warnings key off subscription status rather than payment method, so a
-- failed card is warned exactly the same way.

-- 1. my_company_billing_summary must return past_due_since so Company Billing
--    can render the countdown. Postgres cannot alter a return signature in
--    place, so the function is dropped and recreated unchanged apart from the
--    new trailing column.

drop function if exists public.my_company_billing_summary();

create function public.my_company_billing_summary() returns table(plan_code text, monthly_price_cents integer, currency text, status text, access_enabled boolean, provider text, trial_ends_at timestamp with time zone, current_period_end timestamp with time zone, cancel_at_period_end boolean, stripe_customer_linked boolean, stripe_subscription_linked boolean, included_crew_limit integer, rolling_peak_billable_crews integer, rolling_overage_crew_days integer, crew_overage_status text, recommended_plan_code text, company_name text, contact_email text, past_due_since timestamp with time zone)
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
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
    c.contact_email,
    cs.past_due_since
  from public.companies c
  join public.company_subscriptions cs on cs.company_id = c.id
  where c.id = v_company_id;
end;
$$;

revoke all on function public.my_company_billing_summary() from public;
grant all on function public.my_company_billing_summary() to authenticated;
grant all on function public.my_company_billing_summary() to service_role;

-- 2. Warn every Owner and Admin of a past-due company on days 3, 5 and 6 of
--    the seven-day grace. Access ends on day 7.
--
--    linecrew_enqueue_push_notification de-duplicates on event_key, so this is
--    safe to call on every pass of the one-minute push dispatcher: the day
--    marker and the past_due_since timestamp together make each warning fire
--    exactly once. A company that fails, pays, then fails again gets a new
--    past_due_since and therefore a fresh set of keys.

create or replace function public.linecrew_enqueue_billing_grace_warnings()
returns integer
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_company record;
  v_recipient record;
  v_elapsed_days integer;
  v_days_left integer;
  v_body text;
  v_count_before bigint;
  v_count_after bigint;
begin
  select count(*) into v_count_before from public.push_notification_outbox;

  for v_company in
    select cs.company_id, cs.past_due_since
    from public.company_subscriptions cs
    where cs.status = 'past_due'
      and cs.past_due_since is not null
      and cs.past_due_since > now() - interval '7 days'
  loop
    v_elapsed_days := floor(extract(epoch from (now() - v_company.past_due_since)) / 86400)::integer;
    continue when v_elapsed_days not in (3, 5, 6);

    v_days_left := 7 - v_elapsed_days;
    v_body := case
      when v_days_left = 1 then
        'Payment failed. LineCrew Pro access ends tomorrow. Your crews, jobs and history stay in place - update payment in Company Billing.'
      else
        'Payment failed. LineCrew Pro access ends in ' || v_days_left ||
        ' days. Your crews, jobs and history stay in place - update payment in Company Billing.'
    end;

    for v_recipient in
      select profile.id
      from public.profiles profile
      where profile.company_id = v_company.company_id
        and profile.active is true
        and lower(coalesce(profile.role, '')) in ('owner', 'admin')
    loop
      perform public.linecrew_enqueue_push_notification(
        v_company.company_id,
        v_recipient.id,
        'billing-grace-d' || v_elapsed_days || ':' || v_company.company_id::text
          || ':' || to_char(v_company.past_due_since at time zone 'UTC', 'YYYYMMDDHH24MISS'),
        'billing_grace_warning',
        null::uuid,
        v_body,
        '/billing.html',
        'billing-grace'
      );
    end loop;
  end loop;

  select count(*) into v_count_after from public.push_notification_outbox;
  return greatest(0, (v_count_after - v_count_before))::integer;
end;
$$;

revoke all on function public.linecrew_enqueue_billing_grace_warnings() from public, anon, authenticated;
grant execute on function public.linecrew_enqueue_billing_grace_warnings() to service_role;
