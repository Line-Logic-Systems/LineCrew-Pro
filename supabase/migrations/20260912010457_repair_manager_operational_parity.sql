do $$
declare
  r record;
  v_oid oid;
  v_def text;
  v_new text;
begin
  for r in
    select * from (values
      ('public.create_billing_export_batch(uuid,date,date,boolean,text)',
       'v_role not in (''admin'', ''owner'', ''superintendent'')',
       'v_role not in (''admin'', ''manager'', ''owner'', ''superintendent'')'),
      ('public.get_job_billing_reconciliation(uuid)',
       'v_role not in (''owner'', ''admin'', ''superintendent'')',
       'v_role not in (''owner'', ''manager'', ''admin'', ''superintendent'')'),
      ('public.set_job_closeout(uuid,boolean,text)',
       'v_role not in (''owner'', ''admin'', ''superintendent'')',
       'v_role not in (''owner'', ''manager'', ''admin'', ''superintendent'')'),
      ('public.get_job_progress_dashboard()',
       'v_role not in (''admin'', ''gf'', ''owner'', ''superintendent'')',
       'v_role not in (''admin'', ''manager'', ''gf'', ''owner'', ''superintendent'')'),
      ('public.get_completed_job_export_details_v1(uuid)',
       'v_role not in (''owner'', ''admin'', ''superintendent'', ''gf'')',
       'v_role not in (''owner'', ''manager'', ''admin'', ''superintendent'', ''gf'')'),
      ('public.set_job_leader_assignment(uuid,uuid,boolean)',
       'v_role not in (''owner'', ''admin'', ''gf'', ''superintendent'')',
       'v_role not in (''owner'', ''manager'', ''admin'', ''gf'', ''superintendent'')'),
      ('public.get_price_book_items_for_user(uuid)',
       'v_role not in (''foreman'', ''gf'', ''admin'', ''owner'', ''superintendent'')',
       'v_role not in (''foreman'', ''gf'', ''admin'', ''manager'', ''owner'', ''superintendent'')'),
      ('public.can_review_daily_reports()',
       'lower(p.role) in (''owner'', ''admin'', ''gf'')',
       'lower(p.role) in (''owner'', ''manager'', ''admin'', ''gf'')'),
      ('public.linecrew_can_manage_job_packages()',
       'lower(coalesce(p.role,'''')) in (''owner'',''admin'',''gf'')',
       'lower(coalesce(p.role,'''')) in (''owner'',''manager'',''admin'',''gf'')'),
      ('public.linecrew_can_manage_jobs()',
       'lower(coalesce(p.role,'''')) in (''owner'',''admin'',''gf'')',
       'lower(coalesce(p.role,'''')) in (''owner'',''manager'',''admin'',''gf'')')
    ) as patches(signature, old_text, new_text)
  loop
    v_oid := to_regprocedure(r.signature);
    if v_oid is null then
      raise exception 'Expected Manager parity function is missing: %', r.signature;
    end if;
    select pg_get_functiondef(v_oid) into v_def;
    if strpos(v_def, r.new_text) > 0 then
      continue;
    end if;
    if strpos(v_def, r.old_text) = 0 then
      raise exception 'Expected role allow-list was not found in %', r.signature;
    end if;
    v_new := replace(v_def, r.old_text, r.new_text);
    if v_new = v_def then
      raise exception 'Manager parity patch did not change %', r.signature;
    end if;
    execute v_new;
  end loop;

  v_oid := to_regprocedure('public.set_job_closeout(uuid,boolean,text)');
  select pg_get_functiondef(v_oid) into v_def;
  if strpos(v_def, 'v_override_required and v_role not in (''owner'', ''manager'')') = 0 then
    if strpos(v_def, 'v_override_required and v_role <> ''owner''') = 0 then
      raise exception 'Expected closeout override Owner check was not found.';
    end if;
    v_new := replace(v_def,
      'v_override_required and v_role <> ''owner''',
      'v_override_required and v_role not in (''owner'', ''manager'')');
    v_new := replace(v_new,
      'Only the company Owner can approve closeout with unresolved billing or production.',
      'Only the company Owner or Manager can approve closeout with unresolved billing or production.');
    execute v_new;
  end if;
end $$;
