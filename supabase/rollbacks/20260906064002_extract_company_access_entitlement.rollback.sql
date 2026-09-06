-- Reverse order: 182620, 134013, 071452, 070834, 064624, 064002, 060001, 055947, 055940.
-- Restore the pre-extraction definitions from the live test schema before
-- dropping the shared helper. This rollback is intentionally kept separate
-- from Utility Portal schema changes.

create or replace function public.my_company_subscription_access()
returns table(company_id uuid, plan_code text, status text, access_enabled boolean, trial_ends_at timestamptz, current_period_end timestamptz)
language plpgsql stable security definer set search_path to ''
as $function$
declare v_company_id uuid;
begin
  select p.company_id into v_company_id from public.profiles p
  where p.id=auth.uid() and coalesce(p.active,true)=true;
  if v_company_id is null then return; end if;
  return query select cs.company_id,cs.plan_code,cs.status,
    case when cs.access_override is not null then cs.access_override
      else cs.access_enabled and (
        cs.status='active'
        or (cs.status='trialing' and cs.trial_ends_at is not null and cs.trial_ends_at>now())
        or (cs.status='past_due' and cs.past_due_since is not null and cs.past_due_since>now()-interval '7 days')
      ) end,
    cs.trial_ends_at,cs.current_period_end
  from public.company_subscriptions cs where cs.company_id=v_company_id;
end;
$function$;

create or replace function public.enforce_linecrew_company_access()
returns void language plpgsql stable security definer set search_path to ''
as $function$
declare
  v_profile_active boolean; v_role text; v_is_support boolean; v_has_profile boolean;
  v_subscription_found boolean; v_status text; v_access_enabled boolean;
  v_access_override boolean; v_trial_ends_at timestamptz; v_past_due_since timestamptz;
  v_effective_access boolean;
  v_request_path text:=coalesce(current_setting('request.path',true),'');
  v_aal text:=coalesce((select auth.jwt()->>'aal'),'aal1');
begin
  if auth.uid() is null then return; end if;
  select exists(select 1 from public.platform_support_users s where s.user_id=auth.uid() and s.active is true) into v_is_support;
  select coalesce(p.active,true),lower(coalesce(p.role,'')),lower(coalesce(cs.status,'')),
    coalesce(cs.access_enabled,false),cs.access_override,cs.trial_ends_at,cs.past_due_since,cs.company_id is not null
  into v_profile_active,v_role,v_status,v_access_enabled,v_access_override,v_trial_ends_at,v_past_due_since,v_subscription_found
  from public.profiles p left join public.company_subscriptions cs on cs.company_id=p.company_id where p.id=auth.uid();
  v_has_profile:=found;
  if not v_has_profile and not v_is_support then return; end if;
  if v_has_profile and v_profile_active is not true then raise exception using errcode='42501',message='LineCrew profile access is inactive.'; end if;
  if v_request_path='/rpc/linecrew_mfa_bootstrap_identity' then return; end if;
  if (v_is_support or v_role in ('owner','admin')) and v_aal<>'aal2' then
    raise exception using errcode='42501',message='Authenticator verification is required for privileged access.',hint='Complete the LineCrew Pro authenticator challenge and retry.';
  end if;
  if v_request_path='/rpc/my_company_billing_summary' then return; end if;
  if v_has_profile then
    if v_access_override is not null then v_effective_access:=v_access_override;
    else v_effective_access:=v_subscription_found and v_access_enabled and (
      v_status='active' or (v_status='trialing' and v_trial_ends_at is not null and v_trial_ends_at>now())
      or (v_status='past_due' and v_past_due_since is not null and v_past_due_since>now()-interval '7 days'));
    end if;
    if v_effective_access is not true then raise exception using errcode='42501',message='LineCrew company access is inactive.'; end if;
  end if;
end;
$function$;

drop function if exists public.linecrew_company_access_enabled(uuid);
