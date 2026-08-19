-- Generated capability-aware Superintendent compatibility layer.
-- Applies after Owner/Superintendent foundation migrations.
-- Existing Admin/Owner/GF/Foreman behavior is preserved; Superintendent access is gated by the named capability.
-- SQL-language helper functions without a PL/pgSQL BEGIN block are intentionally left unchanged.

begin;

-- Source: 20260815_link_jobs_to_contracts.sql
-- Superintendent capability: jobs
create or replace function public.create_contract_job(
  p_contract_id uuid,
  p_job_number text,
  p_job_name text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_customer_name text;
  v_job_id uuid;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('jobs') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have jobs permission.';
  end if;
  select p.company_id, lower(coalesce(p.role, '')), p.active
  into v_company_id, v_role, v_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin', 'gf', 'owner', 'superintendent') then
    raise exception using
      errcode = '42501',
      message = 'Only an active Admin or General Foreman can create jobs.';
  end if;

  if length(trim(coalesce(p_job_number, ''))) = 0 or
     length(trim(coalesce(p_job_name, ''))) = 0 then
    raise exception using
      errcode = '22023',
      message = 'Job number and job name are required.';
  end if;

  select customer.name
  into v_customer_name
  from public.contracts contract
  join public.customers customer
    on customer.id = contract.customer_id
   and customer.company_id = contract.company_id
  where contract.id = p_contract_id
    and contract.company_id = v_company_id
    and contract.active is true;

  if v_customer_name is null then
    raise exception using
      errcode = 'P0002',
      message = 'Active contract was not found in your company.';
  end if;

  insert into public.jobs (
    company_id,
    contract_id,
    job_number,
    job_name,
    customer_name,
    utility_name,
    active
  ) values (
    v_company_id,
    p_contract_id,
    trim(p_job_number),
    trim(p_job_name),
    v_customer_name,
    v_customer_name,
    true
  )
  returning id into v_job_id;

  return v_job_id;
end;
$$;

-- Source: 20260815_link_jobs_to_contracts.sql
-- Superintendent capability: jobs
create or replace function public.update_contract_job(
  p_job_id uuid,
  p_contract_id uuid,
  p_job_number text,
  p_job_name text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_customer_name text;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('jobs') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have jobs permission.';
  end if;
  select p.company_id, lower(coalesce(p.role, '')), p.active
  into v_company_id, v_role, v_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin', 'gf', 'owner', 'superintendent') then
    raise exception using
      errcode = '42501',
      message = 'Only an active Admin or General Foreman can update jobs.';
  end if;

  if length(trim(coalesce(p_job_number, ''))) = 0 or
     length(trim(coalesce(p_job_name, ''))) = 0 then
    raise exception using
      errcode = '22023',
      message = 'Job number and job name are required.';
  end if;

  select customer.name
  into v_customer_name
  from public.contracts contract
  join public.customers customer
    on customer.id = contract.customer_id
   and customer.company_id = contract.company_id
  where contract.id = p_contract_id
    and contract.company_id = v_company_id
    and contract.active is true;

  if v_customer_name is null then
    raise exception using
      errcode = 'P0002',
      message = 'Active contract was not found in your company.';
  end if;

  update public.jobs
  set
    contract_id = p_contract_id,
    job_number = trim(p_job_number),
    job_name = trim(p_job_name),
    customer_name = v_customer_name,
    utility_name = v_customer_name
  where id = p_job_id
    and company_id = v_company_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Job was not found in your company.';
  end if;
end;
$$;

-- Source: 20260815_secure_daily_unit_production.sql
-- Superintendent capability: production_review
create or replace function public.get_daily_report_unit_catalog(
  p_report_id uuid
)
returns table (
  price_book_item_id uuid,
  item_code text,
  item_name text,
  description text,
  unit_of_measure text,
  category text,
  install_price numeric,
  retirement_price numeric,
  actual_install_price numeric,
  actual_retirement_price numeric,
  adjusted_install_price numeric,
  adjusted_retirement_price numeric,
  has_adjustment boolean,
  install_quantity numeric,
  retirement_quantity numeric,
  actual_line_value numeric,
  adjusted_line_value numeric,
  visible_line_value numeric
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_profile_active boolean;
  v_report_company_id uuid;
  v_job_id uuid;
  v_contract_id uuid;
  v_price_book_id uuid;
  v_report_creator uuid;
  v_work_date date;
  v_can_see_actual boolean;
  v_percent numeric;
  v_report_has_adjustment boolean;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  select p.company_id, lower(coalesce(p.role, '')), p.active
  into v_company_id, v_role, v_profile_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_profile_active is not true or
     v_role not in ('foreman', 'gf', 'admin', 'owner', 'superintendent') then
    raise exception using
      errcode = '42501',
      message = 'An active Foreman, General Foreman or Admin profile is required.';
  end if;

  select dr.company_id, dr.job_id, job.contract_id, dr.price_book_id,
         dr.created_by, dr.work_date, dr.field_value_percent_snapshot,
         dr.has_field_adjustment
  into v_report_company_id, v_job_id, v_contract_id, v_price_book_id,
       v_report_creator, v_work_date, v_percent,
       v_report_has_adjustment
  from public.daily_reports dr
  join public.jobs job
    on job.id = dr.job_id
   and job.company_id = dr.company_id
  where dr.id = p_report_id;

  if v_report_company_id is null or v_report_company_id <> v_company_id then
    raise exception using
      errcode = 'P0002',
      message = 'Daily report was not found in your company.';
  end if;

  if v_contract_id is null then
    raise exception using
      errcode = '22023',
      message = 'Assign this job to a contract before entering units.';
  end if;

  if v_role = 'foreman' and v_report_creator is distinct from auth.uid() then
    raise exception using
      errcode = '42501',
      message = 'Foremen can view unit production only on their own reports.';
  end if;

  if v_price_book_id is null then
    select pb.id
    into v_price_book_id
    from public.price_books pb
    where pb.company_id = v_company_id
      and pb.contract_id = v_contract_id
      and (pb.active is true or pb.effective_end is not null)
      and (pb.effective_start is null or pb.effective_start <= v_work_date)
      and (pb.effective_end is null or pb.effective_end >= v_work_date)
    order by pb.effective_start desc nulls last, pb.created_at desc
    limit 1;

    if v_price_book_id is null then
      raise exception using
        errcode = 'P0002',
        message = 'No active Price Book covers this report date.';
    end if;

    update public.daily_reports
    set price_book_id = v_price_book_id
    where id = p_report_id
      and company_id = v_company_id
      and price_book_id is null;
  end if;

  if not exists (
    select 1
    from public.price_books pb
    where pb.id = v_price_book_id
      and pb.company_id = v_company_id
      and pb.contract_id = v_contract_id
  ) then
    raise exception using
      errcode = '42501',
      message = 'The report Price Book does not belong to this contract.';
  end if;

  if v_percent is null then
    select setting.field_value_percent
    into v_percent
    from public.contract_field_settings setting
    where setting.contract_id = v_contract_id
      and setting.company_id = v_company_id;

    v_report_has_adjustment := v_percent is not null;
    v_percent := coalesce(v_percent, 100);

    update public.daily_reports
    set
      field_value_percent_snapshot = v_percent,
      has_field_adjustment = v_report_has_adjustment
    where id = p_report_id
      and company_id = v_company_id
      and field_value_percent_snapshot is null;
  end if;

  v_report_has_adjustment := coalesce(v_report_has_adjustment, false);

  v_can_see_actual := v_role in ('admin', 'gf', 'owner', 'superintendent');

  return query
  select
    item.id,
    item.item_code,
    item.item_name,
    item.description,
    item.unit_of_measure,
    item.category,
    case
      when v_can_see_actual then coalesce(line.actual_install_price, item.install_price)
      else coalesce(
        line.adjusted_install_price,
        round(item.install_price * v_percent / 100, 2)
      )
    end,
    case
      when v_can_see_actual then coalesce(line.actual_retirement_price, item.retirement_price)
      else coalesce(
        line.adjusted_retirement_price,
        round(item.retirement_price * v_percent / 100, 2)
      )
    end,
    case when v_can_see_actual
      then coalesce(line.actual_install_price, item.install_price)
      else null
    end,
    case when v_can_see_actual
      then coalesce(line.actual_retirement_price, item.retirement_price)
      else null
    end,
    coalesce(
      line.adjusted_install_price,
      round(item.install_price * v_percent / 100, 2)
    ),
    coalesce(
      line.adjusted_retirement_price,
      round(item.retirement_price * v_percent / 100, 2)
    ),
    coalesce(line.has_adjustment, v_report_has_adjustment),
    coalesce(line.install_quantity, 0),
    coalesce(line.retirement_quantity, 0),
    case when v_can_see_actual then
      round(
        coalesce(line.install_quantity, 0) *
          coalesce(line.actual_install_price, item.install_price) +
        coalesce(line.retirement_quantity, 0) *
          coalesce(line.actual_retirement_price, item.retirement_price),
        2
      )
    else null end,
    round(
      coalesce(line.install_quantity, 0) * coalesce(
        line.adjusted_install_price,
        round(item.install_price * v_percent / 100, 2)
      ) +
      coalesce(line.retirement_quantity, 0) * coalesce(
        line.adjusted_retirement_price,
        round(item.retirement_price * v_percent / 100, 2)
      ),
      2
    ),
    case when v_can_see_actual then
      round(
        coalesce(line.install_quantity, 0) *
          coalesce(line.actual_install_price, item.install_price) +
        coalesce(line.retirement_quantity, 0) *
          coalesce(line.actual_retirement_price, item.retirement_price),
        2
      )
    else
      round(
        coalesce(line.install_quantity, 0) * coalesce(
          line.adjusted_install_price,
          round(item.install_price * v_percent / 100, 2)
        ) +
        coalesce(line.retirement_quantity, 0) * coalesce(
          line.adjusted_retirement_price,
          round(item.retirement_price * v_percent / 100, 2)
        ),
        2
      )
    end
  from public.price_book_items item
  left join public.daily_production_units line
    on line.daily_report_id = p_report_id
   and line.price_book_item_id = item.id
   and line.company_id = v_company_id
  where item.price_book_id = v_price_book_id
    and item.company_id = v_company_id
    and (item.active is true or line.id is not null)
  order by item.active desc, item.item_code;
end;
$$;

-- Source: 20260815_secure_daily_unit_production.sql
-- Superintendent capability: production_review
create or replace function public.save_daily_report_unit(
  p_report_id uuid,
  p_price_book_item_id uuid,
  p_install_quantity numeric,
  p_retirement_quantity numeric
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_profile_active boolean;
  v_report_company_id uuid;
  v_job_id uuid;
  v_contract_id uuid;
  v_price_book_id uuid;
  v_report_creator uuid;
  v_report_status text;
  v_work_date date;
  v_item public.price_book_items%rowtype;
  v_percent numeric;
  v_has_adjustment boolean;
  v_line_id uuid;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  if coalesce(p_install_quantity, 0) < 0 or
     coalesce(p_retirement_quantity, 0) < 0 then
    raise exception using
      errcode = '22023',
      message = 'Unit quantities cannot be negative.';
  end if;

  if coalesce(p_install_quantity, 0) = 0 and
     coalesce(p_retirement_quantity, 0) = 0 then
    raise exception using
      errcode = '22023',
      message = 'Enter an installed or removed quantity.';
  end if;

  select p.company_id, lower(coalesce(p.role, '')), p.active
  into v_company_id, v_role, v_profile_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_profile_active is not true or
     v_role not in ('foreman', 'gf', 'admin', 'owner', 'superintendent') then
    raise exception using
      errcode = '42501',
      message = 'An active Foreman, General Foreman or Admin profile is required.';
  end if;

  select dr.company_id, dr.job_id, job.contract_id, dr.price_book_id,
         dr.created_by, lower(coalesce(dr.status, 'draft')), dr.work_date,
         dr.field_value_percent_snapshot, dr.has_field_adjustment
  into v_report_company_id, v_job_id, v_contract_id, v_price_book_id,
       v_report_creator, v_report_status, v_work_date,
       v_percent, v_has_adjustment
  from public.daily_reports dr
  join public.jobs job
    on job.id = dr.job_id
   and job.company_id = dr.company_id
  where dr.id = p_report_id;

  if v_report_company_id is null or v_report_company_id <> v_company_id then
    raise exception using
      errcode = 'P0002',
      message = 'Daily report was not found in your company.';
  end if;

  if v_report_status <> 'draft' then
    raise exception using
      errcode = '42501',
      message = 'Units can be changed only while the report is a draft.';
  end if;

  if v_role = 'foreman' and v_report_creator is distinct from auth.uid() then
    raise exception using
      errcode = '42501',
      message = 'Foremen can change units only on their own reports.';
  end if;

  if v_contract_id is null then
    raise exception using
      errcode = '22023',
      message = 'Assign this job to a contract before entering units.';
  end if;

  if v_price_book_id is null then
    select pb.id
    into v_price_book_id
    from public.price_books pb
    where pb.company_id = v_company_id
      and pb.contract_id = v_contract_id
      and (pb.active is true or pb.effective_end is not null)
      and (pb.effective_start is null or pb.effective_start <= v_work_date)
      and (pb.effective_end is null or pb.effective_end >= v_work_date)
    order by pb.effective_start desc nulls last, pb.created_at desc
    limit 1;

    if v_price_book_id is null then
      raise exception using
        errcode = 'P0002',
        message = 'No active Price Book covers this report date.';
    end if;

    update public.daily_reports
    set price_book_id = v_price_book_id
    where id = p_report_id
      and company_id = v_company_id
      and price_book_id is null;
  end if;

  if not exists (
    select 1
    from public.price_books pb
    where pb.id = v_price_book_id
      and pb.company_id = v_company_id
      and pb.contract_id = v_contract_id
  ) then
    raise exception using
      errcode = '42501',
      message = 'The report Price Book does not belong to this contract.';
  end if;

  select item.*
  into v_item
  from public.price_book_items item
  where item.id = p_price_book_item_id
    and item.company_id = v_company_id
    and item.price_book_id = v_price_book_id
    and (
      item.active is true or
      exists (
        select 1
        from public.daily_production_units existing_line
        where existing_line.daily_report_id = p_report_id
          and existing_line.price_book_item_id = item.id
          and existing_line.company_id = v_company_id
      )
    );

  if v_item.id is null then
    raise exception using
      errcode = 'P0002',
      message = 'Unit was not found in this report Price Book.';
  end if;

  if v_percent is null then
    select setting.field_value_percent
    into v_percent
    from public.contract_field_settings setting
    where setting.contract_id = v_contract_id
      and setting.company_id = v_company_id;

    v_has_adjustment := v_percent is not null;
    v_percent := coalesce(v_percent, 100);

    update public.daily_reports
    set
      field_value_percent_snapshot = v_percent,
      has_field_adjustment = v_has_adjustment
    where id = p_report_id
      and company_id = v_company_id
      and field_value_percent_snapshot is null;
  end if;

  v_has_adjustment := coalesce(v_has_adjustment, false);

  insert into public.daily_production_units (
    company_id,
    daily_report_id,
    job_id,
    contract_id,
    price_book_id,
    price_book_item_id,
    item_code,
    item_name,
    description,
    unit_of_measure,
    category,
    install_quantity,
    retirement_quantity,
    actual_install_price,
    actual_retirement_price,
    adjusted_install_price,
    adjusted_retirement_price,
    field_value_percent_snapshot,
    has_adjustment,
    created_by,
    updated_at
  ) values (
    v_company_id,
    p_report_id,
    v_job_id,
    v_contract_id,
    v_price_book_id,
    v_item.id,
    v_item.item_code,
    v_item.item_name,
    v_item.description,
    v_item.unit_of_measure,
    v_item.category,
    coalesce(p_install_quantity, 0),
    coalesce(p_retirement_quantity, 0),
    v_item.install_price,
    v_item.retirement_price,
    round(v_item.install_price * v_percent / 100, 2),
    round(v_item.retirement_price * v_percent / 100, 2),
    v_percent,
    v_has_adjustment,
    auth.uid(),
    now()
  )
  on conflict (daily_report_id, price_book_item_id) do update
  set
    install_quantity = excluded.install_quantity,
    retirement_quantity = excluded.retirement_quantity,
    item_code = excluded.item_code,
    item_name = excluded.item_name,
    description = excluded.description,
    unit_of_measure = excluded.unit_of_measure,
    category = excluded.category,
    actual_install_price = excluded.actual_install_price,
    actual_retirement_price = excluded.actual_retirement_price,
    adjusted_install_price = excluded.adjusted_install_price,
    adjusted_retirement_price = excluded.adjusted_retirement_price,
    field_value_percent_snapshot = excluded.field_value_percent_snapshot,
    has_adjustment = excluded.has_adjustment,
    updated_at = now()
  returning id into v_line_id;

  return v_line_id;
end;
$$;

-- Source: 20260815_secure_daily_unit_production.sql
-- Superintendent capability: production_review
create or replace function public.delete_daily_report_unit(
  p_report_id uuid,
  p_price_book_item_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_profile_active boolean;
  v_report_creator uuid;
  v_report_status text;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  select p.company_id, lower(coalesce(p.role, '')), p.active
  into v_company_id, v_role, v_profile_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_profile_active is not true or
     v_role not in ('foreman', 'gf', 'admin', 'owner', 'superintendent') then
    raise exception using
      errcode = '42501',
      message = 'An active Foreman, General Foreman or Admin profile is required.';
  end if;

  select dr.created_by, lower(coalesce(dr.status, 'draft'))
  into v_report_creator, v_report_status
  from public.daily_reports dr
  where dr.id = p_report_id
    and dr.company_id = v_company_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Daily report was not found in your company.';
  end if;

  if v_report_status <> 'draft' then
    raise exception using
      errcode = '42501',
      message = 'Units can be changed only while the report is a draft.';
  end if;

  if v_role = 'foreman' and v_report_creator is distinct from auth.uid() then
    raise exception using
      errcode = '42501',
      message = 'Foremen can change units only on their own reports.';
  end if;

  delete from public.daily_production_units
  where daily_report_id = p_report_id
    and price_book_item_id = p_price_book_item_id
    and company_id = v_company_id;
end;
$$;

-- Source: 20260815_secure_daily_unit_production.sql
-- Superintendent capability: production_review
create or replace function public.get_daily_report_value_summaries()
returns table (
  report_id uuid,
  unit_line_count bigint,
  actual_total numeric,
  adjusted_total numeric,
  visible_total numeric,
  has_adjustment boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_profile_active boolean;
  v_can_see_actual boolean;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  select p.company_id, lower(coalesce(p.role, '')), p.active
  into v_company_id, v_role, v_profile_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_profile_active is not true or
     v_role not in ('foreman', 'gf', 'admin', 'owner', 'superintendent') then
    raise exception using
      errcode = '42501',
      message = 'An active Foreman, General Foreman or Admin profile is required.';
  end if;

  v_can_see_actual := v_role in ('admin', 'gf', 'owner', 'superintendent');

  return query
  select
    dr.id,
    count(line.id),
    case when v_can_see_actual then coalesce(sum(
      line.install_quantity * line.actual_install_price +
      line.retirement_quantity * line.actual_retirement_price
    ), 0) else null end,
    coalesce(sum(
      line.install_quantity * line.adjusted_install_price +
      line.retirement_quantity * line.adjusted_retirement_price
    ), 0),
    case when v_can_see_actual then coalesce(sum(
      line.install_quantity * line.actual_install_price +
      line.retirement_quantity * line.actual_retirement_price
    ), 0) else coalesce(sum(
      line.install_quantity * line.adjusted_install_price +
      line.retirement_quantity * line.adjusted_retirement_price
    ), 0) end,
    coalesce(bool_or(line.has_adjustment), false)
  from public.daily_reports dr
  left join public.daily_production_units line
    on line.daily_report_id = dr.id
   and line.company_id = dr.company_id
  where dr.company_id = v_company_id
    and (v_role in ('admin', 'gf', 'owner', 'superintendent') or dr.created_by = auth.uid())
  group by dr.id;
end;
$$;

-- Source: 20260815_secure_field_value_pricing.sql
-- Superintendent capability: actual_pricing
create or replace function public.set_contract_field_value_percent(
  p_contract_id uuid,
  p_field_value_percent numeric
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_profile_active boolean;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('actual_pricing') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have actual pricing permission.';
  end if;
  if p_contract_id is null then
    raise exception using
      errcode = '22004',
      message = 'Contract is required.';
  end if;

  if p_field_value_percent is not null and
     (p_field_value_percent < 0 or p_field_value_percent > 100) then
    raise exception using
      errcode = '22023',
      message = 'Field Value must be between 0% and 100%.';
  end if;

  select company_id, lower(coalesce(role, '')), active
  into v_company_id, v_role, v_profile_active
  from public.profiles
  where id = auth.uid();

  if v_company_id is null or
     v_role not in ('admin','owner','superintendent') or
     v_profile_active is not true then
    raise exception using
      errcode = '42501',
      message = 'Only an active company Admin can change Field Value settings.';
  end if;

  if not exists (
    select 1
    from public.contracts
    where id = p_contract_id
      and company_id = v_company_id
  ) then
    raise exception using
      errcode = 'P0002',
      message = 'Contract was not found in your company.';
  end if;

  if p_field_value_percent is null then
    delete from public.contract_field_settings
    where contract_id = p_contract_id
      and company_id = v_company_id;
  else
    insert into public.contract_field_settings (
      contract_id,
      company_id,
      field_value_percent,
      updated_by,
      updated_at
    ) values (
      p_contract_id,
      v_company_id,
      p_field_value_percent,
      auth.uid(),
      now()
    )
    on conflict (contract_id) do update
    set
      field_value_percent = excluded.field_value_percent,
      updated_by = excluded.updated_by,
      updated_at = now()
    where public.contract_field_settings.company_id = v_company_id;
  end if;
end;
$$;

-- Source: 20260815_secure_field_value_pricing.sql
-- Superintendent capability: price_books
create or replace function public.get_price_book_items_for_user(
  p_price_book_id uuid
)
returns table (
  id uuid,
  company_id uuid,
  price_book_id uuid,
  item_code text,
  item_name text,
  description text,
  install_price numeric,
  retirement_price numeric,
  unit_of_measure text,
  category text,
  extra_data jsonb,
  active boolean,
  created_at timestamptz,
  updated_at timestamptz,
  actual_install_price numeric,
  actual_retirement_price numeric,
  adjusted_install_price numeric,
  adjusted_retirement_price numeric,
  has_adjustment boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_profile_active boolean;
  v_can_see_actual boolean;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('price_books') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have price books permission.';
  end if;
  if p_price_book_id is null then
    raise exception using
      errcode = '22004',
      message = 'Price Book is required.';
  end if;

  select p.company_id, lower(coalesce(p.role, '')), p.active
  into v_company_id, v_role, v_profile_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_profile_active is not true then
    raise exception using
      errcode = '42501',
      message = 'An active company profile is required.';
  end if;

  if v_role not in ('foreman', 'gf', 'admin', 'owner', 'superintendent') then
    raise exception using
      errcode = '42501',
      message = 'Your role cannot view contract unit values.';
  end if;

  if not exists (
    select 1
    from public.price_books pb
    where pb.id = p_price_book_id
      and pb.company_id = v_company_id
  ) then
    raise exception using
      errcode = 'P0002',
      message = 'Price Book was not found in your company.';
  end if;

  v_can_see_actual := v_role in ('admin', 'gf', 'owner', 'superintendent');

  return query
  select
    i.id,
    i.company_id,
    i.price_book_id,
    i.item_code,
    i.item_name,
    i.description,
    case
      when v_can_see_actual then i.install_price
      else round(
        i.install_price * coalesce(s.field_value_percent, 100) / 100,
        2
      )
    end,
    case
      when v_can_see_actual then i.retirement_price
      else round(
        i.retirement_price * coalesce(s.field_value_percent, 100) / 100,
        2
      )
    end,
    i.unit_of_measure,
    i.category,
    i.extra_data,
    i.active,
    i.created_at,
    i.updated_at,
    case when v_can_see_actual then i.install_price else null end,
    case when v_can_see_actual then i.retirement_price else null end,
    round(
      i.install_price * coalesce(s.field_value_percent, 100) / 100,
      2
    ),
    round(
      i.retirement_price * coalesce(s.field_value_percent, 100) / 100,
      2
    ),
    s.field_value_percent is not null
  from public.price_book_items i
  join public.price_books pb
    on pb.id = i.price_book_id
   and pb.company_id = i.company_id
  left join public.contract_field_settings s
    on s.contract_id = pb.contract_id
   and s.company_id = i.company_id
  where i.price_book_id = p_price_book_id
    and i.company_id = v_company_id
  order by i.active desc, i.item_code asc;
end;
$$;

-- Source: 20260815_secure_join_code_rotation.sql
-- Superintendent capability: team_management
create or replace function public.rotate_company_join_code()
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_profile_active boolean;
  v_new_code text;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('team_management') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have team management permission.';
  end if;
  select company_id, lower(coalesce(role, '')), active
  into v_company_id, v_role, v_profile_active
  from public.profiles
  where id = auth.uid();

  if v_company_id is null or
     v_role not in ('admin','owner','superintendent') or
     v_profile_active is not true then
    raise exception using
      errcode = '42501',
      message = 'Only an active company Admin can generate a new company code.';
  end if;

  loop
    v_new_code := upper(
      substr(
        replace(gen_random_uuid()::text, '-', ''),
        1,
        8
      )
    );

    exit when not exists (
      select 1
      from public.companies
      where upper(btrim(join_code)) = v_new_code
    );
  end loop;

  update public.companies
  set join_code = v_new_code
  where id = v_company_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Company was not found.';
  end if;

  return v_new_code;
end;
$$;

-- Source: 20260815_secure_team_suspension.sql
-- Superintendent capability: price_books
create or replace function public.set_price_book_active(
  p_price_book_id uuid,
  p_active boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_profile_active boolean;
  v_target public.price_books%rowtype;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('price_books') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have price books permission.';
  end if;
  if p_price_book_id is null or p_active is null then
    raise exception using
      errcode = '22004',
      message = 'Price Book ID and active status are required.';
  end if;

  select company_id, role, active
  into v_company_id, v_role, v_profile_active
  from public.profiles
  where id = auth.uid();

  if v_company_id is null or
     lower(coalesce(v_role, '')) not in ('admin','owner','superintendent') or
     v_profile_active is not true then
    raise exception using
      errcode = '42501',
      message = 'Only an active company Admin can change Price Book status.';
  end if;

  select *
  into v_target
  from public.price_books
  where id = p_price_book_id
    and company_id = v_company_id
  for update;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Price Book not found for the current company.';
  end if;

  if p_active then
    update public.price_books
    set active = false, updated_at = now()
    where company_id = v_company_id
      and id <> v_target.id
      and contract_id is not distinct from v_target.contract_id
      and coalesce(lower(btrim(name)), '') =
        coalesce(lower(btrim(v_target.name)), '')
      and active is true;
  end if;

  update public.price_books
  set active = p_active, updated_at = now()
  where id = v_target.id
    and company_id = v_company_id;
end;
$$;

-- Source: 20260816_daily_report_audit_history.sql
-- Superintendent capability: production_review
create or replace function public.record_daily_report_audit_event()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_event_type text;
  v_actor_name text;
  v_actor_role text;
  v_notes text;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  if tg_op = 'INSERT' then
    v_event_type := 'created';
  elsif old.archived is distinct from new.archived then
    v_event_type := case when new.archived then 'archived' else 'restored' end;
  elsif lower(coalesce(old.status, 'draft')) is distinct from
        lower(coalesce(new.status, 'draft')) then
    v_event_type := case lower(coalesce(new.status, 'draft'))
      when 'submitted' then 'submitted'
      when 'approved' then 'approved'
      when 'draft' then 'returned'
      else null
    end;
  end if;

  if v_event_type is null then
    return new;
  end if;

  select profile.full_name, lower(coalesce(profile.role, ''))
  into v_actor_name, v_actor_role
  from public.profiles profile
  where profile.id = auth.uid()
    and profile.company_id = new.company_id;

  v_notes := case
    when v_event_type = 'approved' and new.redline_override_reason is not null
      then 'Admin redline override: ' || new.redline_override_reason
    when v_event_type in ('approved', 'returned')
      then nullif(btrim(coalesce(new.review_notes, '')), '')
    else null
  end;

  insert into public.daily_report_audit_events (
    company_id,
    daily_report_id,
    event_type,
    actor_id,
    actor_name,
    actor_role,
    event_notes
  ) values (
    new.company_id,
    new.id,
    v_event_type,
    auth.uid(),
    coalesce(v_actor_name, 'System'),
    nullif(v_actor_role, ''),
    v_notes
  );

  return new;
end;
$$;

-- Source: 20260816_daily_report_audit_history.sql
-- Superintendent capability: production_review
create or replace function public.get_daily_report_audit_history(p_report_id uuid)
returns table (
  event_id uuid,
  event_type text,
  actor_name text,
  actor_role text,
  event_notes text,
  event_at timestamptz
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
  v_report_company_id uuid;
  v_created_by uuid;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  select report.company_id, report.created_by
  into v_report_company_id, v_created_by
  from public.daily_reports report
  where report.id = p_report_id;

  if v_active is not true or v_company_id is null or
     v_report_company_id is null or v_report_company_id <> v_company_id or
     (v_role not in ('admin', 'gf', 'owner', 'superintendent') and v_created_by <> auth.uid()) then
    raise exception using errcode = '42501',
      message = 'You cannot view this daily report history.';
  end if;

  return query
  select
    audit.id,
    audit.event_type,
    audit.actor_name,
    audit.actor_role,
    audit.event_notes,
    audit.created_at
  from public.daily_report_audit_events audit
  where audit.daily_report_id = p_report_id
    and audit.company_id = v_company_id
  order by audit.created_at desc, audit.id desc;
end;
$$;

-- Source: 20260816_daily_report_cleanup.sql
-- Superintendent capability: production_review
create or replace function public.delete_draft_daily_report(p_report_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role not in ('admin','owner','superintendent') then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin can delete draft daily reports.';
  end if;

  delete from public.daily_reports report
  where report.id = p_report_id
    and report.company_id = v_company_id
    and lower(coalesce(report.status, 'draft')) = 'draft';

  if not found then
    raise exception using errcode = 'P0002',
      message = 'Draft report was not found in your company. Submitted and approved reports must be archived.';
  end if;
end;
$$;

-- Source: 20260816_daily_report_cleanup.sql
-- Superintendent capability: production_review
create or replace function public.set_daily_report_archived(
  p_report_id uuid,
  p_archived boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role not in ('admin','owner','superintendent') then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin can archive daily reports.';
  end if;

  update public.daily_reports report
  set archived = coalesce(p_archived, false)
  where report.id = p_report_id
    and report.company_id = v_company_id
    and (
      coalesce(p_archived, false) is false or
      lower(coalesce(report.status, '')) = 'approved'
    );

  if not found then
    raise exception using errcode = 'P0002',
      message = 'Only approved reports can be archived. Draft reports may be deleted instead.';
  end if;
end;
$$;

-- Source: 20260816_daily_report_review_queue.sql
-- Superintendent capability: production_review
create or replace function public.set_company_redline_approval_requirement(
  p_required boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role not in ('admin','owner','superintendent') then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin can change redline approval requirements.';
  end if;

  update public.companies company
  set require_gf_redline_approval = coalesce(p_required, false)
  where company.id = v_company_id;
end;
$$;

-- Source: 20260816_daily_report_review_queue.sql
-- Superintendent capability: production_review
create or replace function public.get_daily_report_authorization_summaries()
returns table (
  report_id uuid,
  unit_entry_count bigint,
  authorized_count bigint,
  pending_packet_count bigint,
  redline_count bigint
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
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin', 'gf', 'owner', 'superintendent') then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin or General Foreman can view the review queue.';
  end if;

  return query
  select
    report.id,
    count(location.location_line_id),
    count(*) filter (where location.authorization_status = 'authorized'),
    count(*) filter (where location.authorization_status = 'pending_packet'),
    count(*) filter (where location.authorization_status = 'redline')
  from public.daily_reports report
  left join lateral public.get_daily_report_unit_locations(report.id) location
    on true
  where report.company_id = v_company_id
  group by report.id;
end;
$$;

-- Source: 20260816_daily_report_review_queue.sql
-- Superintendent capability: production_review
create or replace function public.approve_daily_report(
  p_report_id uuid,
  p_review_notes text default null
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_report_company_id uuid;
  v_report_status text;
  v_require_gf boolean;
  v_redline_count bigint;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin', 'gf', 'owner', 'superintendent') then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin or General Foreman can approve reports.';
  end if;

  select report.company_id, lower(coalesce(report.status, 'draft'))
  into v_report_company_id, v_report_status
  from public.daily_reports report
  where report.id = p_report_id;

  if v_report_company_id is null or v_report_company_id <> v_company_id then
    raise exception using errcode = 'P0002',
      message = 'Daily report was not found in your company.';
  end if;

  if v_report_status <> 'submitted' then
    raise exception using errcode = '23514',
      message = 'Only submitted reports can be approved.';
  end if;

  select company.require_gf_redline_approval
  into v_require_gf
  from public.companies company
  where company.id = v_company_id;

  select count(*)
  into v_redline_count
  from public.get_daily_report_unit_locations(p_report_id) location
  where location.authorization_status = 'redline';

  if coalesce(v_require_gf, false) and v_redline_count > 0 and v_role in ('admin','owner','superintendent') and
     nullif(btrim(coalesce(p_review_notes, '')), '') is null then
    raise exception using errcode = '22023',
      message = 'Enter an Admin override reason because this company requires GF approval for redlines.';
  end if;

  update public.daily_reports report
  set
    status = 'approved',
    review_notes = nullif(btrim(coalesce(p_review_notes, '')), ''),
    redline_override_by = case
      when coalesce(v_require_gf, false) and v_redline_count > 0 and v_role in ('admin','owner','superintendent')
        then auth.uid() else null end,
    redline_override_reason = case
      when coalesce(v_require_gf, false) and v_redline_count > 0 and v_role in ('admin','owner','superintendent')
        then btrim(p_review_notes) else null end,
    redline_override_at = case
      when coalesce(v_require_gf, false) and v_redline_count > 0 and v_role in ('admin','owner','superintendent')
        then now() else null end
  where report.id = p_report_id
    and report.company_id = v_company_id;
end;
$$;

-- Source: 20260816_daily_unit_pole_locations.sql
-- Superintendent capability: production_review
create or replace function public.get_daily_report_unit_locations(
  p_report_id uuid
)
returns table (
  location_line_id uuid,
  price_book_item_id uuid,
  item_code text,
  item_name text,
  description text,
  unit_of_measure text,
  category text,
  pole_location text,
  install_price numeric,
  retirement_price numeric,
  actual_install_price numeric,
  actual_retirement_price numeric,
  adjusted_install_price numeric,
  adjusted_retirement_price numeric,
  has_adjustment boolean,
  install_quantity numeric,
  retirement_quantity numeric,
  actual_line_value numeric,
  adjusted_line_value numeric,
  visible_line_value numeric
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_profile_active boolean;
  v_report_company_id uuid;
  v_report_creator uuid;
  v_can_see_actual boolean;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_profile_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_profile_active is not true or
     v_role not in ('foreman', 'gf', 'admin', 'owner', 'superintendent') then
    raise exception using
      errcode = '42501',
      message = 'An active Foreman, General Foreman or Admin profile is required.';
  end if;

  select report.company_id, report.created_by
  into v_report_company_id, v_report_creator
  from public.daily_reports report
  where report.id = p_report_id;

  if v_report_company_id is null or v_report_company_id <> v_company_id then
    raise exception using
      errcode = 'P0002',
      message = 'Daily report was not found in your company.';
  end if;

  if v_role = 'foreman' and v_report_creator is distinct from auth.uid() then
    raise exception using
      errcode = '42501',
      message = 'Foremen can view unit production only on their own reports.';
  end if;

  v_can_see_actual := v_role in ('admin', 'gf', 'owner', 'superintendent');

  return query
  select
    location_line.id,
    aggregate_line.price_book_item_id,
    aggregate_line.item_code,
    aggregate_line.item_name,
    aggregate_line.description,
    aggregate_line.unit_of_measure,
    aggregate_line.category,
    location_line.pole_location,
    case when v_can_see_actual
      then aggregate_line.actual_install_price
      else aggregate_line.adjusted_install_price
    end,
    case when v_can_see_actual
      then aggregate_line.actual_retirement_price
      else aggregate_line.adjusted_retirement_price
    end,
    case when v_can_see_actual
      then aggregate_line.actual_install_price
      else null
    end,
    case when v_can_see_actual
      then aggregate_line.actual_retirement_price
      else null
    end,
    aggregate_line.adjusted_install_price,
    aggregate_line.adjusted_retirement_price,
    aggregate_line.has_adjustment,
    location_line.install_quantity,
    location_line.retirement_quantity,
    case when v_can_see_actual then round(
      location_line.install_quantity * aggregate_line.actual_install_price +
      location_line.retirement_quantity * aggregate_line.actual_retirement_price,
      2
    ) else null end,
    round(
      location_line.install_quantity * aggregate_line.adjusted_install_price +
      location_line.retirement_quantity * aggregate_line.adjusted_retirement_price,
      2
    ),
    case when v_can_see_actual then round(
      location_line.install_quantity * aggregate_line.actual_install_price +
      location_line.retirement_quantity * aggregate_line.actual_retirement_price,
      2
    ) else round(
      location_line.install_quantity * aggregate_line.adjusted_install_price +
      location_line.retirement_quantity * aggregate_line.adjusted_retirement_price,
      2
    ) end
  from public.daily_production_unit_locations location_line
  join public.daily_production_units aggregate_line
    on aggregate_line.id = location_line.daily_production_unit_id
   and aggregate_line.company_id = location_line.company_id
   and aggregate_line.daily_report_id = location_line.daily_report_id
   and aggregate_line.price_book_item_id = location_line.price_book_item_id
  where location_line.daily_report_id = p_report_id
    and location_line.company_id = v_company_id
  order by
    location_line.pole_location_key,
    aggregate_line.item_code;
end;
$$;

-- Source: 20260816_daily_unit_pole_locations.sql
-- Superintendent capability: production_review
create or replace function public.save_daily_report_unit_location(
  p_report_id uuid,
  p_price_book_item_id uuid,
  p_pole_location text,
  p_install_quantity numeric,
  p_retirement_quantity numeric
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_profile_active boolean;
  v_report_company_id uuid;
  v_report_creator uuid;
  v_report_status text;
  v_location text;
  v_total_install numeric;
  v_total_retirement numeric;
  v_aggregate_line_id uuid;
  v_location_line_id uuid;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  v_location := btrim(coalesce(p_pole_location, ''));

  if length(v_location) = 0 then
    raise exception using
      errcode = '22023',
      message = 'Enter a pole or work location.';
  end if;

  if coalesce(p_install_quantity, 0) < 0 or
     coalesce(p_retirement_quantity, 0) < 0 or
     (
       coalesce(p_install_quantity, 0) = 0 and
       coalesce(p_retirement_quantity, 0) = 0
     ) then
    raise exception using
      errcode = '22023',
      message = 'Enter an installed or removed quantity greater than zero.';
  end if;

  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_profile_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_profile_active is not true or
     v_role not in ('foreman', 'gf', 'admin', 'owner', 'superintendent') then
    raise exception using
      errcode = '42501',
      message = 'An active Foreman, General Foreman or Admin profile is required.';
  end if;

  select report.company_id, report.created_by,
         lower(coalesce(report.status, 'draft'))
  into v_report_company_id, v_report_creator, v_report_status
  from public.daily_reports report
  where report.id = p_report_id;

  if v_report_company_id is null or v_report_company_id <> v_company_id then
    raise exception using
      errcode = 'P0002',
      message = 'Daily report was not found in your company.';
  end if;

  if v_report_status <> 'draft' then
    raise exception using
      errcode = '42501',
      message = 'Units can be changed only while the report is a draft.';
  end if;

  if v_role = 'foreman' and v_report_creator is distinct from auth.uid() then
    raise exception using
      errcode = '42501',
      message = 'Foremen can change units only on their own reports.';
  end if;

  select
    coalesce(sum(location_line.install_quantity), 0) +
      coalesce(p_install_quantity, 0),
    coalesce(sum(location_line.retirement_quantity), 0) +
      coalesce(p_retirement_quantity, 0)
  into v_total_install, v_total_retirement
  from public.daily_production_unit_locations location_line
  where location_line.daily_report_id = p_report_id
    and location_line.price_book_item_id = p_price_book_item_id
    and location_line.company_id = v_company_id
    and location_line.pole_location_key <> lower(v_location);

  v_aggregate_line_id := public.save_daily_report_unit(
    p_report_id,
    p_price_book_item_id,
    v_total_install,
    v_total_retirement
  );

  insert into public.daily_production_unit_locations (
    company_id,
    daily_report_id,
    daily_production_unit_id,
    price_book_item_id,
    pole_location,
    install_quantity,
    retirement_quantity,
    created_by,
    updated_at
  ) values (
    v_company_id,
    p_report_id,
    v_aggregate_line_id,
    p_price_book_item_id,
    v_location,
    coalesce(p_install_quantity, 0),
    coalesce(p_retirement_quantity, 0),
    auth.uid(),
    now()
  )
  on conflict (daily_report_id, price_book_item_id, pole_location_key)
  do update set
    daily_production_unit_id = excluded.daily_production_unit_id,
    pole_location = excluded.pole_location,
    install_quantity = excluded.install_quantity,
    retirement_quantity = excluded.retirement_quantity,
    updated_at = now()
  returning id into v_location_line_id;

  return v_location_line_id;
end;
$$;

-- Source: 20260816_daily_unit_pole_locations.sql
-- Superintendent capability: production_review
create or replace function public.delete_daily_report_unit_location(
  p_report_id uuid,
  p_price_book_item_id uuid,
  p_pole_location text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_profile_active boolean;
  v_report_company_id uuid;
  v_report_creator uuid;
  v_report_status text;
  v_total_install numeric;
  v_total_retirement numeric;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_profile_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_profile_active is not true or
     v_role not in ('foreman', 'gf', 'admin', 'owner', 'superintendent') then
    raise exception using
      errcode = '42501',
      message = 'An active Foreman, General Foreman or Admin profile is required.';
  end if;

  select report.company_id, report.created_by,
         lower(coalesce(report.status, 'draft'))
  into v_report_company_id, v_report_creator, v_report_status
  from public.daily_reports report
  where report.id = p_report_id;

  if v_report_company_id is null or v_report_company_id <> v_company_id then
    raise exception using
      errcode = 'P0002',
      message = 'Daily report was not found in your company.';
  end if;

  if v_report_status <> 'draft' then
    raise exception using
      errcode = '42501',
      message = 'Units can be changed only while the report is a draft.';
  end if;

  if v_role = 'foreman' and v_report_creator is distinct from auth.uid() then
    raise exception using
      errcode = '42501',
      message = 'Foremen can change units only on their own reports.';
  end if;

  delete from public.daily_production_unit_locations location_line
  where location_line.daily_report_id = p_report_id
    and location_line.price_book_item_id = p_price_book_item_id
    and location_line.company_id = v_company_id
    and location_line.pole_location_key =
      lower(btrim(coalesce(p_pole_location, '')));

  select
    coalesce(sum(location_line.install_quantity), 0),
    coalesce(sum(location_line.retirement_quantity), 0)
  into v_total_install, v_total_retirement
  from public.daily_production_unit_locations location_line
  where location_line.daily_report_id = p_report_id
    and location_line.price_book_item_id = p_price_book_item_id
    and location_line.company_id = v_company_id;

  if v_total_install = 0 and v_total_retirement = 0 then
    perform public.delete_daily_report_unit(
      p_report_id,
      p_price_book_item_id
    );
  else
    perform public.save_daily_report_unit(
      p_report_id,
      p_price_book_item_id,
      v_total_install,
      v_total_retirement
    );
  end if;
end;
$$;

-- Source: 20260816_daily_unit_search_memory.sql
-- Superintendent capability: production_review
create or replace function public.get_daily_unit_usage_memory(
  p_report_id uuid
)
returns table (
  item_code text,
  use_count bigint,
  last_used timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_profile_active boolean;
  v_report_company_id uuid;
  v_report_creator uuid;
  v_contract_id uuid;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_profile_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_profile_active is not true or
     v_role not in ('foreman', 'gf', 'admin', 'owner', 'superintendent') then
    raise exception using
      errcode = '42501',
      message = 'An active Foreman, General Foreman or Admin profile is required.';
  end if;

  select report.company_id, report.created_by, job.contract_id
  into v_report_company_id, v_report_creator, v_contract_id
  from public.daily_reports report
  join public.jobs job
    on job.id = report.job_id
   and job.company_id = report.company_id
  where report.id = p_report_id;

  if v_report_company_id is null or v_report_company_id <> v_company_id then
    raise exception using
      errcode = 'P0002',
      message = 'Daily report was not found in your company.';
  end if;

  if v_role = 'foreman' and v_report_creator is distinct from auth.uid() then
    raise exception using
      errcode = '42501',
      message = 'Foremen can access search memory only for their own reports.';
  end if;

  if v_contract_id is null then
    return;
  end if;

  return query
  select
    min(aggregate_line.item_code),
    count(location_line.id),
    max(location_line.updated_at)
  from public.daily_production_unit_locations location_line
  join public.daily_production_units aggregate_line
    on aggregate_line.id = location_line.daily_production_unit_id
   and aggregate_line.company_id = location_line.company_id
   and aggregate_line.daily_report_id = location_line.daily_report_id
  join public.daily_reports historical_report
    on historical_report.id = location_line.daily_report_id
   and historical_report.company_id = location_line.company_id
  join public.jobs historical_job
    on historical_job.id = historical_report.job_id
   and historical_job.company_id = historical_report.company_id
  where location_line.company_id = v_company_id
    and location_line.created_by = auth.uid()
    and historical_job.contract_id = v_contract_id
  group by lower(btrim(aggregate_line.item_code));
end;
$$;

-- Source: 20260816_job_package_foundation.sql
-- Superintendent capability: job_packages
create or replace function public.get_job_packages(
  p_job_id uuid default null
)
returns table (
  id uuid,
  job_id uuid,
  contract_id uuid,
  package_name text,
  package_number text,
  received_date date,
  source_filename text,
  notes text,
  status text,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('job_packages') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have job packages permission.';
  end if;
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin', 'gf', 'owner', 'superintendent') then
    raise exception using
      errcode = '42501',
      message = 'Only an active Admin or General Foreman can view utility job packages.';
  end if;

  if p_job_id is not null and not exists (
    select 1
    from public.jobs job
    where job.id = p_job_id
      and job.company_id = v_company_id
  ) then
    raise exception using
      errcode = 'P0002',
      message = 'Job was not found in your company.';
  end if;

  return query
  select
    package.id,
    package.job_id,
    package.contract_id,
    package.package_name,
    package.package_number,
    package.received_date,
    package.source_filename,
    package.notes,
    package.status,
    package.created_at,
    package.updated_at
  from public.job_packages package
  where package.company_id = v_company_id
    and (p_job_id is null or package.job_id = p_job_id)
  order by package.created_at desc;
end;
$$;

-- Source: 20260816_job_package_foundation.sql
-- Superintendent capability: job_packages
create or replace function public.create_job_package(
  p_job_id uuid,
  p_package_name text,
  p_package_number text default null,
  p_received_date date default null,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_contract_id uuid;
  v_package_id uuid;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('job_packages') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have job packages permission.';
  end if;
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role not in ('admin','owner','superintendent') then
    raise exception using
      errcode = '42501',
      message = 'Only an active company Admin can add utility job packages.';
  end if;

  if length(trim(coalesce(p_package_name, ''))) = 0 then
    raise exception using
      errcode = '22023',
      message = 'Package name is required.';
  end if;

  select job.contract_id
  into v_contract_id
  from public.jobs job
  join public.contracts contract
    on contract.id = job.contract_id
   and contract.company_id = job.company_id
  where job.id = p_job_id
    and job.company_id = v_company_id
    and job.active is true;

  if v_contract_id is null then
    raise exception using
      errcode = 'P0002',
      message = 'An active job tied to your company contract is required.';
  end if;

  insert into public.job_packages (
    company_id,
    job_id,
    contract_id,
    package_name,
    package_number,
    received_date,
    notes,
    created_by
  ) values (
    v_company_id,
    p_job_id,
    v_contract_id,
    trim(p_package_name),
    nullif(trim(coalesce(p_package_number, '')), ''),
    p_received_date,
    nullif(trim(coalesce(p_notes, '')), ''),
    auth.uid()
  )
  returning id into v_package_id;

  return v_package_id;
exception
  when unique_violation then
    raise exception using
      errcode = '23505',
      message = 'That utility package reference already exists on this job.';
end;
$$;

-- Source: 20260816_job_package_spreadsheet_import.sql
-- Superintendent capability: job_packages
create or replace function public.validate_job_package_import(
  p_package_id uuid,
  p_rows jsonb
)
returns table (
  row_number integer,
  is_valid boolean,
  error_message text
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_contract_id uuid;
  v_row jsonb;
  v_row_number integer;
  v_work_point text;
  v_unit_code text;
  v_install numeric;
  v_retirement numeric;
  v_error text;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('job_packages') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have job packages permission.';
  end if;
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role not in ('admin','owner','superintendent') then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin can validate job packet imports.';
  end if;

  select package.contract_id
  into v_contract_id
  from public.job_packages package
  where package.id = p_package_id
    and package.company_id = v_company_id;

  if v_contract_id is null then
    raise exception using errcode = 'P0002',
      message = 'Utility job package was not found in your company.';
  end if;

  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception using errcode = '22023', message = 'Import rows are required.';
  end if;

  if jsonb_array_length(p_rows) > 2000 then
    raise exception using errcode = '22023',
      message = 'A maximum of 2,000 consolidated rows can be imported at once.';
  end if;

  for v_row in select value from jsonb_array_elements(p_rows)
  loop
    v_row_number := coalesce((v_row->>'row_number')::integer, 0);
    v_work_point := trim(coalesce(v_row->>'work_point_code', ''));
    v_unit_code := trim(coalesce(v_row->>'unit_code', ''));
    v_install := coalesce((v_row->>'install_quantity')::numeric, 0);
    v_retirement := coalesce((v_row->>'retirement_quantity')::numeric, 0);
    v_error := null;

    if length(v_work_point) = 0 then
      v_error := 'Missing work point';
    elsif length(v_unit_code) = 0 then
      v_error := 'Missing unit code';
    elsif v_install < 0 or v_retirement < 0 or v_install + v_retirement <= 0 then
      v_error := 'Authorized quantity must be greater than zero';
    elsif not exists (
      select 1
      from public.price_book_items item
      join public.price_books book
        on book.id = item.price_book_id
       and book.company_id = item.company_id
      where item.company_id = v_company_id
        and book.contract_id = v_contract_id
        and book.active is true
        and item.active is true
        and lower(trim(item.item_code)) = lower(v_unit_code)
    ) then
      v_error := 'Unit code was not found in an active Price Book for this contract';
    end if;

    row_number := v_row_number;
    is_valid := v_error is null;
    error_message := v_error;
    return next;
  end loop;
exception
  when invalid_text_representation then
    raise exception using errcode = '22023',
      message = 'One or more quantities are not valid numbers.';
end;
$$;

-- Source: 20260816_job_package_spreadsheet_import.sql
-- Superintendent capability: job_packages
create or replace function public.import_job_package_units(
  p_package_id uuid,
  p_rows jsonb,
  p_source_filename text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_contract_id uuid;
  v_job_id uuid;
  v_row jsonb;
  v_row_number integer;
  v_work_point text;
  v_description text;
  v_unit_code text;
  v_install numeric;
  v_retirement numeric;
  v_work_point_id uuid;
  v_price_book_item_id uuid;
  v_canonical_unit_code text;
  v_imported integer := 0;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('job_packages') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have job packages permission.';
  end if;
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role not in ('admin','owner','superintendent') then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin can import utility job packets.';
  end if;

  select package.contract_id, package.job_id
  into v_contract_id, v_job_id
  from public.job_packages package
  join public.jobs job
    on job.id = package.job_id
   and job.company_id = package.company_id
  where package.id = p_package_id
    and package.company_id = v_company_id;

  if v_contract_id is null then
    raise exception using errcode = 'P0002',
      message = 'Utility job package was not found in your company.';
  end if;

  if jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception using errcode = '22023', message = 'Import rows are required.';
  end if;

  if jsonb_array_length(p_rows) > 2000 then
    raise exception using errcode = '22023',
      message = 'A maximum of 2,000 consolidated rows can be imported at once.';
  end if;

  -- Validate every row before writing anything. Any exception rolls back the call.
  for v_row in select value from jsonb_array_elements(p_rows)
  loop
    v_row_number := coalesce((v_row->>'row_number')::integer, 0);
    v_work_point := trim(coalesce(v_row->>'work_point_code', ''));
    v_unit_code := trim(coalesce(v_row->>'unit_code', ''));
    v_install := coalesce((v_row->>'install_quantity')::numeric, 0);
    v_retirement := coalesce((v_row->>'retirement_quantity')::numeric, 0);

    if length(v_work_point) = 0 or length(v_unit_code) = 0 or
       v_install < 0 or v_retirement < 0 or v_install + v_retirement <= 0 then
      raise exception using errcode = '22023',
        message = 'Import row ' || v_row_number || ' is incomplete or has an invalid quantity.';
    end if;

    if not exists (
      select 1
      from public.price_book_items item
      join public.price_books book
        on book.id = item.price_book_id
       and book.company_id = item.company_id
      where item.company_id = v_company_id
        and book.contract_id = v_contract_id
        and book.active is true
        and item.active is true
        and lower(trim(item.item_code)) = lower(v_unit_code)
    ) then
      raise exception using errcode = 'P0002',
        message = 'Import row ' || v_row_number || ': unit ' || v_unit_code ||
          ' was not found in an active Price Book for this contract.';
    end if;
  end loop;

  for v_row in select value from jsonb_array_elements(p_rows)
  loop
    v_work_point := trim(v_row->>'work_point_code');
    v_description := nullif(trim(coalesce(v_row->>'work_point_description', '')), '');
    v_unit_code := trim(v_row->>'unit_code');
    v_install := coalesce((v_row->>'install_quantity')::numeric, 0);
    v_retirement := coalesce((v_row->>'retirement_quantity')::numeric, 0);

    select point.id
    into v_work_point_id
    from public.job_package_work_points point
    where point.company_id = v_company_id
      and point.job_package_id = p_package_id
      and public.normalize_work_point_key(point.work_point_code) =
          public.normalize_work_point_key(v_work_point)
    order by point.created_at
    limit 1;

    if v_work_point_id is null then
      insert into public.job_package_work_points (
        company_id, job_package_id, job_id, work_point_code, description, created_by
      ) values (
        v_company_id, p_package_id, v_job_id, v_work_point, v_description, auth.uid()
      )
      returning id into v_work_point_id;
    elsif v_description is not null then
      update public.job_package_work_points
      set description = coalesce(description, v_description), updated_at = now()
      where id = v_work_point_id and company_id = v_company_id;
    end if;

    select item.id, item.item_code
    into v_price_book_item_id, v_canonical_unit_code
    from public.price_book_items item
    join public.price_books book
      on book.id = item.price_book_id
     and book.company_id = item.company_id
    where item.company_id = v_company_id
      and book.contract_id = v_contract_id
      and book.active is true
      and item.active is true
      and lower(trim(item.item_code)) = lower(v_unit_code)
    order by book.effective_start desc nulls last, book.updated_at desc nulls last
    limit 1;

    insert into public.job_package_authorized_units (
      company_id, job_package_id, work_point_id, price_book_item_id, unit_code,
      authorized_install_quantity, authorized_retirement_quantity, created_by
    ) values (
      v_company_id, p_package_id, v_work_point_id, v_price_book_item_id,
      v_canonical_unit_code, v_install, v_retirement, auth.uid()
    )
    on conflict (work_point_id, price_book_item_id) do update set
      authorized_install_quantity = excluded.authorized_install_quantity,
      authorized_retirement_quantity = excluded.authorized_retirement_quantity,
      unit_code = excluded.unit_code,
      updated_at = now();

    v_imported := v_imported + 1;
  end loop;

  update public.job_packages
  set source_filename = nullif(trim(coalesce(p_source_filename, '')), ''),
      updated_at = now()
  where id = p_package_id and company_id = v_company_id;

  return jsonb_build_object('imported_rows', v_imported);
exception
  when invalid_text_representation then
    raise exception using errcode = '22023',
      message = 'One or more quantities are not valid numbers. Nothing was imported.';
end;
$$;

-- Source: 20260816_job_package_work_points.sql
-- Superintendent capability: job_packages
create or replace function public.create_job_package_work_point(
  p_package_id uuid,
  p_work_point_code text,
  p_description text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_job_id uuid;
  v_work_point_id uuid;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('job_packages') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have job packages permission.';
  end if;
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role not in ('admin','owner','superintendent') then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin can add package work points.';
  end if;

  if length(trim(coalesce(p_work_point_code, ''))) = 0 then
    raise exception using errcode = '22023',
      message = 'Pole or work-point number is required.';
  end if;

  select package.job_id
  into v_job_id
  from public.job_packages package
  join public.jobs job
    on job.id = package.job_id
   and job.company_id = package.company_id
  where package.id = p_package_id
    and package.company_id = v_company_id;

  if v_job_id is null then
    raise exception using errcode = 'P0002',
      message = 'Utility job package was not found in your company.';
  end if;

  insert into public.job_package_work_points (
    company_id, job_package_id, job_id, work_point_code, description, created_by
  ) values (
    v_company_id, p_package_id, v_job_id, trim(p_work_point_code),
    nullif(trim(coalesce(p_description, '')), ''), auth.uid()
  )
  returning id into v_work_point_id;

  return v_work_point_id;
exception
  when unique_violation then
    raise exception using errcode = '23505',
      message = 'That pole or work point already exists in this package.';
end;
$$;

-- Source: 20260816_job_package_work_points.sql
-- Superintendent capability: job_packages
create or replace function public.save_job_package_authorized_unit(
  p_work_point_id uuid,
  p_unit_code text,
  p_install_quantity numeric,
  p_retirement_quantity numeric
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_package_id uuid;
  v_contract_id uuid;
  v_price_book_item_id uuid;
  v_unit_code text;
  v_authorized_unit_id uuid;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('job_packages') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have job packages permission.';
  end if;
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role not in ('admin','owner','superintendent') then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin can add authorized units.';
  end if;

  if length(trim(coalesce(p_unit_code, ''))) = 0 or
     coalesce(p_install_quantity, 0) < 0 or
     coalesce(p_retirement_quantity, 0) < 0 or
     coalesce(p_install_quantity, 0) + coalesce(p_retirement_quantity, 0) <= 0 then
    raise exception using errcode = '22023',
      message = 'Unit code and an authorized quantity greater than zero are required.';
  end if;

  select point.job_package_id, package.contract_id
  into v_package_id, v_contract_id
  from public.job_package_work_points point
  join public.job_packages package
    on package.id = point.job_package_id
   and package.company_id = point.company_id
  where point.id = p_work_point_id
    and point.company_id = v_company_id;

  if v_package_id is null then
    raise exception using errcode = 'P0002',
      message = 'Package work point was not found in your company.';
  end if;

  select item.id, item.item_code
  into v_price_book_item_id, v_unit_code
  from public.price_book_items item
  join public.price_books book
    on book.id = item.price_book_id
   and book.company_id = item.company_id
  where item.company_id = v_company_id
    and book.contract_id = v_contract_id
    and book.active is true
    and item.active is true
    and lower(trim(item.item_code)) = lower(trim(p_unit_code))
  order by book.effective_start desc nulls last, book.updated_at desc nulls last
  limit 1;

  if v_price_book_item_id is null then
    raise exception using errcode = 'P0002',
      message = 'That unit code was not found in an active Price Book for this contract.';
  end if;

  insert into public.job_package_authorized_units (
    company_id, job_package_id, work_point_id, price_book_item_id, unit_code,
    authorized_install_quantity, authorized_retirement_quantity, created_by
  ) values (
    v_company_id, v_package_id, p_work_point_id, v_price_book_item_id, v_unit_code,
    coalesce(p_install_quantity, 0), coalesce(p_retirement_quantity, 0), auth.uid()
  )
  on conflict (work_point_id, price_book_item_id) do update set
    authorized_install_quantity = excluded.authorized_install_quantity,
    authorized_retirement_quantity = excluded.authorized_retirement_quantity,
    unit_code = excluded.unit_code,
    updated_at = now()
  returning id into v_authorized_unit_id;

  return v_authorized_unit_id;
end;
$$;

-- Source: 20260816_normalize_job_package_work_points.sql
-- Superintendent capability: job_packages
create or replace function public.get_job_package_work_points(
  p_package_id uuid
)
returns table (
  work_point_id uuid,
  work_point_code text,
  work_point_description text,
  authorized_unit_id uuid,
  unit_code text,
  unit_name text,
  unit_description text,
  authorized_install_quantity numeric,
  authorized_retirement_quantity numeric,
  reported_install_quantity numeric,
  reported_retirement_quantity numeric,
  approved_install_quantity numeric,
  approved_retirement_quantity numeric,
  authorized_value numeric,
  reported_value numeric,
  approved_value numeric
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_job_id uuid;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('job_packages') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have job packages permission.';
  end if;
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin', 'gf', 'owner', 'superintendent') then
    raise exception using errcode = '42501',
      message = 'Only an active Admin or General Foreman can view package progress.';
  end if;

  select package.job_id
  into v_job_id
  from public.job_packages package
  where package.id = p_package_id
    and package.company_id = v_company_id;

  if v_job_id is null then
    raise exception using errcode = 'P0002',
      message = 'Utility job package was not found in your company.';
  end if;

  return query
  select
    point.id,
    point.work_point_code,
    point.description,
    authorized.id,
    authorized.unit_code,
    item.item_name,
    item.description,
    coalesce(authorized.authorized_install_quantity, 0),
    coalesce(authorized.authorized_retirement_quantity, 0),
    coalesce(production.reported_install, 0),
    coalesce(production.reported_retirement, 0),
    coalesce(production.approved_install, 0),
    coalesce(production.approved_retirement, 0),
    coalesce(
      authorized.authorized_install_quantity * item.install_price +
      authorized.authorized_retirement_quantity * item.retirement_price,
      0
    ),
    coalesce(
      least(production.reported_install, authorized.authorized_install_quantity) * item.install_price +
      least(production.reported_retirement, authorized.authorized_retirement_quantity) * item.retirement_price,
      0
    ),
    coalesce(
      least(production.approved_install, authorized.authorized_install_quantity) * item.install_price +
      least(production.approved_retirement, authorized.authorized_retirement_quantity) * item.retirement_price,
      0
    )
  from public.job_package_work_points point
  left join public.job_package_authorized_units authorized
    on authorized.work_point_id = point.id
   and authorized.company_id = point.company_id
  left join public.price_book_items item
    on item.id = authorized.price_book_item_id
   and item.company_id = authorized.company_id
  left join lateral (
    select
      coalesce(sum(location.install_quantity), 0) as reported_install,
      coalesce(sum(location.retirement_quantity), 0) as reported_retirement,
      coalesce(sum(location.install_quantity) filter (
        where lower(coalesce(report.status, '')) = 'approved'
      ), 0) as approved_install,
      coalesce(sum(location.retirement_quantity) filter (
        where lower(coalesce(report.status, '')) = 'approved'
      ), 0) as approved_retirement
    from public.daily_production_unit_locations location
    join public.daily_reports report
      on report.id = location.daily_report_id
     and report.company_id = location.company_id
    join public.price_book_items historical_item
      on historical_item.id = location.price_book_item_id
     and historical_item.company_id = location.company_id
    where location.company_id = v_company_id
      and report.job_id = v_job_id
      and public.normalize_work_point_key(location.pole_location) =
          public.normalize_work_point_key(point.work_point_code)
      and lower(trim(historical_item.item_code)) = lower(trim(authorized.unit_code))
  ) production on authorized.id is not null
  where point.job_package_id = p_package_id
    and point.company_id = v_company_id
  order by point.work_point_key, authorized.unit_code;
end;
$$;

-- Source: 20260816_normalize_job_package_work_points.sql
-- Superintendent capability: job_packages
create or replace function public.delete_job_package_authorized_unit(
  p_authorized_unit_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('job_packages') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have job packages permission.';
  end if;
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role not in ('admin','owner','superintendent') then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin can delete authorized units.';
  end if;

  delete from public.job_package_authorized_units authorized
  where authorized.id = p_authorized_unit_id
    and authorized.company_id = v_company_id;

  if not found then
    raise exception using errcode = 'P0002',
      message = 'Authorized unit was not found in your company.';
  end if;
end;
$$;

-- Source: 20260816_normalize_job_package_work_points.sql
-- Superintendent capability: job_packages
create or replace function public.delete_job_package_work_point(
  p_work_point_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('job_packages') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have job packages permission.';
  end if;
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role not in ('admin','owner','superintendent') then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin can delete package work points.';
  end if;

  if exists (
    select 1
    from public.job_package_authorized_units authorized
    where authorized.work_point_id = p_work_point_id
      and authorized.company_id = v_company_id
  ) then
    raise exception using errcode = '23503',
      message = 'Delete the authorized units from this work point first.';
  end if;

  delete from public.job_package_work_points point
  where point.id = p_work_point_id
    and point.company_id = v_company_id;

  if not found then
    raise exception using errcode = 'P0002',
      message = 'Package work point was not found in your company.';
  end if;
end;
$$;

-- Source: 20260816_normalize_job_package_work_points.sql
-- Superintendent capability: job_packages
create or replace function public.delete_job_package(
  p_package_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('job_packages') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have job packages permission.';
  end if;
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role not in ('admin','owner','superintendent') then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin can delete utility job packages.';
  end if;

  delete from public.job_packages package
  where package.id = p_package_id
    and package.company_id = v_company_id;

  if not found then
    raise exception using errcode = 'P0002',
      message = 'Utility job package was not found in your company.';
  end if;
end;
$$;

-- Source: 20260816_secure_job_package_status.sql
-- Superintendent capability: job_packages
create or replace function public.set_job_package_status(
  p_package_id uuid,
  p_status text
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_next_status text;
  v_job_active boolean;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('job_packages') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have job packages permission.';
  end if;
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role not in ('admin','owner','superintendent') then
    raise exception using
      errcode = '42501',
      message = 'Only an active company Admin can change a utility package status.';
  end if;

  v_next_status := lower(trim(coalesce(p_status, '')));
  if v_next_status not in ('active', 'closed') then
    raise exception using
      errcode = '22023',
      message = 'A utility package can only be activated or closed.';
  end if;

  select job.active
  into v_job_active
  from public.job_packages package
  join public.jobs job
    on job.id = package.job_id
   and job.company_id = package.company_id
  where package.id = p_package_id
    and package.company_id = v_company_id;

  if v_job_active is null then
    raise exception using
      errcode = 'P0002',
      message = 'Utility job package was not found in your company.';
  end if;

  if v_next_status = 'active' and v_job_active is not true then
    raise exception using
      errcode = '22023',
      message = 'Reopen the job before activating this utility package.';
  end if;

  if v_next_status = 'active' and not exists (
    select 1
    from public.job_package_authorized_units unit
    where unit.company_id = v_company_id
      and unit.job_package_id = p_package_id
  ) then
    raise exception using
      errcode = '22023',
      message = 'Add at least one authorized unit before activating this utility package.';
  end if;

  update public.job_packages package
  set status = v_next_status,
      updated_at = now()
  where package.id = p_package_id
    and package.company_id = v_company_id;

  return v_next_status;
end;
$$;

-- Source: 20260817_company_settings_branding.sql
-- Superintendent capability: company_settings
create or replace function public.update_company_settings(
  p_name text,
  p_contact_email text default null,
  p_contact_phone text default null,
  p_logo_url text default null,
  p_primary_color text default '#0b2d4d',
  p_timezone text default 'America/Chicago'
)
returns table(
  id uuid,
  name text,
  contact_email text,
  contact_phone text,
  logo_url text,
  primary_color text,
  timezone text,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_role text;
  v_name text := trim(coalesce(p_name, ''));
  v_email text := nullif(trim(coalesce(p_contact_email, '')), '');
  v_phone text := nullif(trim(coalesce(p_contact_phone, '')), '');
  v_logo text := nullif(trim(coalesce(p_logo_url, '')), '');
  v_color text := lower(trim(coalesce(p_primary_color, '')));
  v_timezone text := trim(coalesce(p_timezone, ''));
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('company_settings') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have company settings permission.';
  end if;
  if auth.uid() is null then
    raise exception 'Authentication required.';
  end if;

  select profile.company_id, lower(coalesce(profile.role, ''))
    into v_company_id, v_role
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_role not in ('admin','owner','superintendent') then
    raise exception 'Only a company Admin can update company settings.';
  end if;

  if length(v_name) < 2 or length(v_name) > 120 then
    raise exception 'Company name must be between 2 and 120 characters.';
  end if;

  if v_email is not null and
     (length(v_email) > 254 or position('@' in v_email) < 2) then
    raise exception 'Enter a valid company email address.';
  end if;

  if v_phone is not null and length(v_phone) > 40 then
    raise exception 'Company phone must be 40 characters or fewer.';
  end if;

  if v_logo is not null and
     (length(v_logo) > 1000 or v_logo !~* '^https://') then
    raise exception 'Logo URL must be a secure https:// address.';
  end if;

  if v_color !~ '^#[0-9a-f]{6}$' then
    raise exception 'Brand color must use the format #0b2d4d.';
  end if;

  if v_timezone not in (
    'America/Chicago',
    'America/New_York',
    'America/Denver',
    'America/Los_Angeles',
    'America/Anchorage',
    'Pacific/Honolulu'
  ) then
    raise exception 'Unsupported company time zone.';
  end if;

  return query
  update public.companies company
  set
    name = v_name,
    contact_email = v_email,
    contact_phone = v_phone,
    logo_url = v_logo,
    primary_color = v_color,
    timezone = v_timezone,
    updated_at = now()
  where company.id = v_company_id
  returning
    company.id,
    company.name,
    company.contact_email,
    company.contact_phone,
    company.logo_url,
    company.primary_color,
    company.timezone,
    company.updated_at;
end;
$$;

-- Source: 20260817_daily_report_attachments.sql
-- Superintendent capability: production_review
create or replace function public.delete_daily_report_attachment(
  p_attachment_id uuid
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile public.profiles%rowtype;
  v_attachment public.daily_report_attachments%rowtype;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  select * into v_profile
  from public.profiles
  where id = auth.uid();

  select * into v_attachment
  from public.daily_report_attachments attachment
  where attachment.id = p_attachment_id
    and attachment.company_id = v_profile.company_id;

  if v_attachment.id is null then
    raise exception 'Attachment not found for your company.';
  end if;

  if v_attachment.uploaded_by <> auth.uid()
     and lower(coalesce(v_profile.role, '')) not in ('admin','gf', 'owner', 'superintendent') then
    raise exception 'Only the uploader, a General Foreman or an Admin may delete this attachment.';
  end if;

  delete from public.daily_report_attachments
  where id = v_attachment.id;

  return v_attachment.storage_path;
end;
$$;

-- Source: 20260817_daily_report_context.sql
-- Superintendent capability: production_review
create or replace function public.set_daily_report_context(
  p_report_id uuid,
  p_weather_conditions text,
  p_delay_hours numeric,
  p_delay_reason text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_delay_hours numeric := coalesce(p_delay_hours, 0);
  v_delay_reason text := nullif(btrim(coalesce(p_delay_reason, '')), '');
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('production_review') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have production review permission.';
  end if;
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true then
    raise exception using errcode = '42501',
      message = 'An active company membership is required.';
  end if;

  if v_delay_hours < 0 then
    raise exception using errcode = '22023',
      message = 'Delay hours cannot be negative.';
  end if;

  if v_delay_hours > 0 and v_delay_reason is null then
    raise exception using errcode = '22023',
      message = 'A delay reason is required when delay hours are entered.';
  end if;

  update public.daily_reports report
  set weather_conditions = nullif(btrim(coalesce(p_weather_conditions, '')), ''),
      delay_hours = v_delay_hours,
      delay_reason = case when v_delay_hours > 0 then v_delay_reason else null end
  where report.id = p_report_id
    and report.company_id = v_company_id
    and lower(coalesce(report.status, 'draft')) = 'draft'
    and (
      report.created_by = auth.uid()
      or v_role in ('admin', 'gf', 'owner', 'superintendent')
    );

  if not found then
    raise exception using errcode = '42501',
      message = 'Only the report creator, an Admin or a General Foreman can update a draft report in their company.';
  end if;
end;
$$;

-- Source: 20260817_standalone_morning_jsa.sql
-- Superintendent capability: safety_records
create or replace function public.create_standalone_jsa(
  p_job_id uuid,
  p_work_date date,
  p_crew_name text,
  p_job_briefing text,
  p_hazards text,
  p_controls text,
  p_ppe text,
  p_emergency_plan text,
  p_crew_members text,
  p_weather_conditions text default null,
  p_special_equipment text default null,
  p_foreman_acknowledged boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_jsa_id uuid;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('safety_records') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have safety records permission.';
  end if;
  select p.company_id, lower(coalesce(p.role, ''))
    into v_company_id, v_role
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_role not in ('foreman', 'gf', 'admin', 'owner', 'superintendent') then
    raise exception using errcode = '42501',
      message = 'You are not allowed to complete a JSA.';
  end if;

  if not exists (
    select 1
    from public.jobs j
    where j.id = p_job_id
      and j.company_id = v_company_id
      and lower(coalesce(j.status, 'active')) = 'active'
  ) then
    raise exception using errcode = 'P0002',
      message = 'An active job was not found for your company.';
  end if;

  if p_work_date is null
    or length(trim(coalesce(p_crew_name, ''))) = 0
    or length(trim(coalesce(p_job_briefing, ''))) = 0
    or length(trim(coalesce(p_hazards, ''))) = 0
    or length(trim(coalesce(p_controls, ''))) = 0
    or length(trim(coalesce(p_ppe, ''))) = 0
    or length(trim(coalesce(p_emergency_plan, ''))) = 0
    or length(trim(coalesce(p_crew_members, ''))) = 0 then
    raise exception using errcode = '22023',
      message = 'All required JSA fields must be completed.';
  end if;

  if not coalesce(p_foreman_acknowledged, false) then
    raise exception using errcode = '22023',
      message = 'The Foreman must acknowledge the crew safety briefing.';
  end if;

  insert into public.daily_report_jsas (
    company_id,
    daily_report_id,
    job_id,
    created_by,
    work_date,
    crew_name,
    job_briefing,
    hazards,
    controls,
    ppe,
    emergency_plan,
    weather_conditions,
    special_equipment,
    crew_members,
    foreman_acknowledged,
    acknowledged_at,
    updated_at
  ) values (
    v_company_id,
    null,
    p_job_id,
    auth.uid(),
    p_work_date,
    trim(p_crew_name),
    trim(p_job_briefing),
    trim(p_hazards),
    trim(p_controls),
    trim(p_ppe),
    trim(p_emergency_plan),
    nullif(trim(coalesce(p_weather_conditions, '')), ''),
    nullif(trim(coalesce(p_special_equipment, '')), ''),
    trim(p_crew_members),
    true,
    now(),
    now()
  )
  returning id into v_jsa_id;

  return v_jsa_id;
end;
$$;

-- Source: 20260817_job_leader_assignments.sql
-- Superintendent capability: jobs
create or replace function public.get_assignable_job_leaders()
returns table (
  member_id uuid,
  full_name text,
  member_role text
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
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('jobs') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have jobs permission.';
  end if;
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin', 'gf', 'owner', 'superintendent') then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin or General Foreman can manage job leaders.';
  end if;

  return query
  select
    profile.id,
    coalesce(nullif(trim(profile.full_name), ''), 'Unnamed Team Member')::text,
    lower(coalesce(profile.role, 'foreman'))::text
  from public.profiles profile
  where profile.company_id = v_company_id
    and profile.active is true
    and lower(coalesce(profile.role, 'foreman')) in ('foreman', 'gf')
  order by
    case when lower(coalesce(profile.role, 'foreman')) = 'gf' then 0 else 1 end,
    lower(coalesce(profile.full_name, ''));
end;
$$;

-- Source: 20260817_job_leader_assignments.sql
-- Superintendent capability: jobs
create or replace function public.get_job_leader_assignments()
returns table (
  job_id uuid,
  member_id uuid,
  full_name text,
  member_role text
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
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('jobs') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have jobs permission.';
  end if;
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin', 'gf', 'owner', 'superintendent') then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin or General Foreman can view job leader assignments.';
  end if;

  return query
  select
    assignment.job_id,
    assignment.member_id,
    coalesce(nullif(trim(profile.full_name), ''), 'Unnamed Team Member')::text,
    lower(coalesce(profile.role, 'foreman'))::text
  from public.job_leader_assignments assignment
  join public.jobs job
    on job.id = assignment.job_id
   and job.company_id = assignment.company_id
  join public.profiles profile
    on profile.id = assignment.member_id
   and profile.company_id = assignment.company_id
  where assignment.company_id = v_company_id
  order by lower(coalesce(profile.full_name, ''));
end;
$$;

-- Source: 20260817_job_leader_assignments.sql
-- Superintendent capability: jobs
create or replace function public.set_job_leader_assignment(
  p_job_id uuid,
  p_member_id uuid,
  p_assigned boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_member_role text;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('jobs') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have jobs permission.';
  end if;
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin', 'gf', 'owner', 'superintendent') then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin or General Foreman can change job leaders.';
  end if;

  if not exists (
    select 1
    from public.jobs job
    where job.id = p_job_id
      and job.company_id = v_company_id
  ) then
    raise exception using errcode = 'P0002',
      message = 'Job was not found in your company.';
  end if;

  select lower(coalesce(profile.role, 'foreman'))
  into v_member_role
  from public.profiles profile
  where profile.id = p_member_id
    and profile.company_id = v_company_id
    and profile.active is true;

  if v_member_role is null or v_member_role not in ('foreman', 'gf') then
    raise exception using errcode = '22023',
      message = 'Select an active Foreman or General Foreman from your company.';
  end if;

  if coalesce(p_assigned, false) then
    insert into public.job_leader_assignments (
      company_id,
      job_id,
      member_id,
      assigned_by
    ) values (
      v_company_id,
      p_job_id,
      p_member_id,
      auth.uid()
    )
    on conflict (job_id, member_id) do nothing;
  else
    delete from public.job_leader_assignments assignment
    where assignment.company_id = v_company_id
      and assignment.job_id = p_job_id
      and assignment.member_id = p_member_id;
  end if;
end;
$$;

-- Source: 20260817_job_progress_dashboard.sql
-- Superintendent capability: reporting
create or replace function public.get_job_progress_dashboard()
returns table (
  job_id uuid,
  package_count bigint,
  work_point_count bigint,
  authorized_value numeric,
  reported_value numeric,
  approved_value numeric,
  remaining_value numeric,
  reported_percent numeric,
  approved_percent numeric,
  report_count bigint,
  redline_count bigint,
  pending_packet_count bigint
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
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('reporting') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have reporting permission.';
  end if;
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin', 'gf', 'owner', 'superintendent') then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin or General Foreman can view job progress.';
  end if;

  return query
  with package_totals as (
    select
      package.job_id,
      count(distinct package.id)::bigint as package_count,
      count(distinct progress.work_point_id)::bigint as work_point_count,
      coalesce(sum(progress.authorized_value), 0)::numeric as authorized_value,
      coalesce(sum(progress.reported_value), 0)::numeric as reported_value,
      coalesce(sum(progress.approved_value), 0)::numeric as approved_value
    from public.job_packages package
    left join lateral public.get_job_package_work_points(package.id) progress
      on true
    where package.company_id = v_company_id
    group by package.job_id
  ),
  report_totals as (
    select
      report.job_id,
      count(distinct report.id)::bigint as report_count
    from public.daily_reports report
    where report.company_id = v_company_id
      and report.archived is not true
    group by report.job_id
  ),
  exception_totals as (
    select
      report.job_id,
      count(*) filter (
        where location.authorization_status = 'redline'
      )::bigint as redline_count,
      count(*) filter (
        where location.authorization_status = 'pending_packet'
      )::bigint as pending_packet_count
    from public.daily_reports report
    cross join lateral public.get_daily_report_unit_locations(report.id) location
    where report.company_id = v_company_id
      and report.archived is not true
      and lower(coalesce(report.status, 'draft')) <> 'rejected'
    group by report.job_id
  )
  select
    job.id,
    coalesce(package.package_count, 0),
    coalesce(package.work_point_count, 0),
    coalesce(package.authorized_value, 0),
    coalesce(package.reported_value, 0),
    coalesce(package.approved_value, 0),
    greatest(coalesce(package.authorized_value, 0) - coalesce(package.reported_value, 0), 0),
    case when coalesce(package.authorized_value, 0) > 0 then
      round(least(package.reported_value / package.authorized_value * 100, 100), 1)
    else 0 end,
    case when coalesce(package.authorized_value, 0) > 0 then
      round(least(package.approved_value / package.authorized_value * 100, 100), 1)
    else 0 end,
    coalesce(report.report_count, 0),
    coalesce(exception.redline_count, 0),
    coalesce(exception.pending_packet_count, 0)
  from public.jobs job
  left join package_totals package on package.job_id = job.id
  left join report_totals report on report.job_id = job.id
  left join exception_totals exception on exception.job_id = job.id
  where job.company_id = v_company_id
  order by job.active desc, job.created_at desc;
end;
$$;

-- Source: 20260817_jsa_storm_mode.sql
-- Superintendent capability: storm_mode
create or replace function public.set_company_storm_mode(
  p_enabled boolean,
  p_event_name text default null
)
returns table (
  storm_mode_enabled boolean,
  storm_event_name text,
  storm_started_at timestamptz,
  storm_ended_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('storm_mode') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have storm mode permission.';
  end if;
  select p.company_id, lower(coalesce(p.role, ''))
    into v_company_id, v_role
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_role not in ('admin','owner','superintendent') then
    raise exception using errcode = '42501',
      message = 'Only a company Admin can change Storm Mode.';
  end if;

  if coalesce(p_enabled, false) and length(trim(coalesce(p_event_name, ''))) = 0 then
    raise exception using errcode = '22023',
      message = 'A storm or event name is required when Storm Mode is enabled.';
  end if;

  update public.companies c
  set storm_mode_enabled = coalesce(p_enabled, false),
      storm_event_name = case when coalesce(p_enabled, false)
        then trim(p_event_name) else null end,
      storm_started_at = case
        when coalesce(p_enabled, false) and not c.storm_mode_enabled then now()
        when coalesce(p_enabled, false) then c.storm_started_at
        else c.storm_started_at end,
      storm_ended_at = case
        when not coalesce(p_enabled, false) and c.storm_mode_enabled then now()
        when coalesce(p_enabled, false) then null
        else c.storm_ended_at end
  where c.id = v_company_id;

  return query
  select c.storm_mode_enabled, c.storm_event_name,
         c.storm_started_at, c.storm_ended_at
  from public.companies c
  where c.id = v_company_id;
end;
$$;

-- Source: 20260817_storm_crew_assignments.sql
-- Superintendent capability: storm_mode
create or replace function public.set_daily_report_storm_context(
  p_report_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_report_created_by uuid;
  v_enabled boolean;
  v_event_name text;
  v_assigned boolean;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('storm_mode') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have storm mode permission.';
  end if;
  select p.company_id, lower(coalesce(p.role, ''))
    into v_company_id, v_role
  from public.profiles p
  where p.id = auth.uid()
    and coalesce(p.active, true);

  if v_company_id is null or v_role not in ('foreman','gf','admin', 'owner', 'superintendent') then
    raise exception using errcode = '42501',
      message = 'You are not allowed to update this daily report.';
  end if;

  select dr.created_by
    into v_report_created_by
  from public.daily_reports dr
  where dr.id = p_report_id
    and dr.company_id = v_company_id;

  if v_report_created_by is null then
    raise exception using errcode = 'P0002',
      message = 'Daily report was not found for your company.';
  end if;

  if v_role = 'foreman' and v_report_created_by <> auth.uid() then
    raise exception using errcode = '42501',
      message = 'Foremen may only update their own daily reports.';
  end if;

  select c.storm_mode_enabled, c.storm_event_name,
         exists (
           select 1
           from public.storm_mode_assignments a
           where a.company_id = v_company_id
             and a.user_id = v_report_created_by
         )
    into v_enabled, v_event_name, v_assigned
  from public.companies c
  where c.id = v_company_id;

  update public.daily_reports
  set storm_mode = coalesce(v_enabled, false) and coalesce(v_assigned, false),
      storm_event_name = case
        when coalesce(v_enabled, false) and coalesce(v_assigned, false)
          then v_event_name
        else null
      end
  where id = p_report_id
    and company_id = v_company_id;
end;
$$;

-- Source: 20260817_jsa_storm_mode.sql
-- Superintendent capability: safety_records
create or replace function public.save_daily_report_jsa(
  p_report_id uuid,
  p_job_briefing text,
  p_hazards text,
  p_controls text,
  p_ppe text,
  p_emergency_plan text,
  p_crew_members text,
  p_special_equipment text default null,
  p_foreman_acknowledged boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_job_id uuid;
  v_created_by uuid;
  v_work_date date;
  v_crew_name text;
  v_weather text;
  v_jsa_id uuid;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('safety_records') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have safety records permission.';
  end if;
  select p.company_id, lower(coalesce(p.role, ''))
    into v_company_id, v_role
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_role not in ('foreman','gf','admin', 'owner', 'superintendent') then
    raise exception using errcode = '42501',
      message = 'You are not allowed to save a JSA.';
  end if;

  select dr.job_id, dr.created_by, dr.work_date, dr.crew_name, dr.weather_conditions
    into v_job_id, v_created_by, v_work_date, v_crew_name, v_weather
  from public.daily_reports dr
  where dr.id = p_report_id
    and dr.company_id = v_company_id
    and lower(coalesce(dr.status, 'draft')) = 'draft';

  if v_job_id is null then
    raise exception using errcode = 'P0002',
      message = 'An editable daily report was not found for your company.';
  end if;

  if v_role = 'foreman' and v_created_by <> auth.uid() then
    raise exception using errcode = '42501',
      message = 'Foremen may only save a JSA for their own daily reports.';
  end if;

  if length(trim(coalesce(p_job_briefing, ''))) = 0
    or length(trim(coalesce(p_hazards, ''))) = 0
    or length(trim(coalesce(p_controls, ''))) = 0
    or length(trim(coalesce(p_ppe, ''))) = 0
    or length(trim(coalesce(p_emergency_plan, ''))) = 0
    or length(trim(coalesce(p_crew_members, ''))) = 0 then
    raise exception using errcode = '22023',
      message = 'All required JSA fields must be completed.';
  end if;

  if not coalesce(p_foreman_acknowledged, false) then
    raise exception using errcode = '22023',
      message = 'The Foreman must acknowledge the crew safety briefing.';
  end if;

  insert into public.daily_report_jsas (
    company_id, daily_report_id, job_id, created_by, work_date, crew_name,
    job_briefing, hazards, controls, ppe, emergency_plan, weather_conditions,
    special_equipment, crew_members, foreman_acknowledged, acknowledged_at,
    updated_at
  ) values (
    v_company_id, p_report_id, v_job_id, auth.uid(), v_work_date, v_crew_name,
    trim(p_job_briefing), trim(p_hazards), trim(p_controls), trim(p_ppe),
    trim(p_emergency_plan), v_weather, nullif(trim(coalesce(p_special_equipment,'')), ''),
    trim(p_crew_members), true, now(), now()
  )
  on conflict (daily_report_id) do update set
    job_id = excluded.job_id,
    work_date = excluded.work_date,
    crew_name = excluded.crew_name,
    job_briefing = excluded.job_briefing,
    hazards = excluded.hazards,
    controls = excluded.controls,
    ppe = excluded.ppe,
    emergency_plan = excluded.emergency_plan,
    weather_conditions = excluded.weather_conditions,
    special_equipment = excluded.special_equipment,
    crew_members = excluded.crew_members,
    foreman_acknowledged = excluded.foreman_acknowledged,
    acknowledged_at = now(),
    updated_at = now()
  returning id into v_jsa_id;

  return v_jsa_id;
end;
$$;

-- Source: 20260817_standalone_morning_jsa.sql
-- Superintendent capability: safety_records
create or replace function public.get_company_jsas()
returns table (
  id uuid,
  daily_report_id uuid,
  job_id uuid,
  job_number text,
  job_name text,
  work_date date,
  crew_name text,
  weather_conditions text,
  job_briefing text,
  hazards text,
  controls text,
  ppe text,
  emergency_plan text,
  crew_members text,
  special_equipment text,
  foreman_name text,
  acknowledged_at timestamptz,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = ''
stable
as $$
declare
  v_company_id uuid;
  v_role text;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('safety_records') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have safety records permission.';
  end if;
  select p.company_id, lower(coalesce(p.role, ''))
    into v_company_id, v_role
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_role not in ('foreman', 'gf', 'admin', 'owner', 'superintendent') then
    raise exception using errcode = '42501',
      message = 'You are not allowed to view JSAs.';
  end if;

  return query
  select
    safety.id,
    safety.daily_report_id,
    safety.job_id,
    job.job_number,
    job.job_name,
    safety.work_date,
    safety.crew_name,
    safety.weather_conditions,
    safety.job_briefing,
    safety.hazards,
    safety.controls,
    safety.ppe,
    safety.emergency_plan,
    safety.crew_members,
    safety.special_equipment,
    coalesce(nullif(trim(profile.full_name), ''), 'Foreman') as foreman_name,
    safety.acknowledged_at,
    safety.created_at
  from public.daily_report_jsas safety
  join public.jobs job
    on job.id = safety.job_id
   and job.company_id = safety.company_id
  left join public.profiles profile
    on profile.id = safety.created_by
   and profile.company_id = safety.company_id
  where safety.company_id = v_company_id
    and (
      v_role in ('gf', 'admin', 'owner', 'superintendent')
      or safety.created_by = auth.uid()
    )
  order by safety.work_date desc, safety.created_at desc;
end;
$$;

-- Source: 20260817_storm_crew_assignments.sql
-- Superintendent capability: storm_mode
create or replace function public.get_storm_mode_assignments()
returns table (
  user_id uuid,
  full_name text,
  role text,
  active boolean,
  assigned boolean
)
language plpgsql
security definer
set search_path = ''
stable
as $$
declare
  v_company_id uuid;
  v_role text;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('storm_mode') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have storm mode permission.';
  end if;
  select p.company_id, lower(coalesce(p.role, ''))
    into v_company_id, v_role
  from public.profiles p
  where p.id = auth.uid()
    and coalesce(p.active, true);

  if v_company_id is null or v_role not in ('admin','owner','superintendent') then
    raise exception using errcode = '42501',
      message = 'Only a company Admin can view Storm Mode crew assignments.';
  end if;

  return query
  select p.id,
         coalesce(nullif(trim(p.full_name), ''), 'Unnamed Team Member'),
         lower(coalesce(p.role, 'foreman')),
         coalesce(p.active, true),
         (a.user_id is not null)
  from public.profiles p
  left join public.storm_mode_assignments a
    on a.company_id = p.company_id
   and a.user_id = p.id
  where p.company_id = v_company_id
    and lower(coalesce(p.role, 'foreman')) in ('foreman', 'gf', 'admin', 'owner', 'superintendent')
  order by
    case lower(coalesce(p.role, 'foreman'))
      when 'gf' then 1
      when 'foreman' then 2
      else 3
    end,
    lower(coalesce(p.full_name, ''));
end;
$$;

-- Source: 20260817_storm_crew_assignments.sql
-- Superintendent capability: storm_mode
create or replace function public.set_storm_mode_assignments(
  p_user_ids uuid[]
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_requested_count integer;
  v_valid_count integer;
begin
  if exists (
    select 1 from public.profiles p
    where p.id = auth.uid()
      and lower(coalesce(p.role,'')) = 'superintendent'
  ) and not public.linecrew_has_capability('storm_mode') then
    raise exception using
      errcode = '42501',
      message = 'This Superintendent does not have storm mode permission.';
  end if;
  select p.company_id, lower(coalesce(p.role, ''))
    into v_company_id, v_role
  from public.profiles p
  where p.id = auth.uid()
    and coalesce(p.active, true);

  if v_company_id is null or v_role not in ('admin','owner','superintendent') then
    raise exception using errcode = '42501',
      message = 'Only a company Admin can change Storm Mode crew assignments.';
  end if;

  select count(distinct requested_id)
    into v_requested_count
  from unnest(coalesce(p_user_ids, array[]::uuid[])) requested_id;

  select count(*)
    into v_valid_count
  from public.profiles p
  where p.company_id = v_company_id
    and p.id = any(coalesce(p_user_ids, array[]::uuid[]))
    and coalesce(p.active, true)
    and lower(coalesce(p.role, 'foreman')) in ('foreman', 'gf', 'admin', 'owner', 'superintendent');

  if v_requested_count <> v_valid_count then
    raise exception using errcode = '22023',
      message = 'One or more selected Storm Mode crew leaders are invalid for this company.';
  end if;

  delete from public.storm_mode_assignments
  where company_id = v_company_id;

  insert into public.storm_mode_assignments(company_id, user_id, assigned_by)
  select v_company_id, p.id, auth.uid()
  from public.profiles p
  where p.company_id = v_company_id
    and p.id = any(coalesce(p_user_ids, array[]::uuid[]))
    and coalesce(p.active, true)
    and lower(coalesce(p.role, 'foreman')) in ('foreman', 'gf', 'admin', 'owner', 'superintendent')
  on conflict (company_id, user_id) do nothing;

  return v_valid_count;
end;
$$;

commit;
