create table if not exists public.platform_support_users (
  user_id uuid primary key references auth.users(id) on delete cascade,
  active boolean not null default true,
  display_name text not null,
  created_at timestamptz not null default now()
);

create table if not exists public.support_access_requests (
  id uuid primary key default gen_random_uuid(),
  support_user_id uuid not null references auth.users(id),
  company_id uuid not null references public.companies(id) on delete cascade,
  reason text not null check (char_length(trim(reason)) between 10 and 500),
  requested_minutes integer not null default 30 check (requested_minutes between 5 and 60),
  status text not null default 'pending' check (status in ('pending','approved','denied','revoked','expired')),
  requested_at timestamptz not null default now(),
  approved_by uuid references auth.users(id),
  approved_at timestamptz,
  expires_at timestamptz,
  revoked_by uuid references auth.users(id),
  revoked_at timestamptz
);

create index if not exists support_access_requests_company_status_idx
  on public.support_access_requests(company_id,status,requested_at desc);
create index if not exists support_access_requests_operator_idx
  on public.support_access_requests(support_user_id,requested_at desc);

create table if not exists public.support_audit_events (
  id bigint generated always as identity primary key,
  request_id uuid references public.support_access_requests(id) on delete set null,
  company_id uuid references public.companies(id) on delete set null,
  actor_id uuid not null references auth.users(id),
  event_type text not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists support_audit_events_company_created_idx
  on public.support_audit_events(company_id,created_at desc);

alter table public.platform_support_users enable row level security;
alter table public.support_access_requests enable row level security;
alter table public.support_audit_events enable row level security;

revoke all on public.platform_support_users from public,anon,authenticated;
revoke all on public.support_access_requests from public,anon,authenticated;
revoke all on public.support_audit_events from public,anon,authenticated;

create or replace function public.is_platform_support()
returns boolean language sql stable security definer set search_path=''
as $$
  select exists (
    select 1 from public.platform_support_users s
    where s.user_id=(select auth.uid()) and s.active is true
  );
$$;

create or replace function public.support_console_identity()
returns table(is_support boolean,company_id uuid,company_role text)
language sql stable security definer set search_path=''
as $$
  select public.is_platform_support(),p.company_id,lower(p.role)
  from public.profiles p
  where p.id=(select auth.uid()) and p.active is true;
$$;

create or replace function public.support_list_companies()
returns table(id uuid,name text,active_users bigint,last_activity timestamptz)
language plpgsql security definer set search_path=''
as $$
begin
  if not public.is_platform_support() then raise exception 'Platform support access required'; end if;
  return query
  select c.id,c.name,
    (select count(*) from public.profiles p where p.company_id=c.id and p.active is true),
    greatest(
      coalesce((select max(j.created_at) from public.jobs j where j.company_id=c.id),c.created_at),
      coalesce((select max(r.created_at) from public.daily_reports r where r.company_id=c.id),c.created_at)
    )
  from public.companies c order by lower(c.name);
end;
$$;

create or replace function public.support_request_access(p_company_id uuid,p_reason text,p_minutes integer default 30)
returns uuid language plpgsql security definer set search_path=''
as $$
declare v_id uuid;
begin
  if not public.is_platform_support() then raise exception 'Platform support access required'; end if;
  if not exists(select 1 from public.companies where id=p_company_id) then raise exception 'Company not found'; end if;
  if char_length(trim(coalesce(p_reason,''))) not between 10 and 500 then raise exception 'A support reason of 10 to 500 characters is required'; end if;
  if p_minutes not between 5 and 60 then raise exception 'Support access must be between 5 and 60 minutes'; end if;
  update public.support_access_requests set status='expired'
    where support_user_id=(select auth.uid()) and company_id=p_company_id
      and status='approved' and expires_at<=now();
  insert into public.support_access_requests(support_user_id,company_id,reason,requested_minutes)
  values ((select auth.uid()),p_company_id,trim(p_reason),p_minutes) returning id into v_id;
  insert into public.support_audit_events(request_id,company_id,actor_id,event_type,details)
  values(v_id,p_company_id,(select auth.uid()),'access_requested',jsonb_build_object('minutes',p_minutes));
  return v_id;
end;
$$;

create or replace function public.company_list_support_requests()
returns table(id uuid,reason text,status text,requested_at timestamptz,requested_minutes integer,
  approved_at timestamptz,expires_at timestamptz,support_name text)
language plpgsql security definer set search_path=''
as $$
declare v_company uuid; v_role text;
begin
  select p.company_id,lower(p.role) into v_company,v_role from public.profiles p
    where p.id=(select auth.uid()) and p.active is true;
  if v_company is null or v_role not in ('owner','admin') then raise exception 'Company Owner or Admin access required'; end if;
  update public.support_access_requests set status='expired'
    where company_id=v_company and status='approved' and expires_at<=now();
  return query select r.id,r.reason,r.status,r.requested_at,r.requested_minutes,r.approved_at,r.expires_at,s.display_name
    from public.support_access_requests r join public.platform_support_users s on s.user_id=r.support_user_id
    where r.company_id=v_company order by r.requested_at desc limit 50;
end;
$$;

create or replace function public.company_decide_support_request(p_request_id uuid,p_approve boolean)
returns void language plpgsql security definer set search_path=''
as $$
declare v_company uuid; v_role text; v_request public.support_access_requests%rowtype;
begin
  select p.company_id,lower(p.role) into v_company,v_role from public.profiles p
    where p.id=(select auth.uid()) and p.active is true;
  if v_company is null or v_role not in ('owner','admin') then raise exception 'Company Owner or Admin access required'; end if;
  select * into v_request from public.support_access_requests where id=p_request_id and company_id=v_company for update;
  if not found or v_request.status<>'pending' then raise exception 'Pending support request not found'; end if;
  update public.support_access_requests set
    status=case when p_approve then 'approved' else 'denied' end,
    approved_by=case when p_approve then (select auth.uid()) else null end,
    approved_at=case when p_approve then now() else null end,
    expires_at=case when p_approve then now()+make_interval(mins=>v_request.requested_minutes) else null end
  where id=p_request_id;
  insert into public.support_audit_events(request_id,company_id,actor_id,event_type)
  values(p_request_id,v_company,(select auth.uid()),case when p_approve then 'access_approved' else 'access_denied' end);
end;
$$;

create or replace function public.company_revoke_support_access(p_request_id uuid)
returns void language plpgsql security definer set search_path=''
as $$
declare v_company uuid; v_role text;
begin
  select p.company_id,lower(p.role) into v_company,v_role from public.profiles p
    where p.id=(select auth.uid()) and p.active is true;
  if v_company is null or v_role not in ('owner','admin') then raise exception 'Company Owner or Admin access required'; end if;
  update public.support_access_requests set status='revoked',revoked_by=(select auth.uid()),revoked_at=now(),expires_at=now()
    where id=p_request_id and company_id=v_company and status='approved';
  if not found then raise exception 'Active support access not found'; end if;
  insert into public.support_audit_events(request_id,company_id,actor_id,event_type)
  values(p_request_id,v_company,(select auth.uid()),'access_revoked');
end;
$$;

create or replace function public.support_list_my_requests()
returns table(id uuid,company_id uuid,company_name text,reason text,status text,requested_at timestamptz,
  requested_minutes integer,approved_at timestamptz,expires_at timestamptz)
language plpgsql security definer set search_path=''
as $$
begin
  if not public.is_platform_support() then raise exception 'Platform support access required'; end if;
  update public.support_access_requests set status='expired'
    where support_user_id=(select auth.uid()) and status='approved' and expires_at<=now();
  return query select r.id,r.company_id,c.name,r.reason,r.status,r.requested_at,r.requested_minutes,r.approved_at,r.expires_at
    from public.support_access_requests r join public.companies c on c.id=r.company_id
    where r.support_user_id=(select auth.uid()) order by r.requested_at desc limit 100;
end;
$$;

create or replace function public.support_get_diagnostics(p_request_id uuid)
returns jsonb language plpgsql security definer set search_path=''
as $$
declare v_request public.support_access_requests%rowtype; v_result jsonb;
begin
  if not public.is_platform_support() then raise exception 'Platform support access required'; end if;
  select * into v_request from public.support_access_requests
    where id=p_request_id and support_user_id=(select auth.uid()) and status='approved' and expires_at>now();
  if not found then raise exception 'Approved, unexpired support access is required'; end if;
  select jsonb_build_object(
    'company_id',c.id,'company_name',c.name,'access_expires_at',v_request.expires_at,
    'active_users',(select count(*) from public.profiles p where p.company_id=c.id and p.active is true),
    'suspended_users',(select count(*) from public.profiles p where p.company_id=c.id and p.active is false),
    'jobs',(select count(*) from public.jobs j where j.company_id=c.id),
    'active_jobs',(select count(*) from public.jobs j where j.company_id=c.id and j.active is true),
    'customers',(select count(*) from public.customers x where x.company_id=c.id),
    'contracts',(select count(*) from public.contracts x where x.company_id=c.id),
    'price_books',(select count(*) from public.price_books x where x.company_id=c.id),
    'daily_reports',(select count(*) from public.daily_reports x where x.company_id=c.id),
    'draft_reports',(select count(*) from public.daily_reports x where x.company_id=c.id and lower(coalesce(x.status,'draft'))='draft'),
    'submitted_reports',(select count(*) from public.daily_reports x where x.company_id=c.id and lower(coalesce(x.status,''))='submitted'),
    'latest_report_at',(select max(x.created_at) from public.daily_reports x where x.company_id=c.id),
    'latest_job_at',(select max(x.created_at) from public.jobs x where x.company_id=c.id),
    'roles',(select coalesce(jsonb_object_agg(q.role,q.total),'{}'::jsonb) from
      (select lower(coalesce(p.role,'unknown')) role,count(*) total from public.profiles p where p.company_id=c.id group by 1) q)
  ) into v_result from public.companies c where c.id=v_request.company_id;
  insert into public.support_audit_events(request_id,company_id,actor_id,event_type,details)
  values(p_request_id,v_request.company_id,(select auth.uid()),'diagnostics_viewed',jsonb_build_object('scope','aggregate_only'));
  return v_result;
end;
$$;

create or replace function public.company_support_audit_history()
returns table(event_type text,created_at timestamptz,details jsonb,actor_name text)
language plpgsql security definer set search_path=''
as $$
declare v_company uuid; v_role text;
begin
  select p.company_id,lower(p.role) into v_company,v_role from public.profiles p
    where p.id=(select auth.uid()) and p.active is true;
  if v_company is null or v_role not in ('owner','admin') then raise exception 'Company Owner or Admin access required'; end if;
  return query select e.event_type,e.created_at,e.details,coalesce(s.display_name,p.full_name,'Company user')
    from public.support_audit_events e
    left join public.platform_support_users s on s.user_id=e.actor_id
    left join public.profiles p on p.id=e.actor_id
    where e.company_id=v_company order by e.created_at desc limit 100;
end;
$$;

revoke execute on function public.is_platform_support() from public,anon;
revoke execute on function public.support_console_identity() from public,anon;
revoke execute on function public.support_list_companies() from public,anon;
revoke execute on function public.support_request_access(uuid,text,integer) from public,anon;
revoke execute on function public.company_list_support_requests() from public,anon;
revoke execute on function public.company_decide_support_request(uuid,boolean) from public,anon;
revoke execute on function public.company_revoke_support_access(uuid) from public,anon;
revoke execute on function public.support_list_my_requests() from public,anon;
revoke execute on function public.support_get_diagnostics(uuid) from public,anon;
revoke execute on function public.company_support_audit_history() from public,anon;

grant execute on function public.is_platform_support() to authenticated;
grant execute on function public.support_console_identity() to authenticated;
grant execute on function public.support_list_companies() to authenticated;
grant execute on function public.support_request_access(uuid,text,integer) to authenticated;
grant execute on function public.company_list_support_requests() to authenticated;
grant execute on function public.company_decide_support_request(uuid,boolean) to authenticated;
grant execute on function public.company_revoke_support_access(uuid) to authenticated;
grant execute on function public.support_list_my_requests() to authenticated;
grant execute on function public.support_get_diagnostics(uuid) to authenticated;
grant execute on function public.company_support_audit_history() to authenticated;
