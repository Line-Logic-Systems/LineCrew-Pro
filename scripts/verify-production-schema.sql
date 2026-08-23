-- Read-only post-deploy verification for LineCrew Pro production.
-- Returns metadata booleans/counts only; it does not read customer rows.
with function_state as (
  select
    p.oid,
    p.proname,
    pg_get_function_identity_arguments(p.oid) as args,
    pg_get_functiondef(p.oid) as definition,
    p.prosecdef
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
), policy_state as (
  select policyname
  from pg_policies
  where schemaname = 'public' and policyname like 'linecrew_owner_%'
), superintendent_contract_policy_state as (
  select policyname
  from pg_policies
  where schemaname = 'public'
    and tablename in ('customers', 'contracts')
    and policyname in (
      'linecrew_superintendent_customers_manage',
      'linecrew_superintendent_contracts_manage'
    )
    and cmd = 'ALL'
    and roles = array['authenticated']::name[]
    and qual like '%customers_contracts%'
    and qual like '%my_company_id%'
    and with_check like '%customers_contracts%'
    and with_check like '%my_company_id%'
)
select
  to_regprocedure('public.update_my_profile_name(text)') is not null
    as has_profile_name_rpc,
  pg_get_function_result('public.get_daily_report_unit_locations(uuid)'::regprocedure)
    like '%authorization_status text%authorization_note text%'
    as unit_locations_has_current_contract,
  (select definition like '%owner%' and definition like '%superintendent%'
   from function_state where proname = 'create_contract_job' limit 1)
    as contract_jobs_support_owner_and_superintendent,
  (select definition like '%owner%' and definition like '%superintendent%'
   from function_state where proname = 'approve_daily_report' limit 1)
    as report_approval_supports_owner_and_superintendent,
  (select definition like '%customers_contracts%' and definition like '%superintendent%'
   from function_state where proname = 'get_contract_field_settings' limit 1)
    as contract_field_settings_support_owner_and_superintendent,
  (select definition like '%safety_records%' and definition like '%p.active is true%'
   from function_state where proname = 'get_daily_report_jsa' limit 1)
    as daily_report_jsa_matches_role_policy,
  (select count(*) = 0 from function_state where definition like '%actual_contract_pricing%')
    as obsolete_pricing_capability_removed,
  not has_function_privilege('authenticated', 'public.admin_update_user(uuid,text,boolean)', 'execute')
    as legacy_admin_update_disabled,
  not has_function_privilege('authenticated', 'public.review_daily_report(uuid,boolean,text)', 'execute')
    as legacy_report_review_disabled,
  not exists (
    select 1 from pg_policies
    where schemaname = 'public' and tablename = 'profiles' and policyname = 'profiles_admin_update'
  ) as broad_profile_update_policy_removed,
  (select count(*) from policy_state) as owner_company_policy_count,
  (select count(*) = 2 from superintendent_contract_policy_state)
    as superintendent_customers_contracts_policies_safe,
  (select count(*) from function_state f
   where f.prosecdef and has_function_privilege('anon', f.oid, 'execute'))
    as anon_executable_security_definer_count;
