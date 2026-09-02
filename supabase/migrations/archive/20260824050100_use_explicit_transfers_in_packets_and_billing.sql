begin;

create or replace function public.finalize_utility_packet_import(p_import_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_package_id uuid; v_source_filename text; v_company_id uuid; v_job_id uuid;
  v_rows jsonb; v_row jsonb; v_work_point_id uuid; v_result jsonb;
begin
  if not public.linecrew_can_manage_job_packages() then
    raise exception using errcode='42501',message='You do not have permission to import job packets.';
  end if;
  select i.job_package_id,i.source_filename,i.company_id,p.job_id
  into v_package_id,v_source_filename,v_company_id,v_job_id
  from public.utility_packet_imports i
  join public.job_packages p on p.id=i.job_package_id and p.company_id=i.company_id
  join public.profiles profile on profile.id=auth.uid() and profile.company_id=i.company_id and profile.active
  where i.id=p_import_id and i.status='review' for update;
  if v_package_id is null then
    raise exception using errcode='P0002',message='Packet review was not found or was already finalized.';
  end if;
  if exists(select 1 from public.utility_packet_import_rows r where r.import_id=p_import_id
      and r.include_in_import and nullif(btrim(r.contractor_unit_code),'') is null) then
    raise exception using errcode='22023',message='Every included production row must have a Contractor Unit. Exclude material-only rows or correct the mapping.';
  end if;
  if exists(select 1 from public.utility_packet_import_rows r where r.import_id=p_import_id
      and r.include_in_import and r.contractor_unit_code is not null
      and public.resolve_utility_packet_price_item(r.import_id,r.contractor_unit_code,r.work_type) is null) then
    raise exception using errcode='P0002',message='One or more Contractor Units were not found in the job Price Book. Correct the unmatched rows before importing.';
  end if;

  select jsonb_agg(jsonb_build_object(
    'work_point_code',g.work_point_code,'work_point_description',g.work_point_description,
    'price_book_item_id',g.price_book_item_id,'unit_code',g.canonical_unit_code,
    'install_quantity',g.install_quantity,'transfer_quantity',g.transfer_quantity,
    'retirement_quantity',g.retirement_quantity
  ) order by g.work_point_code,g.canonical_unit_code) into v_rows
  from (
    select min(btrim(r.work_point_code)) work_point_code,
      max(r.work_point_description) work_point_description,item.id price_book_item_id,
      item.item_code canonical_unit_code,
      sum(case when lower(r.work_type)='install' then r.estimated_quantity else 0 end) install_quantity,
      sum(case when lower(r.work_type)='transfer' then r.estimated_quantity else 0 end) transfer_quantity,
      sum(case when lower(r.work_type)='remove' then r.estimated_quantity else 0 end) retirement_quantity
    from public.utility_packet_import_rows r
    join public.price_book_items item on item.id=public.resolve_utility_packet_price_item(
      r.import_id,r.contractor_unit_code,r.work_type)
    where r.import_id=p_import_id and r.include_in_import and r.contractor_unit_code is not null
    group by public.normalize_work_point_key(r.work_point_code),item.id,item.item_code
  ) g;
  if v_rows is null or jsonb_array_length(v_rows)=0 then
    raise exception using errcode='22023',message='No reviewed Contractor Unit rows are selected for import.';
  end if;

  for v_row in select value from jsonb_array_elements(v_rows) loop
    select w.id into v_work_point_id from public.job_package_work_points w
    where w.company_id=v_company_id and w.job_package_id=v_package_id
      and public.normalize_work_point_key(w.work_point_code)=
          public.normalize_work_point_key(v_row->>'work_point_code')
    order by w.created_at limit 1;
    if v_work_point_id is null then
      insert into public.job_package_work_points(company_id,job_package_id,job_id,work_point_code,description,created_by)
      values(v_company_id,v_package_id,v_job_id,btrim(v_row->>'work_point_code'),
        nullif(btrim(coalesce(v_row->>'work_point_description','')),''),auth.uid())
      returning id into v_work_point_id;
    end if;
    insert into public.job_package_authorized_units(
      company_id,job_package_id,work_point_id,price_book_item_id,unit_code,
      authorized_install_quantity,authorized_transfer_quantity,authorized_retirement_quantity,created_by
    ) values (
      v_company_id,v_package_id,v_work_point_id,(v_row->>'price_book_item_id')::uuid,
      v_row->>'unit_code',(v_row->>'install_quantity')::numeric,
      (v_row->>'transfer_quantity')::numeric,(v_row->>'retirement_quantity')::numeric,auth.uid()
    ) on conflict (work_point_id,price_book_item_id) do update set
      authorized_install_quantity=excluded.authorized_install_quantity,
      authorized_transfer_quantity=excluded.authorized_transfer_quantity,
      authorized_retirement_quantity=excluded.authorized_retirement_quantity,
      unit_code=excluded.unit_code,updated_at=now();
    v_work_point_id:=null;
  end loop;

  update public.job_packages set source_filename=v_source_filename,updated_at=now()
  where id=v_package_id and company_id=v_company_id;
  update public.jobs job set price_book_id=(select book.id from public.price_books book
    where book.company_id=v_company_id and book.contract_id=job.contract_id and book.active
    order by book.effective_start desc nulls last,book.updated_at desc nulls last limit 1)
  where job.id=v_job_id and job.company_id=v_company_id and job.price_book_id is null;
  update public.utility_packet_imports set status='imported',reviewed_by=auth.uid(),reviewed_at=now()
  where id=p_import_id;
  v_result:=jsonb_build_object('imported_rows',jsonb_array_length(v_rows));
  return v_result||jsonb_build_object(
    'source_rows',(select count(*) from public.utility_packet_import_rows r where r.import_id=p_import_id),
    'material_only_rows',(select count(*) from public.utility_packet_import_rows r where r.import_id=p_import_id and r.contractor_unit_code is null),
    'consolidated_rows',jsonb_array_length(v_rows));
end; $$;

revoke all on function public.finalize_utility_packet_import(uuid) from public,anon;
grant execute on function public.finalize_utility_packet_import(uuid) to authenticated;

create or replace function public.create_billing_export_batch(
  p_job_id uuid,p_date_from date default null,p_date_to date default null,
  p_include_redlines boolean default false,p_notes text default null
)
returns uuid language plpgsql security definer set search_path='' as $$
declare
  v_company_id uuid; v_role text; v_active boolean; v_batch_id uuid:=gen_random_uuid();
  v_batch_number text; v_inserted integer;
begin
  select p.company_id,lower(coalesce(p.role,'')),p.active into v_company_id,v_role,v_active
  from public.profiles p where p.id=auth.uid();
  if v_company_id is null or not v_active or v_role not in ('admin','owner','superintendent') then
    raise exception using errcode='42501',message='Only an active Admin, Owner or Superintendent can create billing exports.';
  end if;
  if v_role='superintendent' and (not public.linecrew_has_capability('reporting') or
    not public.linecrew_has_capability('actual_pricing')) then
    raise exception using errcode='42501',message='This Superintendent needs Reporting and Actual Pricing permissions for billing exports.';
  end if;
  if p_date_from is not null and p_date_to is not null and p_date_from>p_date_to then
    raise exception using errcode='22023',message='From Date cannot be after Through Date.';
  end if;
  if not exists(select 1 from public.jobs j where j.id=p_job_id and j.company_id=v_company_id) then
    raise exception using errcode='P0002',message='Job was not found in your company.';
  end if;
  v_batch_number:='BILL-'||to_char(current_date,'YYYYMMDD')||'-'||upper(substr(replace(v_batch_id::text,'-',''),1,6));
  insert into public.billing_export_batches(id,company_id,job_id,batch_number,date_from,date_to,include_redlines,notes,created_by)
  values(v_batch_id,v_company_id,p_job_id,v_batch_number,p_date_from,p_date_to,
    coalesce(p_include_redlines,false),nullif(btrim(coalesce(p_notes,'')),''),auth.uid());

  with eligible as (
    select r.id daily_report_id,r.work_date report_date,r.foreman_name,r.crew_name,
      l.location_line_id production_location_id,l.price_book_item_id,l.pole_location work_point,
      l.item_code unit_code,l.item_name unit_name,l.description unit_description,
      l.install_quantity,l.transfer_quantity,l.retirement_quantity,
      l.actual_install_price,l.actual_retirement_price,l.authorization_status
    from public.daily_reports r cross join lateral public.get_daily_report_unit_locations_v2(r.id) l
    where r.company_id=v_company_id and r.job_id=p_job_id and lower(coalesce(r.status,''))='approved'
      and (p_date_from is null or r.work_date>=p_date_from)
      and (p_date_to is null or r.work_date<=p_date_to)
      and l.authorization_status in ('authorized','redline')
      and (l.authorization_status='authorized' or coalesce(p_include_redlines,false))
  ), actions as (
    select e.*,'INSTALL'::text work_type,e.install_quantity quantity,e.actual_install_price unit_price
    from eligible e where e.install_quantity>0
    union all
    select e.*,'TRANSFER'::text,e.transfer_quantity,e.actual_install_price
    from eligible e where e.transfer_quantity>0
    union all
    select e.*,'REMOVE'::text,e.retirement_quantity,e.actual_retirement_price
    from eligible e where e.retirement_quantity>0
  )
  insert into public.billing_export_lines(company_id,billing_batch_id,job_id,daily_report_id,
    production_location_id,report_date,foreman_name,crew_name,work_point,price_book_item_id,
    unit_code,unit_name,unit_description,work_type,quantity,unit_price,extended_value,authorization_status)
  select v_company_id,v_batch_id,p_job_id,a.daily_report_id,a.production_location_id,a.report_date,
    a.foreman_name,a.crew_name,a.work_point,a.price_book_item_id,a.unit_code,a.unit_name,
    a.unit_description,a.work_type,a.quantity,coalesce(a.unit_price,0),
    round(a.quantity*coalesce(a.unit_price,0),2),a.authorization_status
  from actions a where not exists(select 1 from public.billing_export_lines prior
    where prior.company_id=v_company_id and prior.production_location_id=a.production_location_id
      and prior.work_type=a.work_type and prior.active);
  get diagnostics v_inserted=row_count;
  if v_inserted=0 then
    delete from public.billing_export_batches where id=v_batch_id;
    raise exception using errcode='P0002',message='No approved, unbilled unit lines match this job and date range.';
  end if;
  update public.billing_export_batches b set
    authorized_line_count=(select count(*) from public.billing_export_lines l where l.billing_batch_id=v_batch_id and l.authorization_status='authorized'),
    redline_line_count=(select count(*) from public.billing_export_lines l where l.billing_batch_id=v_batch_id and l.authorization_status='redline'),
    total_value=(select coalesce(sum(l.extended_value),0) from public.billing_export_lines l where l.billing_batch_id=v_batch_id)
  where b.id=v_batch_id;
  return v_batch_id;
end; $$;

revoke all on function public.create_billing_export_batch(uuid,date,date,boolean,text) from public,anon;
-- v2/v3 are the only public billing creation APIs.
revoke all on function public.create_billing_export_batch(uuid,date,date,boolean,text) from authenticated;

commit;
