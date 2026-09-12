do $$
declare
  r record;
  v_oid oid;
  v_def text;
  v_new text;
begin
  -- Manager is an operational leadership role equivalent to Owner/Admin, but
  -- ownership transfer/recovery and platform-owner functions are deliberately
  -- absent from this allow-list.
  for r in select signature from (values
    ('public.create_contract_job(uuid,text,text)'),
    ('public.create_job_package_work_point(uuid,text,text)'),
    ('public.create_job(text,text,text,text)'),
    ('public.create_standalone_jsa_v2(uuid,date,text,text,text,text,text,text,text,text,text,boolean,jsonb)'),
    ('public.create_standalone_jsa(uuid,date,text,text,text,text,text,text,text,text,text,boolean)'),
    ('public.create_uploaded_company_jsa(uuid,date,text,text)'),
    ('public.delete_daily_report_attachment(uuid)'),
    ('public.delete_daily_report_unit_location(uuid,uuid,text)'),
    ('public.delete_daily_report_unit(uuid,uuid)'),
    ('public.delete_draft_daily_report(uuid)'),
    ('public.delete_job_package_authorized_unit(uuid)'),
    ('public.delete_job_package_work_point(uuid)'),
    ('public.delete_job_package(uuid)'),
    ('public.delete_uploaded_company_jsa(uuid)'),
    ('public.get_assignable_job_leaders()'),
    ('public.get_billing_export_batch_lines(uuid)'),
    ('public.get_billing_export_batches_v2()'),
    ('public.get_billing_export_batches_v3()'),
    ('public.get_billing_export_batches()'),
    ('public.get_company_general_foremen()'),
    ('public.get_company_jsas_v2()'),
    ('public.get_company_jsas()'),
    ('public.get_daily_report_audit_history(uuid)'),
    ('public.get_daily_report_authorization_summaries()'),
    ('public.get_daily_report_jsa(uuid)'),
    ('public.get_daily_report_unit_authorized_action(uuid,uuid,text)'),
    ('public.get_daily_report_unit_catalog(uuid)'),
    ('public.get_daily_report_unit_locations_v2(uuid)'),
    ('public.get_daily_report_unit_locations(uuid)'),
    ('public.get_daily_report_value_summaries()'),
    ('public.get_daily_unit_usage_memory(uuid)'),
    ('public.get_gf_crew_assignment_roster()'),
    ('public.get_job_assignment_history(uuid)'),
    ('public.get_job_closeout_history(uuid)'),
    ('public.get_job_leader_assignments()'),
    ('public.get_job_package_work_points(uuid)'),
    ('public.get_job_packages_v2(uuid)'),
    ('public.get_job_packages(uuid)'),
    ('public.get_pending_utility_packet_import_for_package(uuid)'),
    ('public.get_remaining_job_units_for_field(uuid)'),
    ('public.get_storm_mode_assignments()'),
    ('public.import_price_book_items_atomic(uuid,jsonb,boolean,text)'),
    ('public.register_jsa_upload_attachment(uuid,text,text,text,bigint,integer)'),
    ('public.review_daily_report(uuid,boolean,text)'),
    ('public.rotate_company_join_code()'),
    ('public.save_billing_export_batch_details(uuid,text,text,text)'),
    ('public.save_daily_report_jsa(uuid,text,text,text,text,text,text,text,boolean)'),
    ('public.save_daily_report_unit_location_v2(uuid,uuid,text,numeric,numeric,numeric)'),
    ('public.save_daily_report_unit_location(uuid,uuid,text,numeric,numeric)'),
    ('public.save_daily_report_unit_redline_comment(uuid,text)'),
    ('public.save_daily_report_unit(uuid,uuid,numeric,numeric)'),
    ('public.save_job_package_authorized_unit(uuid,text,numeric,numeric)'),
    ('public.set_billing_export_batch_status(uuid,text)'),
    ('public.set_company_redline_approval_requirement(boolean)'),
    ('public.set_company_storm_mode(boolean,text)'),
    ('public.set_contract_field_value_percent(uuid,numeric)'),
    ('public.set_daily_report_archived(uuid,boolean)'),
    ('public.set_daily_report_context(uuid,text,numeric,text)'),
    ('public.set_gf_crew_assignment(uuid,uuid)'),
    ('public.set_price_book_active(uuid,boolean)'),
    ('public.set_storm_mode_assignments(uuid[])'),
    ('public.timekeeping_report_rows_v2(date,date,uuid,uuid)'),
    ('public.timekeeping_report_rows_v3(date,date,uuid,uuid)'),
    ('public.timekeeping_report_rows(date,date,uuid,uuid)'),
    ('public.update_company_settings(text,text,text,text,text,text)'),
    ('public.update_contract_job(uuid,uuid,text,text)'),
    ('public.update_job(uuid,text,text,text,text)'),
    ('public.upsert_leadership_employee_time(uuid,uuid,date,time without time zone,time without time zone,integer,uuid,text,boolean,text,boolean,text)'),
    ('public.upsert_leadership_time_batch(jsonb)'),
    ('public.upsert_my_leadership_time(uuid,date,time without time zone,time without time zone,integer,uuid,text,boolean,text,boolean,text)')
  ) patches(signature)
  loop
    v_oid := to_regprocedure(r.signature);
    if v_oid is null then
      raise exception 'Expected Manager parity function is missing: %',r.signature;
    end if;
    select pg_get_functiondef(v_oid) into v_def;
    if strpos(v_def,'''manager''')>0 then
      continue;
    end if;

    v_new := replace(v_def, '''admin'', ', '''admin'', ''manager'', ');
    v_new := replace(v_new, '''admin'',', '''admin'',''manager'',');
    v_new := replace(v_new,', ''admin'')',', ''admin'', ''manager'')');
    v_new := replace(v_new,',''admin'')',',''admin'',''manager'')');
    v_new := replace(v_new,
      'v_role <> ''admin''',
      'v_role not in (''admin'', ''manager'')');
    v_new := replace(v_new,
      'v_role != ''admin''',
      'v_role not in (''admin'', ''manager'')');

    if v_new=v_def or strpos(v_new,'''manager''')=0 then
           raise exception 'No operational Admin role list was patched in %',r.signature;
    end if;
    execute v_new;
  end loop;

  -- Closing/reopening a clean job is operational. Overriding unresolved Final
  -- Bill or production blockers remains an Owner-only exception, matching the
  -- Final Bill override and the client warning.
  v_oid := to_regprocedure('public.set_job_closeout(uuid,boolean,text)');
  if v_oid is null then raise exception 'set_job_closeout is missing'; end if;
  select pg_get_functiondef(v_oid) into v_def;
  v_new := replace(v_def,
    'v_override_required and v_role not in (''owner'', ''manager'')',
    'v_override_required and v_role <> ''owner''');
  v_new := replace(v_new,
    'Only the company Owner or Manager can approve closeout with unresolved billing or production.',
    'Only the company Owner can approve closeout with unresolved billing or production.');
  if v_new=v_def then
    raise exception 'Expected Manager closeout override gate was not found.';
  end if;
  execute v_new;
end $$;
