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
  update public.support_access_requests r set status='expired'
    where r.company_id=v_company and r.status='approved' and r.expires_at<=now();
  return query select r.id,r.reason,r.status,r.requested_at,r.requested_minutes,r.approved_at,r.expires_at,s.display_name
    from public.support_access_requests r join public.platform_support_users s on s.user_id=r.support_user_id
    where r.company_id=v_company order by r.requested_at desc limit 50;
end;
$$;

create or replace function public.support_list_my_requests()
returns table(id uuid,company_id uuid,company_name text,reason text,status text,requested_at timestamptz,
  requested_minutes integer,approved_at timestamptz,expires_at timestamptz)
language plpgsql security definer set search_path=''
as $$
begin
  if not public.is_platform_support() then raise exception 'Platform support access required'; end if;
  update public.support_access_requests r set status='expired'
    where r.support_user_id=(select auth.uid()) and r.status='approved' and r.expires_at<=now();
  return query select r.id,r.company_id,c.name,r.reason,r.status,r.requested_at,r.requested_minutes,r.approved_at,r.expires_at
    from public.support_access_requests r join public.companies c on c.id=r.company_id
    where r.support_user_id=(select auth.uid()) order by r.requested_at desc limit 100;
end;
$$;

revoke execute on function public.company_list_support_requests() from public,anon;
revoke execute on function public.support_list_my_requests() from public,anon;
grant execute on function public.company_list_support_requests() to authenticated;
grant execute on function public.support_list_my_requests() to authenticated;
