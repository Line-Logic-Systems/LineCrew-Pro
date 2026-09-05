-- Replace fixed crew tiers with one licensed-crew subscription.
-- $599/month includes five active crew slots; every additional slot is $85/month.

create or replace function public.linecrew_monthly_cents(p_crew_limit integer)
returns integer
language sql
immutable
set search_path = ''
as $$
  select case
    when p_crew_limit is null or p_crew_limit < 5 then null
    else 59900 + ((p_crew_limit - 5) * 8500)
  end;
$$;

create or replace function public.plan_crew_limit(p_plan_code text)
returns integer
language sql
immutable
set search_path = ''
as $$
  select case lower(coalesce(p_plan_code,''))
    when 'pilot' then 5
    when 'linecrew' then 5
    when 'starter' then 5
    when 'business' then 10
    when 'pro' then 20
    when 'enterprise' then 40
    else null
  end;
$$;

create or replace function public.plan_monthly_cents(p_plan_code text)
returns integer
language sql
immutable
set search_path = ''
as $$
  select case lower(coalesce(p_plan_code,''))
    when 'linecrew' then 59900
    when 'starter' then 49900
    when 'business' then 74900
    when 'pro' then 119900
    when 'enterprise' then 179900
    else null
  end;
$$;

create or replace function public.recommended_crew_plan(p_peak_crews integer)
returns text
language sql
immutable
set search_path = ''
as $$ select 'linecrew'::text; $$;

create or replace function public.recalculate_company_crew_overage(p_company_id uuid)
returns table(plan_code text, included_crews integer, rolling_overage_crew_days integer, overage_status text, recommended_plan text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_plan text;
  v_limit integer;
  v_overage integer;
  v_peak integer;
  v_status text;
  v_recommended text;
begin
  select lower(coalesce(subscription.plan_code,'pilot')),
         coalesce(subscription.included_crew_limit, public.plan_crew_limit(subscription.plan_code))
    into v_plan, v_limit
  from public.company_subscriptions subscription
  where subscription.company_id = p_company_id;

  if v_plan is null then raise exception 'Subscription not found'; end if;

  select coalesce(sum(greatest(usage.peak_billable_crews - coalesce(v_limit,0), 0)),0)::integer,
         coalesce(max(usage.peak_billable_crews),0)::integer
    into v_overage, v_peak
  from public.company_crew_usage_daily usage
  where usage.company_id = p_company_id
    and usage.usage_date >= current_date - 29;

  if v_plan in ('pilot','custom') then
    v_status := 'within_plan';
    v_recommended := v_plan;
    v_overage := 0;
  elsif v_limit is null then
    v_status := 'upgrade_required';
    v_recommended := 'linecrew';
  elsif v_overage = 0 then
    v_status := 'within_plan';
    v_recommended := v_plan;
  elsif v_overage <= 6 then
    v_status := 'grace';
    v_recommended := 'linecrew';
  else
    v_status := 'upgrade_required';
    v_recommended := 'linecrew';
  end if;

  update public.company_subscriptions subscription
  set included_crew_limit = v_limit,
      rolling_overage_crew_days = v_overage,
      rolling_peak_billable_crews = v_peak,
      crew_overage_status = v_status,
      recommended_plan_code = v_recommended,
      crew_overage_updated_at = now(),
      updated_at = now()
  where subscription.company_id = p_company_id;

  return query select v_plan, v_limit, v_overage, v_status, v_recommended;
end;
$$;

drop function if exists public.platform_owner_set_subscription(uuid,text,integer,text,boolean,timestamptz,text);

create function public.platform_owner_set_subscription(
  p_company_id uuid,
  p_plan_code text,
  p_monthly_price_cents integer,
  p_status text,
  p_access_override boolean default null,
  p_trial_ends_at timestamptz default null,
  p_notes text default null,
  p_included_crew_limit integer default 5
)
returns public.company_subscriptions
language plpgsql
security definer
set search_path = 'public'
as $$
declare
  result public.company_subscriptions;
  v_before jsonb;
  v_provider text;
  v_stripe_subscription_id text;
  v_existing_status text;
  v_plan text;
  v_limit integer;
  v_price integer;
begin
  if not public.is_platform_owner() then raise exception 'Platform owner access required'; end if;
  if p_status not in ('trialing','active','past_due','paused','canceled','incomplete') then raise exception 'Invalid subscription status'; end if;
  if not exists(select 1 from public.companies c where c.id=p_company_id) then raise exception 'Company not found'; end if;

  v_plan := lower(coalesce(nullif(trim(p_plan_code),''),'linecrew'));
  if v_plan not in ('pilot','linecrew') then raise exception 'Invalid plan code'; end if;
  v_limit := case when v_plan='pilot' then 5 else greatest(5,coalesce(p_included_crew_limit,5)) end;
  v_price := case when v_plan='pilot' then 0 else public.linecrew_monthly_cents(v_limit) end;

  select to_jsonb(cs),cs.provider,cs.stripe_subscription_id,cs.status
    into v_before,v_provider,v_stripe_subscription_id,v_existing_status
  from public.company_subscriptions cs where cs.company_id=p_company_id;

  if v_provider='stripe' and v_stripe_subscription_id is not null and coalesce(v_existing_status,'')<>'canceled' then
    update public.company_subscriptions cs
    set access_override=p_access_override,notes=p_notes,updated_at=now()
    where cs.company_id=p_company_id returning cs.* into result;
  else
    insert into public.company_subscriptions(
      company_id,plan_code,monthly_price_cents,status,access_enabled,access_override,trial_ends_at,notes,provider,updated_at,included_crew_limit
    ) values (
      p_company_id,v_plan,v_price,p_status,p_status in ('trialing','active','past_due'),p_access_override,p_trial_ends_at,p_notes,'manual',now(),v_limit
    )
    on conflict(company_id) do update set
      plan_code=excluded.plan_code,monthly_price_cents=excluded.monthly_price_cents,status=excluded.status,
      access_enabled=excluded.access_enabled,access_override=excluded.access_override,trial_ends_at=excluded.trial_ends_at,
      notes=excluded.notes,provider='manual',included_crew_limit=excluded.included_crew_limit,updated_at=now()
    returning * into result;
  end if;

  perform public.recalculate_company_crew_overage(p_company_id);
  select * into result from public.company_subscriptions cs where cs.company_id=p_company_id;
  insert into public.platform_owner_audit_events(actor_user_id,company_id,action,before_state,after_state)
  values(auth.uid(),p_company_id,'subscription_settings_updated',v_before,to_jsonb(result));
  return result;
end;
$$;

revoke all on function public.linecrew_monthly_cents(integer) from public;
grant execute on function public.linecrew_monthly_cents(integer) to authenticated, service_role;
revoke all on function public.platform_owner_set_subscription(uuid,text,integer,text,boolean,timestamptz,text,integer) from public;
grant execute on function public.platform_owner_set_subscription(uuid,text,integer,text,boolean,timestamptz,text,integer) to authenticated, service_role;

comment on function public.linecrew_monthly_cents(integer) is 'Monthly licensed-crew price: $599 for five crews plus $85 for each additional crew.';
