begin;

alter table public.job_package_authorized_units
  add column if not exists authorized_transfer_quantity numeric(12,2) not null default 0;
alter table public.daily_production_unit_locations
  add column if not exists transfer_quantity numeric(12,2) not null default 0;

alter table public.job_package_authorized_units
  drop constraint if exists job_package_authorized_units_nonnegative,
  drop constraint if exists job_package_authorized_units_has_quantity;
alter table public.job_package_authorized_units
  add constraint job_package_authorized_units_nonnegative check (
    authorized_install_quantity >= 0 and authorized_transfer_quantity >= 0 and
    authorized_retirement_quantity >= 0
  ),
  add constraint job_package_authorized_units_has_quantity check (
    authorized_install_quantity > 0 or authorized_transfer_quantity > 0 or
    authorized_retirement_quantity > 0
  );

alter table public.daily_production_unit_locations
  drop constraint if exists daily_production_unit_locations_nonnegative,
  drop constraint if exists daily_production_unit_locations_has_quantity;
alter table public.daily_production_unit_locations
  add constraint daily_production_unit_locations_nonnegative check (
    install_quantity >= 0 and transfer_quantity >= 0 and retirement_quantity >= 0
  ),
  add constraint daily_production_unit_locations_has_quantity check (
    install_quantity > 0 or transfer_quantity > 0 or retirement_quantity > 0
  );

-- Preserve existing production that was already reviewed and billed as TRANSFER.
with confirmed_transfer_items as (
  select distinct line.company_id,line.price_book_item_id
  from public.billing_export_lines line
  where line.work_type='TRANSFER'
)
update public.daily_production_unit_locations location
set transfer_quantity=location.install_quantity,install_quantity=0,updated_at=now()
from confirmed_transfer_items confirmed
where confirmed.company_id=location.company_id
  and confirmed.price_book_item_id=location.price_book_item_id
  and location.install_quantity>0 and location.transfer_quantity=0;

with confirmed_transfer_items as (
  select distinct line.company_id,line.price_book_item_id
  from public.billing_export_lines line
  where line.work_type='TRANSFER'
)
update public.job_package_authorized_units authorized
set authorized_transfer_quantity=authorized.authorized_install_quantity,
    authorized_install_quantity=0,updated_at=now()
from confirmed_transfer_items confirmed
where confirmed.company_id=authorized.company_id
  and confirmed.price_book_item_id=authorized.price_book_item_id
  and authorized.authorized_install_quantity>0
  and authorized.authorized_transfer_quantity=0;

create or replace function public.save_daily_report_unit_location_v2(
  p_report_id uuid,p_price_book_item_id uuid,p_pole_location text,
  p_install_quantity numeric,p_transfer_quantity numeric,p_retirement_quantity numeric
)
returns uuid language plpgsql security definer set search_path='' as $$
declare
  v_company_id uuid; v_role text; v_active boolean; v_report_company_id uuid;
  v_report_creator uuid; v_report_status text; v_location text;
  v_total_install numeric; v_total_retirement numeric;
  v_aggregate_line_id uuid; v_location_line_id uuid;
