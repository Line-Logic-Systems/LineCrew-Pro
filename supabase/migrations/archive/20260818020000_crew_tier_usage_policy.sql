begin;

create table if not exists public.company_crew_usage_daily (
  company_id uuid not null references public.companies(id) on delete cascade,
  usage_date date not null,
  peak_active_crews integer not null default 0 check (peak_active_crews >= 0),
  storm_crews integer not null default 0 check (storm_crews >= 0),
  billable_peak_crews integer generated always as (greatest(peak_active_crews - storm_crews, 0)) stored,
  recorded_at timestamptz not null default now(),
  primary key (company_id, usage_date)
);

alter table public.company_crew_usage_daily enable row level security;
revoke all on public.company_crew_usage_daily from anon, authenticated;

alter table public.company_subscriptions
  add column if not exists included_crew_limit integer,
  add column if not exists rolling_overage_crew_days integer not null default 0,
  add column if not exists crew_overage_status text not null default 'within_plan'
    check (crew_overage_status in ('within_plan','grace','upgrade_required','custom_quote_required')),
  add column if not exists crew_overage_updated_at timestamptz;

create or replace function public.plan_crew_limit(p_plan_code text)
returns integer
language sql
immutable
as $$
  select case lower(coalesce(p_plan_code,''))
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
as $$
  select case lower(coalesce(p_plan_code,''))
    when 'starter' then 49900
    when 'business' then 74900
    when 'pro' then 119900
    when 'enterprise' then 179900
    else null
  end;
$$;

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
  select lower(coalesce(subscription.plan_code,'starter'))
  into v_plan
  from public.company_subscriptions subscription
  where subscription.company_id = p_company_id;

  if v_plan is null then
    raise exception 'Subscription not found';
  end if;

  v_limit := public.plan_crew_limit(v_plan);

  select
    coalesce(sum(greatest(usage.billable_peak_crews - coalesce(v_limit,0), 0)),0)::integer,
    coalesce(max(usage.billable_peak_crews),0)::integer
  into v_overage, v_peak
  from public.company_crew_usage_daily usage
  where usage.company_id = p_company_id
    and usage.usage_date >= current_date - 29;

  if v_limit is null then
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
    v_recommended := case
      when v_peak <= 5 then 'starter'
      when v_peak <= 10 then 'business'
      when v_peak <= 20 then 'pro'
      when v_peak <= 40 then 'enterprise'
      else 'custom'
    end;
  end if;

  update public.company_subscriptions subscription
  set included_crew_limit = v_limit,
      rolling_overage_crew_days = v_overage,
      crew_overage_status = v_status,
      crew_overage_updated_at = now(),
      updated_at = now()
  where subscription.company_id = p_company_id;

  return query select v_plan, v_limit, v_overage, v_status, v_recommended;
end;
$$;

revoke all on function public.recalculate_company_crew_overage(uuid) from public, anon, authenticated;
grant execute on function public.recalculate_company_crew_overage(uuid) to service_role;

comment on table public.company_crew_usage_daily is
'One row per company/calendar day. Overage uses peak non-storm active crews. Rolling allowance is six over-limit crew-days in the latest 30 days; taking crews off does not reset prior usage.';

comment on column public.company_crew_usage_daily.storm_crews is
'Crews explicitly designated for Storm Mode that day; excluded from normal subscription crew overage calculations.';

commit;
