create table if not exists public.app_error_events (
  id bigint generated always as identity primary key,
  company_id uuid not null references public.companies(id) on delete cascade,
  user_id uuid references auth.users(id) on delete set null,
  area text not null,
  error_code text not null,
  page text not null,
  safe_message text not null,
  created_at timestamptz not null default now()
);

create index if not exists app_error_events_company_created_idx
  on public.app_error_events(company_id,created_at desc);
alter table public.app_error_events enable row level security;
revoke all on public.app_error_events from public,anon,authenticated;

alter table public.companies drop constraint if exists companies_subscription_status_supported;
alter table public.companies add constraint companies_subscription_status_supported
  check (subscription_status in ('trial','active','internal','past_due','suspended','cancelled'));

create or replace function public.record_app_error(
  p_area text,
  p_error_code text,
  p_page text,
  p_message text
)
returns void language plpgsql security definer set search_path=''
as $$
declare v_company uuid; v_safe text;
begin
  select p.company_id into v_company from public.profiles p
    where p.id=(select auth.uid()) and p.active is true;
  if v_company is null then return; end if;
  v_safe:=left(coalesce(p_message,'Unexpected application error'),300);
  v_safe:=regexp_replace(v_safe,'https?://[^ ]+','[url]','gi');
  v_safe:=regexp_replace(v_safe,'[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}','[email]','gi');
  v_safe:=regexp_replace(v_safe,'[0-9a-f]{8}-[0-9a-f-]{27,}','[id]','gi');
  v_safe:=regexp_replace(v_safe,'(sk|sb)_[A-Za-z0-9_-]{12,}','[secret]','gi');
  insert into public.app_error_events(company_id,user_id,area,error_code,page,safe_message)
  values(v_company,(select auth.uid()),left(coalesce(nullif(trim(p_area),''),'app'),60),
    left(coalesce(nullif(trim(p_error_code),''),'operation_failed'),80),
    left(coalesce(nullif(trim(p_page),''),'unknown'),100),v_safe);
end;
$$;

drop function if exists public.support_list_companies();
create function public.support_list_companies()
returns table(id uuid,name text,active_users bigint,last_activity timestamptz,
  subscription_status text,subscription_expires_at timestamptz,recent_errors bigint)
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
    ),c.subscription_status,c.subscription_expires_at,
    (select count(*) from public.app_error_events e where e.company_id=c.id and e.created_at>now()-interval '24 hours')
  from public.companies c order by lower(c.name);
end;
$$;

create or replace function public.support_set_company_access(
  p_company_id uuid,p_status text,p_expires_at timestamptz default null
)
returns void language plpgsql security definer set search_path=''
as $$
declare v_status text:=lower(trim(coalesce(p_status,'')));
begin
  if not public.is_platform_support() then raise exception 'Platform support access required'; end if;
  if v_status not in ('trial','active','internal','past_due','suspended','cancelled') then raise exception 'Invalid company access status'; end if;
  if v_status='trial' and p_expires_at is not null and p_expires_at<=now() then raise exception 'Trial expiration must be in the future'; end if;
  update public.companies set subscription_status=v_status,
    subscription_expires_at=case when v_status='trial' then p_expires_at else null end,
    updated_at=now()
  where id=p_company_id;
  if not found then raise exception 'Company not found'; end if;
  insert into public.support_audit_events(company_id,actor_id,event_type,details)
  values(p_company_id,(select auth.uid()),'company_access_updated',
    jsonb_build_object('status',v_status,'expires_at',p_expires_at));
end;
$$;

create or replace function public.support_get_recent_errors(p_request_id uuid)
returns table(id bigint,area text,error_code text,page text,safe_message text,created_at timestamptz)
language plpgsql security definer set search_path=''
as $$
declare v_request public.support_access_requests%rowtype;
begin
  if not public.is_platform_support() then raise exception 'Platform support access required'; end if;
  select * into v_request from public.support_access_requests r
    where r.id=p_request_id and r.support_user_id=(select auth.uid())
      and r.status='approved' and r.expires_at>now();
  if not found then raise exception 'Approved, unexpired support access is required'; end if;
  insert into public.support_audit_events(request_id,company_id,actor_id,event_type,details)
  values(p_request_id,v_request.company_id,(select auth.uid()),'error_log_viewed',jsonb_build_object('scope','sanitized'));
  return query select e.id,e.area,e.error_code,e.page,e.safe_message,e.created_at
    from public.app_error_events e where e.company_id=v_request.company_id
    order by e.created_at desc limit 50;
end;
$$;

revoke execute on function public.record_app_error(text,text,text,text) from public,anon;
revoke execute on function public.support_list_companies() from public,anon;
revoke execute on function public.support_set_company_access(uuid,text,timestamptz) from public,anon;
revoke execute on function public.support_get_recent_errors(uuid) from public,anon;
grant execute on function public.record_app_error(text,text,text,text) to authenticated;
grant execute on function public.support_list_companies() to authenticated;
grant execute on function public.support_set_company_access(uuid,text,timestamptz) to authenticated;
grant execute on function public.support_get_recent_errors(uuid) to authenticated;

update public.companies set subscription_status='internal',subscription_expires_at=null
where lower(name)='linecrew pro support';
