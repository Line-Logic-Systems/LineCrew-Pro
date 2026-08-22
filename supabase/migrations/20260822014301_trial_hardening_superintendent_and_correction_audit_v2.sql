do $$
declare
  d text;
begin
  select pg_get_functiondef(oid) into d
  from pg_proc where pronamespace='public'::regnamespace and proname='get_daily_report_unit_locations';
  d := replace(d, 'v_role not in (''foreman'', ''gf'', ''admin'')', 'v_role not in (''foreman'', ''gf'', ''superintendent'', ''admin'', ''owner'')');
  d := replace(d, 'v_can_see_actual := v_role in (''admin'', ''gf'');', 'v_can_see_actual := v_role in (''admin'',''gf'',''owner'') or (v_role=''superintendent'' and coalesce((select (p.role_permissions->>''actual_contract_pricing'')::boolean from public.profiles p where p.id=auth.uid()), true));');
  execute d;

  select pg_get_functiondef(oid) into d
  from pg_proc where pronamespace='public'::regnamespace and proname='get_daily_report_unit_catalog';
  d := replace(d, 'v_role not in (''foreman'', ''gf'', ''admin'')', 'v_role not in (''foreman'', ''gf'', ''superintendent'', ''admin'', ''owner'')');
  d := replace(d, 'v_can_see_actual := v_role in (''admin'', ''gf'');', 'v_can_see_actual := v_role in (''admin'',''gf'',''owner'') or (v_role=''superintendent'' and coalesce((select (p.role_permissions->>''actual_contract_pricing'')::boolean from public.profiles p where p.id=auth.uid()), true));');
  execute d;

  select pg_get_functiondef(oid) into d
  from pg_proc where pronamespace='public'::regnamespace and proname='get_daily_unit_usage_memory';
  d := replace(d, 'v_role not in (''foreman'', ''gf'', ''admin'')', 'v_role not in (''foreman'', ''gf'', ''superintendent'', ''admin'', ''owner'')');
  execute d;
end $$;

create or replace function public.audit_returned_unit_change()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  r public.daily_reports%rowtype;
  v_item_code text;
  v_actor_name text;
  v_actor_role text;
  v_note text;
begin
  select * into r
  from public.daily_reports
  where id = coalesce(new.daily_report_id, old.daily_report_id);

  if r.id is null or lower(coalesce(r.status,'')) <> 'draft' or nullif(btrim(coalesce(r.review_notes,'')),'') is null or r.reviewed_at is null then
    return coalesce(new, old);
  end if;

  select coalesce(pbi.item_code, dpu.item_code, 'Unit')
  into v_item_code
  from public.daily_production_units dpu
  left join public.price_book_items pbi on pbi.id = dpu.price_book_item_id
  where dpu.id = coalesce(new.daily_production_unit_id, old.daily_production_unit_id);

  select coalesce(p.full_name,'Foreman'), lower(coalesce(p.role,''))
  into v_actor_name, v_actor_role
  from public.profiles p where p.id = auth.uid();

  if tg_op = 'UPDATE' and
     new.install_quantity is not distinct from old.install_quantity and
     new.retirement_quantity is not distinct from old.retirement_quantity then
    return new;
  end if;

  if tg_op = 'INSERT' then
    v_note := format('%s / %s added — installed %s, removed %s',
      coalesce(new.pole_location,'Location'), coalesce(v_item_code,'Unit'),
      coalesce(new.install_quantity,0), coalesce(new.retirement_quantity,0));
  elsif tg_op = 'DELETE' then
    v_note := format('%s / %s removed — was installed %s, removed %s',
      coalesce(old.pole_location,'Location'), coalesce(v_item_code,'Unit'),
      coalesce(old.install_quantity,0), coalesce(old.retirement_quantity,0));
  else
    v_note := format('%s / %s changed — installed %s → %s, removed %s → %s',
      coalesce(new.pole_location,old.pole_location,'Location'), coalesce(v_item_code,'Unit'),
      coalesce(old.install_quantity,0), coalesce(new.install_quantity,0),
      coalesce(old.retirement_quantity,0), coalesce(new.retirement_quantity,0));
  end if;

  insert into public.daily_report_audit_events(
    company_id,daily_report_id,event_type,actor_id,actor_name,actor_role,event_notes,created_at
  ) values (
    r.company_id,r.id,'foreman_correction',auth.uid(),v_actor_name,v_actor_role,v_note,now()
  );

  return coalesce(new, old);
end;
$$;

drop trigger if exists trg_audit_returned_unit_change on public.daily_production_unit_locations;
create trigger trg_audit_returned_unit_change
after insert or update or delete on public.daily_production_unit_locations
for each row execute function public.audit_returned_unit_change();

create or replace function public.submit_daily_report(p_report_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_reviewed_at timestamptz;
  v_review_notes text;
  v_corrections text;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if not exists (
    select 1 from public.daily_production_unit_locations l
    where l.daily_report_id = p_report_id
      and l.company_id = public.my_company_id()
  ) then
    raise exception 'Add at least one unit before submitting this daily report.';
  end if;

  select reviewed_at, review_notes
  into v_reviewed_at, v_review_notes
  from public.daily_reports
  where id=p_report_id
    and company_id=public.my_company_id()
    and foreman_id=auth.uid()
    and status in ('draft','rejected');

  if not found then
    raise exception 'Report not found or cannot be submitted';
  end if;

  if v_reviewed_at is not null and nullif(btrim(coalesce(v_review_notes,'')),'') is not null then
    select string_agg('• ' || e.event_notes, E'\n' order by e.created_at)
    into v_corrections
    from public.daily_report_audit_events e
    where e.daily_report_id=p_report_id
      and e.company_id=public.my_company_id()
      and e.event_type='foreman_correction'
      and e.created_at >= v_reviewed_at;
  end if;

  update public.daily_reports
  set status='submitted',
      submitted_at=now(),
      updated_at=now(),
      review_notes = case
        when nullif(v_corrections,'') is not null then
          regexp_replace(coalesce(v_review_notes,''), E'\n\nFOREMAN CORRECTIONS:[\s\S]*$', '', 'g') || E'\n\nFOREMAN CORRECTIONS:\n' || v_corrections
        else v_review_notes
      end
  where id=p_report_id
    and company_id=public.my_company_id()
    and foreman_id=auth.uid()
    and status in ('draft','rejected');
end;
$$;

