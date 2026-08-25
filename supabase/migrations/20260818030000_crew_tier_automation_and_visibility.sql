begin;

-- Track the true peak non-storm crew count independently from the legacy
-- generated billable_peak_crews expression. This avoids a later Storm Mode
-- change rewriting the meaning of an earlier daily peak.
alter table public.company_crew_usage_daily
  add column if not exists peak_billable_crews integer not null default 0
    check (peak_billable_crews >= 0);

alter table public.company_subscriptions
  add column if not exists rolling_peak_billable_crews integer not null default 0,
  add column if not exists recommended_plan_code text;

create or replace function public.recommended_crew_plan(p_peak_crews integer)
returns text
language sql
immutable
as $$
  select case
    when coalesce(p_peak_crews,0) <= 5 then 'starter'
    when p_peak_crews <= 10 then 'business'
    when p_peak_crews <= 20 then 'pro'
    when p_peak_crews <= 40 then 'enterprise'
    else 'custom'
  end;
$$;

create or replace function public.capture_company_crew_usage(p_company_id uuid, p_usage_date date default current_date)
returns table(active_crews integer, storm_crews integer, billable_crews integer)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_active integer;
  v_storm integer;
  v_billable integer;
  v_storm_mode boolean;
begin
  if p_company_id is null then
    return;
  end if;

  select coalesce(c.storm_mode_enabled,false)
  into v_storm_mode
  from public.companies c
  where c.id = p_company_id;

  if not found then
    return;
  end if;

  select count(*)::integer
  into v_active
  from public.crews c
  where c.company_id = p_company_id
    and coalesce(c.active,true) = true;

  if v_storm_mode then
    select count(*)::integer
    into v_storm
    from public.crews c
    where c.company_id = p_company_id
      and coalesce(c.active,true) = true
      and c.foreman_id is not null
      and exists (
        select 1
        from public.storm_mode_assignments a
        where a.company_id = p_company_id
          and a.user_id = c.foreman_id
      );
  else
    v_storm := 0;
  end if;

  v_billable := greatest(v_active - v_storm,0);

  insert into public.company_crew_usage_daily(
    company_id, usage_date, peak_active_crews, storm_crews, peak_billable_crews, recorded_at
  ) values (
    p_company_id, coalesce(p_usage_date,current_date), v_active, v_storm, v_billable, now()
  )
  on conflict (company_id, usage_date) do update set
    peak_active_crews = greatest(public.company_crew_usage_daily.peak_active_crews, excluded.peak_active_crews),
    storm_crews = greatest(public.company_crew_usage_daily.storm_crews, excluded.storm_crews),
    peak_billable_crews = greatest(public.company_crew_usage_daily.peak_billable_crews, excluded.peak_billable_crews),
    recorded_at = now();

  return query select v_active, v_storm, v_billable;
end;
$$;

revoke all on function public.capture_company_crew_usage(uuid,date) from public, anon, authenticated;
grant execute on function public.capture_company_crew_usage(uuid,date) to service_role;

create or replace function public.capture_all_company_crew_usage(p_usage_date date default current_date)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company record;
  v_count integer := 0;
begin
  for v_company in select c.id from public.companies c loop
    perform public.capture_company_crew_usage(v_company.id, coalesce(p_usage_date,current_date));
    perform public.recalculate_company_crew_overage(v_company.id);
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

revoke all on function public.capture_all_company_crew_usage(date) from public, anon, authenticated;
grant execute on function public.capture_all_company_crew_usage(date) to service_role;

create or replace function public.recalculate_company_crew_overage(p_company_id uuid)
returns table(
  plan_code text,
  included_crews integer,
  rolling_overage_crew_days integer,
  overage_status text,
  recommended_plan text
)
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
  select lower(coalesce(subscription.plan_code,'pilot'))
  into v_plan
  from public.company_subscriptions subscription
  where subscription.company_id = p_company_id;

  if v_plan is null then
    raise exception 'Subscription not found';
  end if;

  v_limit := public.plan_crew_limit(v_plan);

  select
    coalesce(sum(greatest(usage.peak_billable_crews - coalesce(v_limit,0), 0)),0)::integer,
    coalesce(max(usage.peak_billable_crews),0)::integer
  into v_overage, v_peak
  from public.company_crew_usage_daily usage
  where usage.company_id = p_company_id
    and usage.usage_date >= current_date - 29;

  if v_plan = 'pilot' then
    v_status := 'within_plan';
    v_recommended := 'pilot';
    v_overage := 0;
  elsif v_plan = 'custom' then
    v_status := 'within_plan';
    v_recommended := 'custom';
    v_overage := 0;
  elsif v_limit is null then
    v_status := 'custom_quote_required';
    v_recommended := 'custom';
  elsif v_peak > 40 then
    v_status := 'custom_quote_required';
    v_recommended := 'custom';
  elsif v_overage = 0 then
    v_status := 'within_plan';
    v_recommended := v_plan;
  elsif v_overage <= 6 then
    v_status := 'grace';
    v_recommended := v_plan;
  else
    v_status := 'upgrade_required';
    v_recommended := public.recommended_crew_plan(v_peak);
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

