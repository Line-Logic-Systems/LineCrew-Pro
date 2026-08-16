begin;

alter table public.daily_reports
  add column if not exists created_by uuid null
    references auth.users(id) on delete set null;

alter table public.daily_reports
  alter column created_by set default auth.uid();

alter table public.daily_reports
  add column if not exists price_book_id uuid null
    references public.price_books(id) on delete restrict;

alter table public.daily_reports
  add column if not exists field_value_percent_snapshot numeric(5,2) null;

alter table public.daily_reports
  add column if not exists has_field_adjustment boolean null;

create table if not exists public.daily_production_units (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null
    references public.companies(id) on delete cascade,
  daily_report_id uuid not null
    references public.daily_reports(id) on delete cascade,
  job_id uuid not null
    references public.jobs(id) on delete restrict,
  contract_id uuid not null
    references public.contracts(id) on delete restrict,
  price_book_id uuid not null
    references public.price_books(id) on delete restrict,
  price_book_item_id uuid not null
    references public.price_book_items(id) on delete restrict,
  item_code text not null,
  item_name text null,
  description text null,
  unit_of_measure text null,
  category text null,
  install_quantity numeric(12,2) not null default 0,
  retirement_quantity numeric(12,2) not null default 0,
  actual_install_price numeric(14,2) not null,
  actual_retirement_price numeric(14,2) not null,
  adjusted_install_price numeric(14,2) not null,
  adjusted_retirement_price numeric(14,2) not null,
  field_value_percent_snapshot numeric(5,2) not null,
  has_adjustment boolean not null default false,
  created_by uuid null references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint daily_production_units_nonnegative_quantities
    check (install_quantity >= 0 and retirement_quantity >= 0),
  constraint daily_production_units_has_quantity
    check (install_quantity > 0 or retirement_quantity > 0),
  constraint daily_production_units_report_item_unique
    unique (daily_report_id, price_book_item_id)
);

create index if not exists daily_production_units_company_report_idx
  on public.daily_production_units(company_id, daily_report_id);

alter table public.daily_production_units enable row level security;

revoke all on public.daily_production_units from public;
revoke all on public.daily_production_units from anon;
revoke all on public.daily_production_units from authenticated;

create or replace function public.protect_daily_report_unit_history()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1
    from public.daily_production_units line
    where line.daily_report_id = old.id
  ) and (
    new.job_id is distinct from old.job_id or
    new.work_date is distinct from old.work_date
  ) then
    raise exception using
      errcode = '23514',
      message = 'Remove saved unit production before changing the job or work date.';
  end if;

  if lower(coalesce(old.status, 'draft')) = 'draft' and
     lower(coalesce(new.status, 'draft')) = 'submitted' and
     not exists (
       select 1
       from public.daily_production_units line
       where line.daily_report_id = old.id
     ) then
    raise exception using
      errcode = '23514',
      message = 'Add at least one unit before submitting this daily report.';
  end if;

  return new;
end;
$$;

drop trigger if exists protect_daily_report_unit_history_trigger
on public.daily_reports;

create trigger protect_daily_report_unit_history_trigger
before update on public.daily_reports
for each row execute function public.protect_daily_report_unit_history();

revoke all on function public.protect_daily_report_unit_history() from public;
revoke all on function public.protect_daily_report_unit_history() from anon;
revoke all on function public.protect_daily_report_unit_history()
from authenticated;

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
  select p.company_id, lower(coalesce(p.role, '')), p.active
  into v_company_id, v_role, v_profile_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_profile_active is not true or
     v_role not in ('foreman', 'gf', 'admin') then
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

  v_can_see_actual := v_role in ('admin', 'gf');

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

revoke all on function public.get_daily_report_unit_catalog(uuid) from public;
revoke all on function public.get_daily_report_unit_catalog(uuid) from anon;
grant execute on function public.get_daily_report_unit_catalog(uuid)
to authenticated;

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
     v_role not in ('foreman', 'gf', 'admin') then
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

revoke all on function public.save_daily_report_unit(uuid, uuid, numeric, numeric)
from public;
revoke all on function public.save_daily_report_unit(uuid, uuid, numeric, numeric)
from anon;
grant execute on function public.save_daily_report_unit(uuid, uuid, numeric, numeric)
to authenticated;

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
  select p.company_id, lower(coalesce(p.role, '')), p.active
  into v_company_id, v_role, v_profile_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_profile_active is not true or
     v_role not in ('foreman', 'gf', 'admin') then
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

revoke all on function public.delete_daily_report_unit(uuid, uuid)
from public;
revoke all on function public.delete_daily_report_unit(uuid, uuid)
from anon;
grant execute on function public.delete_daily_report_unit(uuid, uuid)
to authenticated;

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
  select p.company_id, lower(coalesce(p.role, '')), p.active
  into v_company_id, v_role, v_profile_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_profile_active is not true or
     v_role not in ('foreman', 'gf', 'admin') then
    raise exception using
      errcode = '42501',
      message = 'An active Foreman, General Foreman or Admin profile is required.';
  end if;

  v_can_see_actual := v_role in ('admin', 'gf');

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
    and (v_role in ('admin', 'gf') or dr.created_by = auth.uid())
  group by dr.id;
end;
$$;

revoke all on function public.get_daily_report_value_summaries() from public;
revoke all on function public.get_daily_report_value_summaries() from anon;
grant execute on function public.get_daily_report_value_summaries()
to authenticated;

commit;