begin
  v_location:=btrim(coalesce(p_pole_location,''));
  if v_location='' then raise exception using errcode='22023',message='Enter a pole or work location.'; end if;
  if coalesce(p_install_quantity,0)<0 or coalesce(p_transfer_quantity,0)<0 or
     coalesce(p_retirement_quantity,0)<0 or
     coalesce(p_install_quantity,0)+coalesce(p_transfer_quantity,0)+coalesce(p_retirement_quantity,0)=0 then
    raise exception using errcode='22023',message='Enter an installed, transferred or removed quantity greater than zero.';
  end if;
  select p.company_id,lower(coalesce(p.role,'')),p.active into v_company_id,v_role,v_active
  from public.profiles p where p.id=auth.uid();
  if v_company_id is null or not v_active or v_role not in ('foreman','gf','admin','owner','superintendent') then
    raise exception using errcode='42501',message='An active Foreman, General Foreman or Admin profile is required.';
  end if;
  if v_role='superintendent' and not public.linecrew_has_capability('production_review') then
    raise exception using errcode='42501',message='This Superintendent does not have production review permission.';
  end if;
  select r.company_id,r.created_by,lower(coalesce(r.status,'draft'))
  into v_report_company_id,v_report_creator,v_report_status
  from public.daily_reports r where r.id=p_report_id;
  if v_report_company_id is null or v_report_company_id<>v_company_id then
    raise exception using errcode='P0002',message='Daily report was not found in your company.';
  end if;
  if v_report_status<>'draft' then raise exception using errcode='42501',message='Units can be changed only while the report is a draft.'; end if;
  if v_role='foreman' and v_report_creator is distinct from auth.uid() then
    raise exception using errcode='42501',message='Foremen can change units only on their own reports.';
  end if;

  select coalesce(sum(l.install_quantity+l.transfer_quantity),0)+
           coalesce(p_install_quantity,0)+coalesce(p_transfer_quantity,0),
         coalesce(sum(l.retirement_quantity),0)+coalesce(p_retirement_quantity,0)
  into v_total_install,v_total_retirement
  from public.daily_production_unit_locations l
  where l.daily_report_id=p_report_id and l.price_book_item_id=p_price_book_item_id
    and l.company_id=v_company_id and l.pole_location_key<>lower(v_location);

  v_aggregate_line_id:=public.save_daily_report_unit(
    p_report_id,p_price_book_item_id,v_total_install,v_total_retirement
  );
  insert into public.daily_production_unit_locations(
    company_id,daily_report_id,daily_production_unit_id,price_book_item_id,pole_location,
    install_quantity,transfer_quantity,retirement_quantity,created_by,updated_at
  ) values (
    v_company_id,p_report_id,v_aggregate_line_id,p_price_book_item_id,v_location,
    coalesce(p_install_quantity,0),coalesce(p_transfer_quantity,0),
    coalesce(p_retirement_quantity,0),auth.uid(),now()
  ) on conflict (daily_report_id,price_book_item_id,pole_location_key) do update set
    daily_production_unit_id=excluded.daily_production_unit_id,pole_location=excluded.pole_location,
    install_quantity=excluded.install_quantity,transfer_quantity=excluded.transfer_quantity,
    retirement_quantity=excluded.retirement_quantity,updated_at=now()
  returning id into v_location_line_id;
  return v_location_line_id;
end; $$;

revoke all on function public.save_daily_report_unit_location_v2(uuid,uuid,text,numeric,numeric,numeric) from public,anon;
grant execute on function public.save_daily_report_unit_location_v2(uuid,uuid,text,numeric,numeric,numeric) to authenticated;

create or replace function public.get_daily_report_unit_locations_v2(p_report_id uuid)
returns table(
  location_line_id uuid,price_book_item_id uuid,item_code text,item_name text,description text,
  unit_of_measure text,category text,pole_location text,install_price numeric,retirement_price numeric,
  actual_install_price numeric,actual_retirement_price numeric,adjusted_install_price numeric,
  adjusted_retirement_price numeric,has_adjustment boolean,install_quantity numeric,
  transfer_quantity numeric,retirement_quantity numeric,actual_line_value numeric,
  adjusted_line_value numeric,visible_line_value numeric,authorization_status text,authorization_note text
) language plpgsql stable security definer set search_path='' as $$
declare
  v_company_id uuid; v_role text; v_active boolean; v_report_company_id uuid;
  v_report_creator uuid; v_report_job_id uuid; v_can_see_actual boolean;
