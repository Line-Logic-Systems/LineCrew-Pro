create or replace function public.linecrew_require_privileged_mfa_for_mutation()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  if not public.linecrew_privileged_mfa_satisfied() then
    raise exception using errcode='42501',
      message='Complete authenticator verification before making this privileged change.';
  end if;
  return coalesce(new, old);
end;
$$;

do $$
declare
  v_table text;
  v_trigger text;
begin
  foreach v_table in array array[
    'profiles','companies','customers','contracts','price_books','price_book_items',
    'contract_field_settings','billing_export_batches','billing_export_lines'
  ] loop
    v_trigger := 'require_privileged_mfa_' || v_table;
    execute format('drop trigger if exists %I on public.%I',v_trigger,v_table);
    execute format(
      'create trigger %I before insert or update or delete on public.%I for each row execute function public.linecrew_require_privileged_mfa_for_mutation()',
      v_trigger,v_table
    );
  end loop;
end $$;

do $$
declare
  v_oid oid;
  v_def text;
begin
  v_oid := to_regprocedure('public.set_company_member_active(uuid,boolean)');
  if v_oid is null then raise exception 'set_company_member_active is missing'; end if;
  select pg_get_functiondef(v_oid) into v_def;
  if strpos(v_def,'actor_role not in (''owner'',''manager'',''admin'',''superintendent'')') = 0 then
    if strpos(v_def,'actor_role not in (''owner'',''admin'',''superintendent'')') = 0 then
      raise exception 'Expected member-active role boundary was not found.';
    end if;
    v_def := replace(v_def,
      'actor_role not in (''owner'',''admin'',''superintendent'')',
      'actor_role not in (''owner'',''manager'',''admin'',''superintendent'')');
    execute v_def;
  end if;

  v_oid := to_regprocedure('public.set_billing_export_batch_status_v2(uuid,text,text)');
  if v_oid is null then raise exception 'set_billing_export_batch_status_v2 is missing'; end if;
  select pg_get_functiondef(v_oid) into v_def;
  if strpos(v_def,'v_role not in (''owner'',''manager'',''admin'',''superintendent'')') = 0 then
    if strpos(v_def,'v_role not in (''owner'',''admin'',''superintendent'')') = 0 then
      raise exception 'Expected billing-status role boundary was not found.';
    end if;
    execute replace(v_def,
      'v_role not in (''owner'',''admin'',''superintendent'')',
      'v_role not in (''owner'',''manager'',''admin'',''superintendent'')');
  end if;
end $$;