revoke all on function public.recalculate_company_crew_overage(uuid) from public, anon, authenticated;
grant execute on function public.recalculate_company_crew_overage(uuid) to service_role;

-- Capture usage automatically whenever crew/storm configuration changes.
create or replace function public.capture_crew_usage_from_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old_company uuid;
  v_new_company uuid;
begin
  v_old_company := case when tg_op in ('UPDATE','DELETE') then old.company_id else null end;
  v_new_company := case when tg_op in ('INSERT','UPDATE') then new.company_id else null end;

  if v_old_company is not null then
    perform public.capture_company_crew_usage(v_old_company,current_date);
    perform public.recalculate_company_crew_overage(v_old_company);
  end if;
  if v_new_company is not null and v_new_company is distinct from v_old_company then
    perform public.capture_company_crew_usage(v_new_company,current_date);
    perform public.recalculate_company_crew_overage(v_new_company);
  end if;
  return coalesce(new,old);
end;
$$;

revoke all on function public.capture_crew_usage_from_change() from public, anon, authenticated;

drop trigger if exists linecrew_capture_crew_usage on public.crews;
create trigger linecrew_capture_crew_usage
after insert or update of active,foreman_id,company_id or delete on public.crews
for each row execute function public.capture_crew_usage_from_change();

drop trigger if exists linecrew_capture_storm_assignment_usage on public.storm_mode_assignments;
create trigger linecrew_capture_storm_assignment_usage
after insert or update or delete on public.storm_mode_assignments
for each row execute function public.capture_crew_usage_from_change();

create or replace function public.capture_company_storm_toggle_usage()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.capture_company_crew_usage(new.id,current_date);
  perform public.recalculate_company_crew_overage(new.id);
  return new;
end;
$$;

revoke all on function public.capture_company_storm_toggle_usage() from public, anon, authenticated;

drop trigger if exists linecrew_capture_storm_toggle_usage on public.companies;
create trigger linecrew_capture_storm_toggle_usage
after update of storm_mode_enabled on public.companies
for each row
when (old.storm_mode_enabled is distinct from new.storm_mode_enabled)
execute function public.capture_company_storm_toggle_usage();

-- Seed today's snapshot. A daily service-role call to capture_all_company_crew_usage()
-- keeps charging based on sustained over-limit use even on days with no crew edits.
select public.capture_all_company_crew_usage(current_date);