begin
  select p.company_id,lower(coalesce(p.role,'')),p.active into v_company_id,v_role,v_active
  from public.profiles p where p.id=auth.uid();
  if v_company_id is null or not v_active or v_role not in ('foreman','gf','superintendent','admin','owner') then
    raise exception using errcode='42501',message='An active production profile is required.';
  end if;
  select r.company_id,r.created_by,r.job_id into v_report_company_id,v_report_creator,v_report_job_id
  from public.daily_reports r where r.id=p_report_id;
  if v_report_company_id is null or v_report_company_id<>v_company_id then
    raise exception using errcode='P0002',message='Daily report was not found in your company.';
  end if;
  if v_role='foreman' and v_report_creator is distinct from auth.uid() then
    raise exception using errcode='42501',message='Foremen can view unit production only on their own reports.';
  end if;
  v_can_see_actual:=v_role in ('admin','gf','owner') or
    (v_role='superintendent' and public.linecrew_has_capability('actual_pricing'));

  return query
  select l.id,u.price_book_item_id,u.item_code,u.item_name,u.description,u.unit_of_measure,u.category,
    l.pole_location,
    case when v_can_see_actual then u.actual_install_price else u.adjusted_install_price end,
    case when v_can_see_actual then u.actual_retirement_price else u.adjusted_retirement_price end,
    case when v_can_see_actual then u.actual_install_price else null end,
    case when v_can_see_actual then u.actual_retirement_price else null end,
    u.adjusted_install_price,u.adjusted_retirement_price,u.has_adjustment,
    l.install_quantity,l.transfer_quantity,l.retirement_quantity,
    case when v_can_see_actual then round((l.install_quantity+l.transfer_quantity)*u.actual_install_price+
      l.retirement_quantity*u.actual_retirement_price,2) else null end,
    round((l.install_quantity+l.transfer_quantity)*u.adjusted_install_price+
      l.retirement_quantity*u.adjusted_retirement_price,2),
    case when v_can_see_actual then round((l.install_quantity+l.transfer_quantity)*u.actual_install_price+
      l.retirement_quantity*u.actual_retirement_price,2)
    else round((l.install_quantity+l.transfer_quantity)*u.adjusted_install_price+
      l.retirement_quantity*u.adjusted_retirement_price,2) end,
    case when packages.package_count=0 then 'pending_packet'
      when auths.authorized_unit_count=0 then 'redline'
      when production.reported_install>auths.authorized_install or
           production.reported_transfer>auths.authorized_transfer or
           production.reported_retirement>auths.authorized_retirement then 'redline'
      else 'authorized' end,
    case when packages.package_count=0 then 'No active utility job packet has been added yet. This entry will reconcile when a packet is imported.'
      when auths.authorized_unit_count=0 then 'This unit is not authorized at this pole or work point in the active utility job packet.'
      when production.reported_install>auths.authorized_install or
           production.reported_transfer>auths.authorized_transfer or
           production.reported_retirement>auths.authorized_retirement
        then 'Reported quantity exceeds the active utility-authorized quantity at this pole or work point.'
      else null end
  from public.daily_production_unit_locations l
  join public.daily_production_units u on u.id=l.daily_production_unit_id and u.company_id=l.company_id
    and u.daily_report_id=l.daily_report_id and u.price_book_item_id=l.price_book_item_id
  cross join lateral (
    select count(*)::integer package_count from public.job_packages p
    where p.company_id=v_company_id and p.job_id=v_report_job_id and p.status='active'
  ) packages
  cross join lateral (
    select count(a.id)::integer authorized_unit_count,
      coalesce(sum(a.authorized_install_quantity),0) authorized_install,
      coalesce(sum(a.authorized_transfer_quantity),0) authorized_transfer,
      coalesce(sum(a.authorized_retirement_quantity),0) authorized_retirement
    from public.job_packages p
    join public.job_package_work_points w on w.job_package_id=p.id and w.company_id=p.company_id
    join public.job_package_authorized_units a on a.work_point_id=w.id and a.company_id=w.company_id
    where p.company_id=v_company_id and p.job_id=v_report_job_id and p.status='active'
      and public.normalize_work_point_key(w.work_point_code)=public.normalize_work_point_key(l.pole_location)
      and a.price_book_item_id=l.price_book_item_id
  ) auths
  cross join lateral (
    select coalesce(sum(o.install_quantity),0) reported_install,
      coalesce(sum(o.transfer_quantity),0) reported_transfer,
      coalesce(sum(o.retirement_quantity),0) reported_retirement
    from public.daily_production_unit_locations o join public.daily_reports r
      on r.id=o.daily_report_id and r.company_id=o.company_id
    where o.company_id=v_company_id and r.job_id=v_report_job_id
      and lower(coalesce(r.status,''))<>'rejected' and o.price_book_item_id=l.price_book_item_id
      and public.normalize_work_point_key(o.pole_location)=public.normalize_work_point_key(l.pole_location)
  ) production
  where l.daily_report_id=p_report_id and l.company_id=v_company_id
  order by l.pole_location_key,u.item_code;
end; $$;

revoke all on function public.get_daily_report_unit_locations_v2(uuid) from public,anon;
grant execute on function public.get_daily_report_unit_locations_v2(uuid) to authenticated;

commit;
