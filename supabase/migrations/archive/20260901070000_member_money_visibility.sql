-- Per-member Actual Money / Field Money visibility for Foreman, GF and Superintendent.
-- Existing defaults are preserved until Owner/Admin changes an individual's boxes.

create or replace function public.linecrew_has_capability(capability text)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when capability is null or not (capability = any(array[
      'company_settings','team_management','role_management',
      'customers_contracts','price_books','jobs','job_packages',
      'production_review','reporting','storm_mode','safety_records',
      'actual_pricing','field_pricing','exports','ai_assistant'
    ]::text[])) then false
    else coalesce((
      select case
        when lower(profile.role) in ('owner','admin') then true
        when capability = 'actual_pricing' and
             lower(profile.role) in ('foreman','gf','superintendent') then
          coalesce(
            (profile.role_permissions ->> capability)::boolean,
            lower(profile.role) <> 'foreman'
          )
        when capability = 'field_pricing' and
             lower(profile.role) in ('foreman','gf','superintendent') then
          coalesce((profile.role_permissions ->> capability)::boolean, true)
        when lower(profile.role) = 'superintendent' then
          coalesce((profile.role_permissions ->> capability)::boolean, true)
        else false
      end
      from public.profiles profile
      where profile.id = auth.uid()
        and profile.active is true
    ), false)
  end;
$$;

revoke all on function public.linecrew_has_capability(text) from public, anon;
grant execute on function public.linecrew_has_capability(text) to authenticated;

