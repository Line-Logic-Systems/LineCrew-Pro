-- Cost guard for the Admin Assistant and lease-based Stripe webhook claims.

create table if not exists public.assistant_usage_monthly (
  company_id uuid not null references public.companies(id) on delete cascade,
  usage_month date not null,
  request_count integer not null default 0 check(request_count>=0),
  request_limit integer not null default 2000 check(request_limit between 1 and 100000),
  updated_at timestamptz not null default now(),
  primary key(company_id,usage_month)
);
alter table public.assistant_usage_monthly enable row level security;
revoke all on table public.assistant_usage_monthly from public,anon,authenticated;
grant all on table public.assistant_usage_monthly to service_role;

create or replace function public.consume_assistant_monthly_request()
returns table(allowed boolean,request_count integer,request_limit integer,usage_month date)
language plpgsql volatile security definer set search_path=''
as $$
declare v_company_id uuid; v_role text; v_active boolean; v_month date;
  v_count integer; v_limit integer;
begin
  select profile.company_id,lower(coalesce(profile.role,'')),profile.active
    into v_company_id,v_role,v_active from public.profiles profile where profile.id=auth.uid();
  if v_company_id is null or not v_active or v_role not in ('owner','manager','admin') then
    raise exception using errcode='42501',message='The LineCrew Assistant is not enabled for your role.';
  end if;
  v_month:=date_trunc('month',now() at time zone 'UTC')::date;
  insert into public.assistant_usage_monthly(company_id,usage_month,request_count)
  values(v_company_id,v_month,1)
  on conflict(company_id,usage_month) do update
    set request_count=assistant_usage_monthly.request_count+1,updated_at=now()
    where assistant_usage_monthly.request_count<assistant_usage_monthly.request_limit
  returning assistant_usage_monthly.request_count,assistant_usage_monthly.request_limit
    into v_count,v_limit;
  if not found then
    select usage.request_count,usage.request_limit into v_count,v_limit
    from public.assistant_usage_monthly usage
    where usage.company_id=v_company_id and usage.usage_month=v_month;
    return query select false,v_count,v_limit,v_month;
    return;
  end if;
  return query select true,v_count,v_limit,v_month;
end;
$$;
revoke all on function public.consume_assistant_monthly_request() from public,anon;
grant execute on function public.consume_assistant_monthly_request() to authenticated,service_role;

alter table public.billing_events
  add column if not exists processing_started_at timestamptz,
  add column if not exists processing_token uuid;
create index if not exists billing_events_unfinished_claim_idx
  on public.billing_events(processing_started_at)
  where processed_at is null;

-- These are API functions or trigger functions that must never be anonymously executable.
revoke execute on function public.get_daily_report_unit_locations_visible_v3(uuid) from public,anon;
revoke execute on function public.guard_approved_daily_report_hours() from public,anon;
revoke execute on function public.guard_approved_daily_report_timekeeping() from public,anon;
revoke execute on function public.linecrew_require_privileged_mfa_for_mutation() from public,anon;
revoke execute on function public.save_daily_report_unit_redline_comment(uuid,text) from public,anon;

comment on table public.assistant_usage_monthly is
  'Atomic company-level monthly request budget for cost-controlled LineCrew Assistant access.';

create or replace function public.get_job_jsas(p_job_id uuid,p_limit integer default 500,p_offset integer default 0)
returns table(id uuid,daily_report_id uuid,job_id uuid,job_number text,job_name text,work_date date,
  crew_name text,weather_conditions text,job_briefing text,hazards text,controls text,ppe text,
  emergency_plan text,crew_members text,special_equipment text,foreman_name text,
  acknowledged_at timestamptz,created_at timestamptz)
language plpgsql stable security definer set search_path=''
as $$
declare v_company_id uuid; v_role text; v_active boolean; v_limit integer;
begin
  select profile.company_id,lower(coalesce(profile.role,'')),profile.active
    into v_company_id,v_role,v_active from public.profiles profile where profile.id=auth.uid();
  if v_company_id is null or not v_active or v_role not in ('foreman','gf','admin','manager','owner','superintendent','safety') then
    raise exception using errcode='42501',message='You are not allowed to view JSAs.';
  end if;
  if v_role='superintendent' and not public.linecrew_has_capability('safety_records') then
    raise exception using errcode='42501',message='This Superintendent does not have safety records permission.';
  end if;
  if not exists(select 1 from public.jobs job where job.id=p_job_id and job.company_id=v_company_id) then
    raise exception using errcode='P0002',message='Job was not found in your company.';
  end if;
  v_limit:=least(greatest(coalesce(p_limit,500),1),500);
  return query select safety.id,safety.daily_report_id,safety.job_id,job.job_number,job.job_name,
    safety.work_date,safety.crew_name,safety.weather_conditions,safety.job_briefing,safety.hazards,
    safety.controls,safety.ppe,safety.emergency_plan,safety.crew_members,safety.special_equipment,
    coalesce(nullif(trim(profile.full_name),''),'Foreman'),safety.acknowledged_at,safety.created_at
  from public.daily_report_jsas safety
  join public.jobs job on job.id=safety.job_id and job.company_id=safety.company_id
  left join public.profiles profile on profile.id=safety.created_by and profile.company_id=safety.company_id
  where safety.company_id=v_company_id and safety.job_id=p_job_id
    and (v_role<>'foreman' or safety.created_by=auth.uid())
  order by safety.work_date desc,safety.created_at desc
  limit v_limit offset greatest(coalesce(p_offset,0),0);
end;
$$;
revoke all on function public.get_job_jsas(uuid,integer,integer) from public,anon;
grant execute on function public.get_job_jsas(uuid,integer,integer) to authenticated,service_role;

create or replace function public.get_job_billing_export_batches(p_job_id uuid)
returns setof public.billing_export_batches
language plpgsql stable security definer set search_path=''
as $$
declare v_company_id uuid; v_role text; v_active boolean;
begin
  select profile.company_id,lower(coalesce(profile.role,'')),profile.active
    into v_company_id,v_role,v_active from public.profiles profile where profile.id=auth.uid();
  if v_company_id is null or not v_active or v_role not in ('owner','manager','admin','superintendent') then
    raise exception using errcode='42501',message='Billing access is required.';
  end if;
  if v_role='superintendent' and (not public.linecrew_has_capability('reporting') or not public.linecrew_has_capability('actual_pricing')) then
    raise exception using errcode='42501',message='Reporting and Actual Pricing permissions are required.';
  end if;
  return query select batch.* from public.billing_export_batches batch
    where batch.company_id=v_company_id and batch.job_id=p_job_id order by batch.created_at desc;
end;
$$;
revoke all on function public.get_job_billing_export_batches(uuid) from public,anon;
grant execute on function public.get_job_billing_export_batches(uuid) to authenticated,service_role;
