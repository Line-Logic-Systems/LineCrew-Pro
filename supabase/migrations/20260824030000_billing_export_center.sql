begin;

create table if not exists public.billing_export_batches (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  job_id uuid not null references public.jobs(id) on delete restrict,
  batch_number text not null,
  date_from date,
  date_to date,
  include_redlines boolean not null default false,
  status text not null default 'draft'
    check (status in ('draft','exported','submitted','paid','void')),
  authorized_line_count integer not null default 0,
  redline_line_count integer not null default 0,
  total_value numeric(14,2) not null default 0,
  notes text,
  created_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  exported_at timestamptz,
  submitted_at timestamptz,
  paid_at timestamptz,
  voided_at timestamptz,
  unique(company_id, batch_number)
);

create table if not exists public.billing_export_lines (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  billing_batch_id uuid not null references public.billing_export_batches(id) on delete cascade,
  job_id uuid not null references public.jobs(id) on delete restrict,
  daily_report_id uuid not null references public.daily_reports(id) on delete restrict,
  production_location_id uuid not null references public.daily_production_unit_locations(id) on delete restrict,
  report_date date not null,
  foreman_name text,
  crew_name text,
  work_point text not null,
  price_book_item_id uuid not null references public.price_book_items(id) on delete restrict,
  unit_code text not null,
  unit_name text,
  unit_description text,
  work_type text not null check (work_type in ('INSTALL','REMOVE','TRANSFER')),
  quantity numeric(14,2) not null check (quantity > 0),
  unit_price numeric(14,2) not null default 0,
  extended_value numeric(14,2) not null default 0,
  authorization_status text not null check (authorization_status in ('authorized','redline')),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create unique index if not exists billing_export_lines_active_source_action_uidx
  on public.billing_export_lines(company_id, production_location_id, work_type)
  where active;
create index if not exists billing_export_batches_company_created_idx
  on public.billing_export_batches(company_id, created_at desc);
create index if not exists billing_export_lines_batch_idx
  on public.billing_export_lines(billing_batch_id, unit_code, work_point);

alter table public.billing_export_batches enable row level security;
alter table public.billing_export_lines enable row level security;
revoke all on public.billing_export_batches from public, anon, authenticated;
revoke all on public.billing_export_lines from public, anon, authenticated;

create or replace function public.create_billing_export_batch(
  p_job_id uuid,
  p_date_from date default null,
  p_date_to date default null,
  p_include_redlines boolean default false,
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
  v_batch_id uuid := gen_random_uuid();
  v_batch_number text;
  v_inserted integer;
begin
  select profile.company_id, lower(coalesce(profile.role,'')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin','owner','superintendent') then
    raise exception using errcode='42501',
      message='Only an active Admin, Owner or Superintendent can create billing exports.';
  end if;
  if v_role = 'superintendent' and (
    not public.linecrew_has_capability('reporting') or
    not public.linecrew_has_capability('actual_pricing')
  ) then
    raise exception using errcode='42501',
      message='This Superintendent needs Reporting and Actual Pricing permissions for billing exports.';
  end if;
  if p_date_from is not null and p_date_to is not null and p_date_from > p_date_to then
    raise exception using errcode='22023', message='From Date cannot be after Through Date.';
  end if;
  if not exists (
    select 1 from public.jobs job
    where job.id=p_job_id and job.company_id=v_company_id
  ) then
    raise exception using errcode='P0002', message='Job was not found in your company.';
  end if;

  v_batch_number := 'BILL-' || to_char(current_date,'YYYYMMDD') || '-' ||
    upper(substr(replace(v_batch_id::text,'-',''),1,6));

  insert into public.billing_export_batches(
    id,company_id,job_id,batch_number,date_from,date_to,include_redlines,notes,created_by
  ) values (
    v_batch_id,v_company_id,p_job_id,v_batch_number,p_date_from,p_date_to,
    coalesce(p_include_redlines,false),nullif(btrim(coalesce(p_notes,'')),''),auth.uid()
  );

  with eligible as (
    select
      report.id as daily_report_id,
      report.work_date as report_date,
      report.foreman_name,
      report.crew_name,
      location.location_line_id as production_location_id,
      location.price_book_item_id,
      location.pole_location as work_point,
      location.item_code as unit_code,
      location.item_name as unit_name,
      location.description as unit_description,
      location.install_quantity,
      location.retirement_quantity,
      location.actual_install_price,
      location.actual_retirement_price,
      location.authorization_status
    from public.daily_reports report
    cross join lateral public.get_daily_report_unit_locations(report.id) location
    where report.company_id=v_company_id
      and report.job_id=p_job_id
      and lower(coalesce(report.status,''))='approved'
      and (p_date_from is null or report.work_date >= p_date_from)
      and (p_date_to is null or report.work_date <= p_date_to)
      and location.authorization_status in ('authorized','redline')
      and (location.authorization_status='authorized' or coalesce(p_include_redlines,false))
  ), actions as (
    select eligible.*, 
      case when right(upper(btrim(eligible.unit_code)),1)='T' then 'TRANSFER' else 'INSTALL' end as work_type,
      eligible.install_quantity as quantity,
      eligible.actual_install_price as unit_price
    from eligible where eligible.install_quantity > 0
    union all
    select eligible.*, 'REMOVE' as work_type,
      eligible.retirement_quantity as quantity,
      eligible.actual_retirement_price as unit_price
    from eligible where eligible.retirement_quantity > 0
  )
  insert into public.billing_export_lines(
    company_id,billing_batch_id,job_id,daily_report_id,production_location_id,
    report_date,foreman_name,crew_name,work_point,price_book_item_id,unit_code,
    unit_name,unit_description,work_type,quantity,unit_price,extended_value,
    authorization_status
  )
  select
    v_company_id,v_batch_id,p_job_id,action.daily_report_id,action.production_location_id,
    action.report_date,action.foreman_name,action.crew_name,action.work_point,
    action.price_book_item_id,action.unit_code,action.unit_name,action.unit_description,
    action.work_type,action.quantity,coalesce(action.unit_price,0),
    round(action.quantity * coalesce(action.unit_price,0),2),action.authorization_status
  from actions action
  where not exists (
    select 1 from public.billing_export_lines prior
    where prior.company_id=v_company_id
      and prior.production_location_id=action.production_location_id
      and prior.work_type=action.work_type
      and prior.active
  );

  get diagnostics v_inserted = row_count;
  if v_inserted = 0 then
    delete from public.billing_export_batches where id=v_batch_id;
    raise exception using errcode='P0002',
      message='No approved, unbilled unit lines match this job and date range.';
  end if;

  update public.billing_export_batches batch set
    authorized_line_count=(select count(*) from public.billing_export_lines line
      where line.billing_batch_id=v_batch_id and line.authorization_status='authorized'),
    redline_line_count=(select count(*) from public.billing_export_lines line
      where line.billing_batch_id=v_batch_id and line.authorization_status='redline'),
    total_value=(select coalesce(sum(line.extended_value),0) from public.billing_export_lines line
      where line.billing_batch_id=v_batch_id)
  where batch.id=v_batch_id;

  return v_batch_id;
end;
$$;

create or replace function public.get_billing_export_batches()
returns table(
  batch_id uuid,batch_number text,job_id uuid,job_number text,job_name text,
  date_from date,date_to date,include_redlines boolean,status text,
  authorized_line_count integer,redline_line_count integer,total_value numeric,
  notes text,created_by_name text,created_at timestamptz,exported_at timestamptz,
  submitted_at timestamptz,paid_at timestamptz,voided_at timestamptz
)
language plpgsql stable security definer set search_path=''
as $$
declare v_company_id uuid; v_role text; v_active boolean;
begin
  select p.company_id,lower(coalesce(p.role,'')),p.active
  into v_company_id,v_role,v_active from public.profiles p where p.id=auth.uid();
  if v_company_id is null or v_active is not true or
     v_role not in ('admin','owner','superintendent') then
    raise exception using errcode='42501',message='Billing export access is required.';
  end if;
  if v_role='superintendent' and (
    not public.linecrew_has_capability('reporting') or
    not public.linecrew_has_capability('actual_pricing')
  ) then
    raise exception using errcode='42501',message='Reporting and Actual Pricing permissions are required.';
  end if;
  return query
  select b.id,b.batch_number,b.job_id,j.job_number,j.job_name,b.date_from,b.date_to,
    b.include_redlines,b.status,b.authorized_line_count,b.redline_line_count,b.total_value,
    b.notes,p.full_name,b.created_at,b.exported_at,b.submitted_at,b.paid_at,b.voided_at
  from public.billing_export_batches b
  join public.jobs j on j.id=b.job_id and j.company_id=b.company_id
  left join public.profiles p on p.id=b.created_by
  where b.company_id=v_company_id
  order by b.created_at desc;
end;
$$;

create or replace function public.get_billing_export_batch_lines(p_batch_id uuid)
returns table(
  line_id uuid,batch_number text,job_number text,job_name text,customer_name text,
  utility_name text,report_date date,foreman_name text,crew_name text,work_point text,
  unit_code text,unit_name text,unit_description text,work_type text,quantity numeric,
  unit_price numeric,extended_value numeric,authorization_status text
)
language plpgsql stable security definer set search_path=''
as $$
declare v_company_id uuid; v_role text; v_active boolean;
begin
  select p.company_id,lower(coalesce(p.role,'')),p.active
  into v_company_id,v_role,v_active from public.profiles p where p.id=auth.uid();
  if v_company_id is null or v_active is not true or
     v_role not in ('admin','owner','superintendent') then
    raise exception using errcode='42501',message='Billing export access is required.';
  end if;
  if v_role='superintendent' and (
    not public.linecrew_has_capability('reporting') or
    not public.linecrew_has_capability('actual_pricing')
  ) then
    raise exception using errcode='42501',message='Reporting and Actual Pricing permissions are required.';
  end if;
  return query
  select l.id,b.batch_number,j.job_number,j.job_name,j.customer_name,j.utility_name,
    l.report_date,l.foreman_name,l.crew_name,l.work_point,l.unit_code,l.unit_name,
    l.unit_description,l.work_type,l.quantity,l.unit_price,l.extended_value,
    l.authorization_status
  from public.billing_export_lines l
  join public.billing_export_batches b on b.id=l.billing_batch_id and b.company_id=l.company_id
  join public.jobs j on j.id=l.job_id and j.company_id=l.company_id
  where l.company_id=v_company_id and l.billing_batch_id=p_batch_id
  order by case when l.authorization_status='authorized' then 0 else 1 end,
    l.report_date,l.work_point,l.unit_code,l.work_type;
end;
$$;

create or replace function public.set_billing_export_batch_status(
  p_batch_id uuid,p_status text
)
returns void
language plpgsql security definer set search_path=''
as $$
declare v_company_id uuid; v_role text; v_active boolean; v_current text; v_next text;
begin
  select p.company_id,lower(coalesce(p.role,'')),p.active
  into v_company_id,v_role,v_active from public.profiles p where p.id=auth.uid();
  if v_company_id is null or v_active is not true or
     v_role not in ('admin','owner','superintendent') then
    raise exception using errcode='42501',message='Billing export access is required.';
  end if;
  if v_role='superintendent' and (
    not public.linecrew_has_capability('reporting') or
    not public.linecrew_has_capability('actual_pricing')
  ) then
    raise exception using errcode='42501',message='Reporting and Actual Pricing permissions are required.';
  end if;
  v_next:=lower(btrim(coalesce(p_status,'')));
  if v_next not in ('exported','submitted','paid','void') then
    raise exception using errcode='22023',message='Invalid billing batch status.';
  end if;
  select b.status into v_current from public.billing_export_batches b
    where b.id=p_batch_id and b.company_id=v_company_id for update;
  if v_current is null then
    raise exception using errcode='P0002',message='Billing batch was not found.';
  end if;
  if v_current='void' or v_current='paid' then
    raise exception using errcode='23514',message='A paid or void billing batch cannot be changed.';
  end if;
  if v_next='void' then
    update public.billing_export_lines set active=false
      where billing_batch_id=p_batch_id and company_id=v_company_id;
  end if;
  update public.billing_export_batches set
    status=v_next,
    exported_at=case when v_next='exported' then coalesce(exported_at,now()) else exported_at end,
    submitted_at=case when v_next='submitted' then coalesce(submitted_at,now()) else submitted_at end,
    paid_at=case when v_next='paid' then coalesce(paid_at,now()) else paid_at end,
    voided_at=case when v_next='void' then coalesce(voided_at,now()) else voided_at end
  where id=p_batch_id and company_id=v_company_id;
end;
$$;

revoke all on function public.create_billing_export_batch(uuid,date,date,boolean,text) from public,anon;
revoke all on function public.get_billing_export_batches() from public,anon;
revoke all on function public.get_billing_export_batch_lines(uuid) from public,anon;
revoke all on function public.set_billing_export_batch_status(uuid,text) from public,anon;
grant execute on function public.create_billing_export_batch(uuid,date,date,boolean,text) to authenticated;
grant execute on function public.get_billing_export_batches() to authenticated;
grant execute on function public.get_billing_export_batch_lines(uuid) to authenticated;
grant execute on function public.set_billing_export_batch_status(uuid,text) to authenticated;

commit;
