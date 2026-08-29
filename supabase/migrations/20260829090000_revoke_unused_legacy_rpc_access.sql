-- Reduce the authenticated Data API surface without dropping legacy functions.
--
-- These RPCs have no caller in the current application, database functions,
-- triggers, RLS policies, the PostgREST pre-request hook, or scheduled jobs.
-- Keep the functions in place so access can be restored with GRANT EXECUTE if
-- an unexpected legacy client dependency is discovered.

do $migration$
declare
  v_signature text;
  v_function regprocedure;
begin
  foreach v_signature in array array[
    'public.add_daily_report_unit(uuid,text,text,text,numeric,numeric,numeric,numeric,text)',
    'public.admin_create_price_book(text,text,text,date)',
    'public.admin_delete_price_book(uuid)',
    'public.admin_delete_unit_price(uuid)',
    'public.admin_save_unit_price(uuid,text,text,numeric,numeric,numeric)',
    'public.admin_update_company_settings(boolean,numeric,text,text,text,text,boolean,boolean,text,text)',
    'public.admin_update_unit_price(uuid,text,text,numeric,numeric,numeric,boolean)',
    'public.get_billing_export_batches_v2()',
    'public.get_billing_export_batches()',
    'public.get_company_jsas_v2()',
    'public.get_daily_report_jsa(uuid)',
    'public.get_job_packages(uuid)',
    'public.linecrew_can_manage_jobs()',
    'public.my_company_subscription_access()',
    'public.save_daily_report_jsa(uuid,text,text,text,text,text,text,text,boolean)',
    'public.save_daily_report_unit_location(uuid,uuid,text,numeric,numeric)',
    'public.timekeeping_report_rows(date,date,uuid,uuid)',
    'public.update_job(uuid,text,text,text,text)'
  ]
  loop
    v_function := to_regprocedure(v_signature);

    if v_function is not null then
      execute format(
        'revoke execute on function %s from public, anon, authenticated',
        v_function
      );

      if has_function_privilege('anon', v_function, 'execute')
         or has_function_privilege('authenticated', v_function, 'execute') then
        raise exception 'Legacy RPC remains executable: %', v_signature;
      end if;
    end if;
  end loop;
end
$migration$;