create or replace function public.linecrew_set_member_money_permissions(
  target_user_id uuid,
  can_see_actual boolean,
  can_see_field boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor public.profiles%rowtype;
  target public.profiles%rowtype;
begin
  if target_user_id is null or can_see_actual is null or can_see_field is null then
    raise exception using
      errcode = '22004',
      message = 'Team member and both money visibility choices are required.';
  end if;

  select * into actor
  from public.profiles profile
  where profile.id = auth.uid()
  for update;

  if actor.id is null or actor.active is not true or
     lower(coalesce(actor.role,'')) not in ('owner','admin') then
    raise exception using
      errcode = '42501',
      message = 'Active Owner or Admin access is required.';
  end if;

  select * into target
  from public.profiles profile
  where profile.id = target_user_id
    and profile.company_id = actor.company_id
  for update;

  if target.id is null then
    raise exception using
      errcode = 'P0002',
      message = 'Team member was not found in your company.';
  end if;

  if lower(coalesce(target.role,'')) not in ('foreman','gf','superintendent') then
    raise exception using
      errcode = '42501',
      message = 'Money visibility can be changed only for Foremen, General Foremen and Superintendents.';
  end if;

  update public.profiles profile
  set role_permissions = coalesce(profile.role_permissions, '{}'::jsonb) ||
    jsonb_build_object(
      'actual_pricing', can_see_actual,
      'field_pricing', can_see_field
    )
  where profile.id = target.id
    and profile.company_id = actor.company_id;
end;
$$;

revoke all on function public.linecrew_set_member_money_permissions(uuid,boolean,boolean)
  from public, anon;
grant execute on function public.linecrew_set_member_money_permissions(uuid,boolean,boolean)
  to authenticated;

-- Saving a Superintendent's operational capability checklist must not erase
-- the independently managed money-visibility choices.
create or replace function public.linecrew_set_superintendent_permissions(
  target_user_id uuid,
  permissions jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor public.profiles%rowtype;
  target public.profiles%rowtype;
  item record;
  allowed_keys text[] := array[
    'company_settings','team_management','role_management',
    'customers_contracts','price_books','jobs','job_packages',
    'production_review','reporting','storm_mode','safety_records',
    'exports','ai_assistant'
  ];
begin
  select * into actor
  from public.profiles profile
  where profile.id = auth.uid();
  if actor.id is null or actor.active is not true or
     lower(coalesce(actor.role,'')) not in ('owner','admin') then
    raise exception using errcode = '42501',
      message = 'Active Owner or Admin access is required.';
  end if;

  select * into target
  from public.profiles profile
  where profile.id = target_user_id
    and profile.company_id = actor.company_id
  for update;
  if target.id is null then
    raise exception using errcode = 'P0002',
      message = 'Team member was not found in your company.';
  end if;
  if lower(coalesce(target.role,'')) <> 'superintendent' then
    raise exception using errcode = '42501',
      message = 'Operational permission overrides apply only to Superintendents.';
  end if;

  permissions := coalesce(permissions, '{}'::jsonb);
  if jsonb_typeof(permissions) <> 'object' then
    raise exception using errcode = '22023',
      message = 'Superintendent permissions must be a JSON object.';
  end if;
  for item in select key, value from jsonb_each(permissions)
  loop
    if not (item.key = any(allowed_keys)) then
      raise exception using errcode = '22023',
        message = format('Unsupported Superintendent capability: %s', item.key);
    end if;
    if jsonb_typeof(item.value) <> 'boolean' then
      raise exception using errcode = '22023',
        message = format('Superintendent capability %s must be true or false', item.key);
    end if;
  end loop;

  update public.profiles profile
  set role_permissions = permissions || jsonb_strip_nulls(jsonb_build_object(
    'actual_pricing', target.role_permissions -> 'actual_pricing',
    'field_pricing', target.role_permissions -> 'field_pricing'
  ))
  where profile.id = target.id
    and profile.company_id = actor.company_id;
end;
$$;

revoke all on function public.linecrew_set_superintendent_permissions(uuid,jsonb)
  from public, anon;
grant execute on function public.linecrew_set_superintendent_permissions(uuid,jsonb)
  to authenticated;

-- Replace the legacy role-list actual-price gates in the three detailed pricing
-- readers with the centralized per-member capability. Fail the migration if a
-- deployed definition no longer matches the reviewed shape.
do $migration$
declare
  signature text;
  original_definition text;
  secured_definition text;
begin
  foreach signature in array array[
    'public.get_price_book_items_for_user(uuid)',
    'public.get_daily_report_unit_catalog(uuid)',
    'public.get_daily_report_unit_locations_v2(uuid)'
  ]
  loop
    select pg_get_functiondef(to_regprocedure(signature))
    into original_definition;
    if original_definition is null then
      raise exception 'Required money reader is missing: %', signature;
    end if;

    secured_definition := regexp_replace(
      original_definition,
      'v_can_see_actual[[:space:]]*:=[[:space:]]*v_role[[:space:]]+in[[:space:]]*\([^;]+;',
      'v_can_see_actual := public.linecrew_has_capability(''actual_pricing'');'
    );
    if secured_definition = original_definition then
      raise exception 'Actual-money gate was not updated for %', signature;
    end if;
    execute secured_definition;
  end loop;
end;
$migration$;

create or replace function public.get_daily_report_value_summaries()
returns table(
  report_id uuid, unit_line_count bigint, actual_total numeric,
  adjusted_total numeric, visible_total numeric, has_adjustment boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_can_see_actual boolean;
  v_can_see_field boolean;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or not v_active or
     v_role not in ('foreman','gf','superintendent','admin','owner') then
    raise exception using
      errcode = '42501',
      message = 'An active company production profile is required.';
  end if;

  v_can_see_actual := public.linecrew_has_capability('actual_pricing');
  v_can_see_field := public.linecrew_has_capability('field_pricing');

  return query
  select report.id, count(unit.id),
    case when v_can_see_actual then coalesce(sum(
      greatest(unit.install_quantity - coalesce(location.transfer_quantity, 0), 0) * unit.actual_install_price +
      coalesce(location.transfer_quantity, 0) * unit.actual_transfer_price +
      unit.retirement_quantity * unit.actual_retirement_price
    ), 0) else null end,
    case when v_can_see_field then coalesce(sum(
      greatest(unit.install_quantity - coalesce(location.transfer_quantity, 0), 0) * unit.adjusted_install_price +
      coalesce(location.transfer_quantity, 0) * unit.adjusted_transfer_price +
      unit.retirement_quantity * unit.adjusted_retirement_price
    ), 0) else null end,
    case
      when v_can_see_actual then coalesce(sum(
        greatest(unit.install_quantity - coalesce(location.transfer_quantity, 0), 0) * unit.actual_install_price +
        coalesce(location.transfer_quantity, 0) * unit.actual_transfer_price +
        unit.retirement_quantity * unit.actual_retirement_price
      ), 0)
      when v_can_see_field then coalesce(sum(
        greatest(unit.install_quantity - coalesce(location.transfer_quantity, 0), 0) * unit.adjusted_install_price +
        coalesce(location.transfer_quantity, 0) * unit.adjusted_transfer_price +
        unit.retirement_quantity * unit.adjusted_retirement_price
      ), 0)
      else null
    end,
    coalesce(bool_or(unit.has_adjustment), false)
  from public.daily_reports report
  left join public.daily_production_units unit
    on unit.daily_report_id = report.id
   and unit.company_id = report.company_id
  left join lateral (
    select sum(detail.transfer_quantity) transfer_quantity
    from public.daily_production_unit_locations detail
    where detail.daily_production_unit_id = unit.id
      and detail.company_id = unit.company_id
  ) location on true
  where report.company_id = v_company_id
    and (
      v_role in ('admin','owner','gf','superintendent') or
      report.created_by = auth.uid()
    )
  group by report.id;
end;
$$;

revoke all on function public.get_daily_report_value_summaries() from public, anon;
grant execute on function public.get_daily_report_value_summaries() to authenticated;
