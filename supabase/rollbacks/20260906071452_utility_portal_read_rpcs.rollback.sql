-- Reverse order: 182620, 134013, 071452, 070834, 064624, 064002, 060001, 055947, 055940.
drop function if exists public.utility_log_view(uuid, text);
drop function if exists public.utility_accept_invitation(text, text);
drop function if exists public.utility_get_job_progress(uuid);
drop function if exists public.utility_list_jobs();
drop function if exists public.utility_me();

-- Restore enforce_linecrew_company_access() from the immediately preceding migration.
create or replace function public.enforce_linecrew_company_access()
returns void language plpgsql stable security definer set search_path to '' as $$
declare v_company_id uuid; v_profile_active boolean; v_role text; v_is_support boolean;
 v_has_profile boolean; v_effective_access boolean;
 v_request_path text:=coalesce(current_setting('request.path',true),'');
 v_aal text:=coalesce((select auth.jwt()->>'aal'),'aal1');
begin
 if auth.uid() is null then return; end if;
 select exists(select 1 from public.platform_support_users s where s.user_id=auth.uid() and s.active is true) into v_is_support;
 select p.company_id,coalesce(p.active,true),lower(coalesce(p.role,''))
 into v_company_id,v_profile_active,v_role from public.profiles p where p.id=auth.uid();
 v_has_profile:=found;
 if not v_has_profile and not v_is_support then return; end if;
 if v_has_profile and v_profile_active is not true then raise exception using errcode='42501',message='LineCrew profile access is inactive.'; end if;
 if v_request_path='/rpc/linecrew_mfa_bootstrap_identity' then return; end if;
 if (v_is_support or v_role in ('owner','admin')) and v_aal<>'aal2' then
  raise exception using errcode='42501',message='Authenticator verification is required for privileged access.',hint='Complete the LineCrew Pro authenticator challenge and retry.';
 end if;
 if v_request_path='/rpc/my_company_billing_summary' then return; end if;
 if v_has_profile then
  v_effective_access:=public.linecrew_company_access_enabled(v_company_id);
  if v_effective_access is not true then raise exception using errcode='42501',message='LineCrew company access is inactive.'; end if;
 end if;
end; $$;
