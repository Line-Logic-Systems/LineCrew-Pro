begin;

-- Storm Event v2 is additive. Existing company storm flags and report tags stay
-- authoritative for the current app, while these tables preserve event history
-- and readiness without changing normal-production behavior.
create table if not exists public.storm_events (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  event_name text not null,
  status text not null default 'active'
    check (status in ('planned','active','closed','cancelled')),
  customer_id uuid references public.customers(id) on delete set null,
  contract_id uuid references public.contracts(id) on delete set null,
  location text,
  start_date date,
  expected_end_date date,
  ended_at timestamptz,
  time_policy text not null default 'record_only'
    check (time_policy in ('record_only','weekly_ot','straight_ot')),
  per_diem_policy text not null default 'manual'
    check (per_diem_policy in ('none','manual','daily')),
  default_per_diem_amount numeric(12,2)
    check (default_per_diem_amount is null or default_per_diem_amount >= 0),
  operations_notes text,
  created_by uuid not null references auth.users(id) on delete restrict default auth.uid(),
  updated_by uuid not null references auth.users(id) on delete restrict default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (expected_end_date is null or start_date is null or expected_end_date >= start_date)
);

create unique index if not exists storm_events_one_active_per_company_idx
  on public.storm_events(company_id) where status = 'active';
create index if not exists storm_events_company_history_idx
  on public.storm_events(company_id, created_at desc);
create index if not exists storm_events_customer_idx on public.storm_events(customer_id)
  where customer_id is not null;
create index if not exists storm_events_contract_idx on public.storm_events(contract_id)
  where contract_id is not null;

