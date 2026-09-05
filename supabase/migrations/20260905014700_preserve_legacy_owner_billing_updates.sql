-- Preserve platform-owner support for legacy manual subscriptions while all customer-facing purchases use the single licensed-crew plan.

create or replace function public.platform_owner_set_subscription(
p_company_id uuid,p_plan_code text,p_monthly_price_cents integer,p_status text,p_access_override boolean default null,p_trial_ends_at timestamptz default null,p_notes text default null,p_included_crew_limit integer default 5)
returns public.company_subscriptions language plpgsql security definer set search_path='public' as $$
declare result public.company_subscriptions; v_before jsonb; v_provider text; v_stripe_subscription_id text; v_existing_status text; v_plan text; v_limit integer; v_price integer;
begin
if not public.is_platform_owner() then raise exception 'Platform owner access required'; end if;
if p_status not in ('trialing','active','past_due','paused','canceled','incomplete') then raise exception 'Invalid subscription status'; end if;
if not exists(select 1 from public.companies c where c.id=p_company_id) then raise exception 'Company not found'; end if;
v_plan:=lower(coalesce(nullif(trim(p_plan_code),''),'linecrew'));
if v_plan not in ('pilot','linecrew','starter','business','pro','enterprise') then raise exception 'Invalid plan code'; end if;
v_limit:=case when v_plan='pilot' then 5 when v_plan='linecrew' then greatest(5,coalesce(p_included_crew_limit,5)) else coalesce(public.plan_crew_limit(v_plan),greatest(5,coalesce(p_included_crew_limit,5))) end;
v_price:=case when v_plan='pilot' then 0 when v_plan='linecrew' then public.linecrew_monthly_cents(v_limit) else coalesce(public.plan_monthly_cents(v_plan),p_monthly_price_cents) end;
select to_jsonb(cs),cs.provider,cs.stripe_subscription_id,cs.status into v_before,v_provider,v_stripe_subscription_id,v_existing_status from public.company_subscriptions cs where cs.company_id=p_company_id;
if v_provider='stripe' and v_stripe_subscription_id is not null and coalesce(v_existing_status,'')<>'canceled' then
 update public.company_subscriptions cs set access_override=p_access_override,notes=p_notes,updated_at=now() where cs.company_id=p_company_id returning cs.* into result;
else
 insert into public.company_subscriptions(company_id,plan_code,monthly_price_cents,status,access_enabled,access_override,trial_ends_at,notes,provider,updated_at,included_crew_limit)
 values(p_company_id,v_plan,v_price,p_status,p_status in ('trialing','active','past_due'),p_access_override,p_trial_ends_at,p_notes,'manual',now(),v_limit)
 on conflict(company_id) do update set plan_code=excluded.plan_code,monthly_price_cents=excluded.monthly_price_cents,status=excluded.status,access_enabled=excluded.access_enabled,access_override=excluded.access_override,trial_ends_at=excluded.trial_ends_at,notes=excluded.notes,provider='manual',included_crew_limit=excluded.included_crew_limit,updated_at=now() returning * into result;
end if;
perform public.recalculate_company_crew_overage(p_company_id);
select * into result from public.company_subscriptions cs where cs.company_id=p_company_id;
insert into public.platform_owner_audit_events(actor_user_id,company_id,action,before_state,after_state) values(auth.uid(),p_company_id,'subscription_settings_updated',v_before,to_jsonb(result));
return result;
end; $$;

revoke all on function public.platform_owner_set_subscription(uuid,text,integer,text,boolean,timestamptz,text,integer) from public;
revoke execute on function public.platform_owner_set_subscription(uuid,text,integer,text,boolean,timestamptz,text,integer) from anon;
grant execute on function public.platform_owner_set_subscription(uuid,text,integer,text,boolean,timestamptz,text,integer) to authenticated,service_role;