-- Extend owner dashboard with crew-plan health. Return signature changes require drop/recreate.
drop function if exists public.platform_owner_company_dashboard();
create function public.platform_owner_company_dashboard()
returns table (
  company_id uuid,
  company_name text,
  contact_email text,
  company_created_at timestamptz,
  active_users bigint,
  active_jobs bigint,
  total_reports bigint,
  last_report_at timestamptz,
  active_crews bigint,
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
  included_crew_limit integer,
  rolling_peak_billable_crews integer,
  rolling_overage_crew_days integer,
  crew_overage_status text,
  recommended_plan_code text,
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
    (select count(*) from public.profiles p where p.company_id = c.id and coalesce(p.active,true)=true),
    (select count(*) from public.jobs j where j.company_id = c.id and coalesce(j.active,true)=true),
    (select count(*) from public.daily_reports dr where dr.company_id = c.id),
    (select max(dr.created_at) from public.daily_reports dr where dr.company_id = c.id),
    (select count(*) from public.crews cr where cr.company_id = c.id and coalesce(cr.active,true)=true),
    coalesce(cs.plan_code,'pilot'),
    coalesce(cs.monthly_price_cents,0),
    coalesce(cs.status,'trialing'),
    coalesce(cs.access_override,cs.access_enabled,true),
    cs.access_override,
    cs.trial_ends_at,
    cs.current_period_end,
    coalesce(cs.cancel_at_period_end,false),
    coalesce(cs.provider,'manual'),
    cs.stripe_customer_id is not null,
    cs.stripe_subscription_id is not null,
    cs.included_crew_limit,
    coalesce(cs.rolling_peak_billable_crews,0),
    coalesce(cs.rolling_overage_crew_days,0),
    coalesce(cs.crew_overage_status,'within_plan'),
    coalesce(cs.recommended_plan_code,cs.plan_code,'pilot'),
    cs.notes
  from public.companies c
  left join public.company_subscriptions cs on cs.company_id = c.id
  order by lower(c.name),c.created_at;
end;
$$;
revoke all on function public.platform_owner_company_dashboard() from public,anon;
grant execute on function public.platform_owner_company_dashboard() to authenticated;

-- Extend contractor Admin billing summary with crew-tier state.
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
  recommended_plan_code text
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
  select p.company_id,lower(coalesce(p.role,'')),coalesce(p.active,true)
  into v_company_id,v_role,v_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or not v_active or v_role <> 'admin' then
    raise exception 'Company Admin access required';
  end if;

  return query
  select
    coalesce(cs.plan_code,'pilot'),
    coalesce(cs.monthly_price_cents,0),
    coalesce(cs.currency,'usd'),
    coalesce(cs.status,'trialing'),
    coalesce(cs.access_override,cs.access_enabled,true),
    coalesce(cs.provider,'manual'),
    cs.trial_ends_at,
    cs.current_period_end,
    coalesce(cs.cancel_at_period_end,false),
    cs.stripe_customer_id is not null,
    cs.stripe_subscription_id is not null,
    cs.included_crew_limit,
    coalesce(cs.rolling_peak_billable_crews,0),
    coalesce(cs.rolling_overage_crew_days,0),
    coalesce(cs.crew_overage_status,'within_plan'),
    coalesce(cs.recommended_plan_code,cs.plan_code,'pilot')
  from (select 1) x
  left join public.company_subscriptions cs on cs.company_id = v_company_id;
end;
$$;
revoke all on function public.my_company_billing_summary() from public,anon;
grant execute on function public.my_company_billing_summary() to authenticated;

-- Enforce approved list pricing for manual known tiers. Stripe-linked live plans remain
-- immutable here; their price/plan must be changed through a Stripe subscription flow.
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
  v_stripe_subscription_id text;
  v_existing_status text;
  v_base_access boolean;
  v_plan text;
  v_effective_price integer;
begin
  if not public.is_platform_owner() then raise exception 'Platform owner access required'; end if;
  if p_monthly_price_cents < 0 then raise exception 'Monthly price cannot be negative'; end if;
  if p_status not in ('trialing','active','past_due','paused','canceled','incomplete') then raise exception 'Invalid subscription status'; end if;
  if not exists(select 1 from public.companies c where c.id=p_company_id) then raise exception 'Company not found'; end if;

  v_plan := lower(coalesce(nullif(trim(p_plan_code),''),'custom'));
  if v_plan not in ('pilot','starter','business','pro','enterprise','custom') then
    raise exception 'Invalid plan code';
  end if;
  v_effective_price := case
    when v_plan='pilot' then 0
    when v_plan='custom' then p_monthly_price_cents
    else public.plan_monthly_cents(v_plan)
  end;

  select to_jsonb(cs),cs.provider,cs.stripe_subscription_id,cs.status
  into v_before,v_provider,v_stripe_subscription_id,v_existing_status
  from public.company_subscriptions cs where cs.company_id=p_company_id;

  v_base_access := p_status in ('trialing','active','past_due');

  if v_provider='stripe' and v_stripe_subscription_id is not null and coalesce(v_existing_status,'')<>'canceled' then
    update public.company_subscriptions cs
    set access_override=p_access_override,notes=p_notes,updated_at=now()
    where cs.company_id=p_company_id returning cs.* into result;
  else
    insert into public.company_subscriptions(
      company_id,plan_code,monthly_price_cents,status,access_enabled,access_override,trial_ends_at,notes,provider,updated_at,included_crew_limit
    ) values (
      p_company_id,v_plan,v_effective_price,p_status,v_base_access,p_access_override,p_trial_ends_at,p_notes,'manual',now(),public.plan_crew_limit(v_plan)
    )
    on conflict(company_id) do update set
      plan_code=excluded.plan_code,
      monthly_price_cents=excluded.monthly_price_cents,
      status=excluded.status,
      access_enabled=excluded.access_enabled,
      access_override=excluded.access_override,
      trial_ends_at=excluded.trial_ends_at,
      notes=excluded.notes,
      provider='manual',
      included_crew_limit=excluded.included_crew_limit,
      updated_at=now()
    returning * into result;
  end if;

  perform public.recalculate_company_crew_overage(p_company_id);
  select * into result from public.company_subscriptions cs where cs.company_id=p_company_id;

  insert into public.platform_owner_audit_events(actor_user_id,company_id,action,before_state,after_state)
  values(auth.uid(),p_company_id,'subscription_settings_updated',v_before,to_jsonb(result));
  return result;
end;
$$;
revoke all on function public.platform_owner_set_subscription(uuid,text,integer,text,boolean,timestamptz,text) from public,anon;
grant execute on function public.platform_owner_set_subscription(uuid,text,integer,text,boolean,timestamptz,text) to authenticated;

comment on function public.capture_all_company_crew_usage(date) is
'Call once daily with service_role. Triggers capture in-day changes; this daily snapshot makes sustained over-limit use accumulate even when no crew records change.';

commit;