create table if not exists public.storm_event_crew_status (
  event_id uuid not null references public.storm_events(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  deployment_status text not null default 'assigned'
    check (deployment_status in ('assigned','mobilizing','onsite','standby','released')),
  current_location text,
  lodging text,
  readiness_notes text,
  last_check_in_at timestamptz,
  updated_by uuid not null references auth.users(id) on delete restrict default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (event_id, user_id)
);

create index if not exists storm_event_crew_company_status_idx
  on public.storm_event_crew_status(company_id, deployment_status, event_id);
create index if not exists storm_event_crew_user_idx
  on public.storm_event_crew_status(user_id, event_id);

create table if not exists public.storm_event_activity (
  id bigint generated always as identity primary key,
  event_id uuid not null references public.storm_events(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  actor_id uuid references auth.users(id) on delete set null,
  action text not null check (action in (
    'created','updated','activated','closed','cancelled',
    'crew_assigned','crew_released','crew_check_in'
  )),
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists storm_event_activity_event_idx
  on public.storm_event_activity(event_id, created_at desc);
create index if not exists storm_event_activity_company_idx
  on public.storm_event_activity(company_id, created_at desc);

alter table public.daily_reports
  add column if not exists storm_event_id uuid references public.storm_events(id) on delete set null;
alter table public.timekeeping_entries
  add column if not exists storm_event_id uuid references public.storm_events(id) on delete set null;
create index if not exists daily_reports_storm_event_idx
  on public.daily_reports(storm_event_id, work_date desc) where storm_event_id is not null;
create index if not exists timekeeping_entries_storm_event_idx
  on public.timekeeping_entries(storm_event_id, work_date desc) where storm_event_id is not null;

create or replace function public.apply_timekeeping_storm_event_context()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.daily_report_id is not null then
    select dr.storm_mode,dr.storm_event_id
      into new.storm_work,new.storm_event_id
    from public.daily_reports dr
    where dr.id=new.daily_report_id and dr.company_id=new.company_id;
  end if;
  return new;
end;
$$;

drop trigger if exists linecrew_timekeeping_storm_event_context on public.timekeeping_entries;
create trigger linecrew_timekeeping_storm_event_context
before insert or update of daily_report_id on public.timekeeping_entries
for each row execute function public.apply_timekeeping_storm_event_context();

alter table public.storm_events enable row level security;
alter table public.storm_event_crew_status enable row level security;
alter table public.storm_event_activity enable row level security;

revoke all on table public.storm_events from public, anon, authenticated;
revoke all on table public.storm_event_crew_status from public, anon, authenticated;
revoke all on table public.storm_event_activity from public, anon, authenticated;
grant select, insert, update, delete on table public.storm_events to service_role;
grant select, insert, update, delete on table public.storm_event_crew_status to service_role;
grant select, insert, update, delete on table public.storm_event_activity to service_role;
grant usage, select on sequence public.storm_event_activity_id_seq to service_role;

drop policy if exists server_only_no_direct_access on public.storm_events;
create policy server_only_no_direct_access on public.storm_events
  as restrictive for all using (false) with check (false);
drop policy if exists server_only_no_direct_access on public.storm_event_crew_status;
create policy server_only_no_direct_access on public.storm_event_crew_status
  as restrictive for all using (false) with check (false);
drop policy if exists server_only_no_direct_access on public.storm_event_activity;
create policy server_only_no_direct_access on public.storm_event_activity
  as restrictive for all using (false) with check (false);

-- Preserve an event that was already active before this migration landed.
insert into public.storm_events(
  company_id,event_name,status,start_date,created_by,updated_by,created_at,updated_at
)
select c.id,c.storm_event_name,'active',
  coalesce((c.storm_started_at at time zone c.timezone)::date,current_date),
  actor.id,actor.id,coalesce(c.storm_started_at,now()),now()
from public.companies c
cross join lateral (
  select p.id from public.profiles p
  where p.company_id=c.id and p.active is true and lower(p.role) in ('owner','admin')
  order by case lower(p.role) when 'owner' then 0 else 1 end,p.created_at
  limit 1
) actor
where c.storm_mode_enabled is true
  and length(btrim(coalesce(c.storm_event_name,'')))>0
  and not exists(select 1 from public.storm_events e where e.company_id=c.id and e.status='active')
on conflict do nothing;

insert into public.storm_event_crew_status(event_id,company_id,user_id,updated_by,created_at,updated_at)
select e.id,e.company_id,a.user_id,coalesce(a.assigned_by,e.updated_by),a.created_at,now()
from public.storm_events e
join public.storm_mode_assignments a on a.company_id=e.company_id
where e.status='active'
on conflict(event_id,user_id) do nothing;

create or replace function public.save_storm_event_workspace(
  p_enabled boolean,
  p_event_name text,
  p_customer_id uuid default null,
  p_contract_id uuid default null,
  p_location text default null,
  p_start_date date default null,
  p_expected_end_date date default null,
  p_time_policy text default 'record_only',
  p_per_diem_policy text default 'manual',
  p_default_per_diem_amount numeric default null,
  p_operations_notes text default null
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_event_id uuid;
  v_action text;
begin
  select p.company_id, lower(coalesce(p.role,''))
    into v_company_id, v_role
  from public.profiles p
  where p.id = auth.uid() and p.active is true;

  if v_company_id is null or v_role not in ('owner','admin','superintendent') then
    raise exception using errcode='42501', message='An active Owner, Admin, or permitted Superintendent is required.';
  end if;
  if v_role = 'superintendent' and not public.linecrew_has_capability('storm_mode') then
    raise exception using errcode='42501', message='This Superintendent does not have storm mode permission.';
  end if;
  if coalesce(p_enabled,false) and length(btrim(coalesce(p_event_name,''))) = 0 then
    raise exception using errcode='22023', message='A storm or event name is required.';
  end if;
  if p_time_policy not in ('record_only','weekly_ot','straight_ot') then
    raise exception using errcode='22023', message='Unsupported storm time policy.';
  end if;
  if p_per_diem_policy not in ('none','manual','daily') then
    raise exception using errcode='22023', message='Unsupported storm per diem policy.';
  end if;
  if p_default_per_diem_amount is not null and p_default_per_diem_amount < 0 then
    raise exception using errcode='22023', message='Per diem amount cannot be negative.';
  end if;
  if p_expected_end_date is not null and p_start_date is not null and p_expected_end_date < p_start_date then
    raise exception using errcode='22023', message='Expected end date cannot be before the start date.';
  end if;
  if p_customer_id is not null and not exists (
    select 1 from public.customers c where c.id=p_customer_id and c.company_id=v_company_id
  ) then
    raise exception using errcode='22023', message='The selected utility does not belong to this company.';
  end if;
  if p_contract_id is not null and not exists (
    select 1 from public.contracts c
    where c.id=p_contract_id and c.company_id=v_company_id
      and (p_customer_id is null or c.customer_id=p_customer_id)
  ) then
    raise exception using errcode='22023', message='The selected contract does not belong to this company or utility.';
  end if;

  select e.id into v_event_id
  from public.storm_events e
  where e.company_id=v_company_id and e.status='active'
  for update;

  if coalesce(p_enabled,false) then
    if v_event_id is null then
      insert into public.storm_events(
        company_id,event_name,status,customer_id,contract_id,location,start_date,
        expected_end_date,time_policy,per_diem_policy,default_per_diem_amount,
        operations_notes,created_by,updated_by
      ) values (
        v_company_id,btrim(p_event_name),'active',p_customer_id,p_contract_id,
        nullif(btrim(coalesce(p_location,'')),''),coalesce(p_start_date,current_date),
        p_expected_end_date,p_time_policy,p_per_diem_policy,p_default_per_diem_amount,
        nullif(btrim(coalesce(p_operations_notes,'')),''),auth.uid(),auth.uid()
      ) returning id into v_event_id;
      v_action := 'created';
    else
      update public.storm_events e set
        event_name=btrim(p_event_name), customer_id=p_customer_id,
        contract_id=p_contract_id, location=nullif(btrim(coalesce(p_location,'')),''),
        start_date=coalesce(p_start_date,e.start_date), expected_end_date=p_expected_end_date,
        time_policy=p_time_policy, per_diem_policy=p_per_diem_policy,
        default_per_diem_amount=p_default_per_diem_amount,
        operations_notes=nullif(btrim(coalesce(p_operations_notes,'')),''),
        updated_by=auth.uid(), updated_at=now()
      where e.id=v_event_id;
      v_action := 'updated';
    end if;

    insert into public.storm_event_crew_status(event_id,company_id,user_id,updated_by)
    select v_event_id,v_company_id,a.user_id,auth.uid()
    from public.storm_mode_assignments a
    where a.company_id=v_company_id
    on conflict(event_id,user_id) do update set
      deployment_status=case
        when public.storm_event_crew_status.deployment_status='released' then 'assigned'
        else public.storm_event_crew_status.deployment_status end,
      updated_by=auth.uid(),updated_at=now();

    update public.storm_event_crew_status s set
      deployment_status='released',updated_by=auth.uid(),updated_at=now()
    where s.event_id=v_event_id and s.company_id=v_company_id
      and not exists (
        select 1 from public.storm_mode_assignments a
        where a.company_id=v_company_id and a.user_id=s.user_id
      ) and s.deployment_status <> 'released';
  elsif v_event_id is not null then
    update public.storm_events set
      status='closed',ended_at=now(),updated_by=auth.uid(),updated_at=now()
    where id=v_event_id;
    update public.storm_event_crew_status set
      deployment_status='released',updated_by=auth.uid(),updated_at=now()
    where event_id=v_event_id and deployment_status <> 'released';
    v_action := 'closed';
  end if;

  if v_event_id is not null then
    insert into public.storm_event_activity(event_id,company_id,actor_id,action,details)
    values(v_event_id,v_company_id,auth.uid(),v_action,
      jsonb_build_object('event_name',btrim(coalesce(p_event_name,''))));
  end if;
  return v_event_id;
end;
$$;

create or replace function public.update_storm_crew_check_in(
  p_event_id uuid,
  p_user_id uuid,
  p_deployment_status text,
  p_current_location text default null,
  p_lodging text default null,
  p_readiness_notes text default null
) returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
begin
  select p.company_id,lower(coalesce(p.role,'')) into v_company_id,v_role
  from public.profiles p where p.id=auth.uid() and p.active is true;
  if v_company_id is null or not exists(
    select 1 from public.storm_events e where e.id=p_event_id and e.company_id=v_company_id and e.status='active'
  ) then
    raise exception using errcode='42501',message='The active storm event is unavailable.';
  end if;
  if p_deployment_status not in ('assigned','mobilizing','onsite','standby','released') then
    raise exception using errcode='22023',message='Unsupported crew deployment status.';
  end if;
  if p_user_id <> auth.uid() and v_role not in ('owner','admin','superintendent','gf') then
    raise exception using errcode='42501',message='You may only update your own storm check-in.';
  end if;
  if v_role='superintendent' and not public.linecrew_has_capability('storm_mode') then
    raise exception using errcode='42501',message='This Superintendent does not have storm mode permission.';
  end if;
  if not exists(
    select 1 from public.storm_event_crew_status s
    where s.event_id=p_event_id and s.company_id=v_company_id and s.user_id=p_user_id
  ) then
    raise exception using errcode='P0002',message='This crew is not assigned to the storm event.';
  end if;

  update public.storm_event_crew_status set
    deployment_status=p_deployment_status,
    current_location=nullif(btrim(coalesce(p_current_location,'')),''),
    lodging=nullif(btrim(coalesce(p_lodging,'')),''),
    readiness_notes=nullif(btrim(coalesce(p_readiness_notes,'')),''),
    last_check_in_at=now(),updated_by=auth.uid(),updated_at=now()
  where event_id=p_event_id and company_id=v_company_id and user_id=p_user_id;
  insert into public.storm_event_activity(event_id,company_id,actor_id,action,details)
  values(p_event_id,v_company_id,auth.uid(),'crew_check_in',
    jsonb_build_object('user_id',p_user_id,'status',p_deployment_status));
end;
$$;

create or replace function public.get_storm_event_workspace()
returns jsonb
language plpgsql
security definer
set search_path = ''
stable
as $$
declare
  v_company_id uuid;
  v_event_id uuid;
  v_today date;
  v_result jsonb;
begin
  select p.company_id,(now() at time zone c.timezone)::date into v_company_id,v_today
  from public.profiles p join public.companies c on c.id=p.company_id
  where p.id=auth.uid() and p.active is true;
  if v_company_id is null then
    raise exception using errcode='42501',message='An active company profile is required.';
  end if;
  select e.id into v_event_id from public.storm_events e
  where e.company_id=v_company_id and e.status='active';

  select jsonb_build_object(
    'active_event',case when e.id is null then null else jsonb_build_object(
      'id',e.id,'event_name',e.event_name,'status',e.status,'customer_id',e.customer_id,
      'customer_name',c.name,'contract_id',e.contract_id,'contract_name',ct.contract_name,
      'location',e.location,'start_date',e.start_date,'expected_end_date',e.expected_end_date,
      'time_policy',e.time_policy,'per_diem_policy',e.per_diem_policy,
      'default_per_diem_amount',e.default_per_diem_amount,'operations_notes',e.operations_notes,
      'created_at',e.created_at,'updated_at',e.updated_at
    ) end,
    'crews',coalesce((select jsonb_agg(jsonb_build_object(
      'user_id',s.user_id,'full_name',p.full_name,'role',p.role,
      'deployment_status',s.deployment_status,'current_location',s.current_location,
      'lodging',s.lodging,'readiness_notes',s.readiness_notes,
      'last_check_in_at',s.last_check_in_at,'has_report_today',exists(
        select 1 from public.daily_reports dr where dr.storm_event_id=s.event_id
          and dr.created_by=s.user_id and dr.work_date=v_today and dr.archived is not true
      )
    ) order by lower(p.full_name))
      from public.storm_event_crew_status s join public.profiles p on p.id=s.user_id
      where s.event_id=v_event_id and s.company_id=v_company_id),'[]'::jsonb),
    'today',jsonb_build_object(
      'reports',(select count(*) from public.daily_reports dr where dr.storm_event_id=v_event_id and dr.work_date=v_today and dr.archived is not true),
      'submitted',(select count(*) from public.daily_reports dr where dr.storm_event_id=v_event_id and dr.work_date=v_today and dr.status='submitted' and dr.archived is not true),
      'approved',(select count(*) from public.daily_reports dr where dr.storm_event_id=v_event_id and dr.work_date=v_today and dr.status='approved' and dr.archived is not true),
      'regular_hours',coalesce((select sum(dr.regular_hours) from public.daily_reports dr where dr.storm_event_id=v_event_id and dr.work_date=v_today and dr.archived is not true),0),
      'overtime_hours',coalesce((select sum(dr.overtime_hours) from public.daily_reports dr where dr.storm_event_id=v_event_id and dr.work_date=v_today and dr.archived is not true),0)
    ),
    'history',coalesce((select jsonb_agg(h.item order by h.created_at desc) from (
      select jsonb_build_object('id',se.id,'event_name',se.event_name,'status',se.status,
        'location',se.location,'start_date',se.start_date,'ended_at',se.ended_at) item,se.created_at
      from public.storm_events se where se.company_id=v_company_id order by se.created_at desc limit 20
    ) h),'[]'::jsonb)
  ) into v_result
  from (select * from public.storm_events where id=v_event_id) e
  left join public.customers c on c.id=e.customer_id
  left join public.contracts ct on ct.id=e.contract_id;

  if v_result is null then
    v_result := jsonb_build_object('active_event',null,'crews','[]'::jsonb,'today',jsonb_build_object(
      'reports',0,'submitted',0,'approved',0,'regular_hours',0,'overtime_hours',0
    ),'history',coalesce((select jsonb_agg(h.item order by h.created_at desc) from (
      select jsonb_build_object('id',se.id,'event_name',se.event_name,'status',se.status,
        'location',se.location,'start_date',se.start_date,'ended_at',se.ended_at) item,se.created_at
      from public.storm_events se where se.company_id=v_company_id order by se.created_at desc limit 20
    ) h),'[]'::jsonb));
  end if;
  return v_result;
end;
$$;

-- Preserve the legacy entry point while adding a stable event foreign key.
create or replace function public.set_daily_report_storm_context(p_report_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid; v_role text; v_report_created_by uuid;
  v_enabled boolean; v_event_name text; v_assigned boolean; v_event_id uuid;
begin
  select p.company_id,lower(coalesce(p.role,'')) into v_company_id,v_role
  from public.profiles p where p.id=auth.uid() and p.active is true;
  if v_company_id is null or v_role not in ('foreman','gf','admin','owner','superintendent') then
    raise exception using errcode='42501',message='You are not allowed to update this daily report.';
  end if;
  if v_role='superintendent' and not public.linecrew_has_capability('storm_mode') then
    raise exception using errcode='42501',message='This Superintendent does not have storm mode permission.';
  end if;
  select dr.created_by into v_report_created_by from public.daily_reports dr
  where dr.id=p_report_id and dr.company_id=v_company_id;
  if v_report_created_by is null then raise exception using errcode='P0002',message='Daily report was not found for your company.'; end if;
  if v_role='foreman' and v_report_created_by<>auth.uid() then
    raise exception using errcode='42501',message='Foremen may only update their own daily reports.';
  end if;
  select c.storm_mode_enabled,c.storm_event_name,
    exists(select 1 from public.storm_mode_assignments a where a.company_id=v_company_id and a.user_id=v_report_created_by),
    (select e.id from public.storm_events e where e.company_id=v_company_id and e.status='active')
  into v_enabled,v_event_name,v_assigned,v_event_id
  from public.companies c where c.id=v_company_id;
  update public.daily_reports set
    storm_mode=coalesce(v_enabled,false) and coalesce(v_assigned,false),
    storm_event_name=case when coalesce(v_enabled,false) and coalesce(v_assigned,false) then v_event_name else null end,
    storm_event_id=case when coalesce(v_enabled,false) and coalesce(v_assigned,false) then v_event_id else null end
  where id=p_report_id and company_id=v_company_id;
end;
$$;

revoke all on function public.save_storm_event_workspace(boolean,text,uuid,uuid,text,date,date,text,text,numeric,text) from public,anon;
revoke all on function public.update_storm_crew_check_in(uuid,uuid,text,text,text,text) from public,anon;
revoke all on function public.get_storm_event_workspace() from public,anon;
revoke all on function public.set_daily_report_storm_context(uuid) from public,anon;
revoke all on function public.apply_timekeeping_storm_event_context() from public,anon,authenticated;
grant execute on function public.save_storm_event_workspace(boolean,text,uuid,uuid,text,date,date,text,text,numeric,text) to authenticated,service_role;
grant execute on function public.update_storm_crew_check_in(uuid,uuid,text,text,text,text) to authenticated,service_role;
grant execute on function public.get_storm_event_workspace() to authenticated,service_role;
grant execute on function public.set_daily_report_storm_context(uuid) to authenticated,service_role;

commit;
