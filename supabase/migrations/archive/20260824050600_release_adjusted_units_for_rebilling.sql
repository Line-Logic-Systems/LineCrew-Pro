-- A full billing adjustment reverses both money and billed-unit ownership.
-- The paid source batch remains immutable, its history is preserved, and its
-- production actions become available for a later billing batch.

create or replace function public.create_billing_credit_batch(p_paid_batch_id uuid,p_reason text)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_company uuid; v_role text; v_active boolean; v_source public.billing_export_batches%rowtype;
  v_id uuid:=gen_random_uuid(); v_number text; v_sequence integer;
begin
  select p.company_id,lower(coalesce(p.role,'')),p.active into v_company,v_role,v_active
  from public.profiles p where p.id=auth.uid();
  if v_company is null or not v_active or v_role not in ('owner','admin') then
    raise exception using errcode='42501',message='Only Admin or Owner can create a billing adjustment.';
  end if;
  if nullif(btrim(coalesce(p_reason,'')),'') is null then
    raise exception using errcode='22023',message='A billing-adjustment reason is required.';
  end if;

  select * into v_source from public.billing_export_batches b
    where b.id=p_paid_batch_id and b.company_id=v_company
      and b.status='paid' and b.billing_type<>'credit' for update;
  if v_source.id is null then
    raise exception using errcode='23514',message='Choose a paid original billing batch.';
  end if;
  if exists(select 1 from public.billing_export_batches b
    where b.parent_batch_id=v_source.id and b.billing_type='credit' and b.status<>'void') then
    raise exception using errcode='23505',message='An active billing adjustment already exists for this paid batch.';
  end if;

  select coalesce(max(b.billing_sequence),0)+1 into v_sequence
  from public.billing_export_batches b
  where b.company_id=v_company and b.job_id=v_source.job_id;
  v_number:='CREDIT-'||to_char(current_date,'YYYYMMDD')||'-'||upper(substr(replace(v_id::text,'-',''),1,6));

  insert into public.billing_export_batches(id,company_id,job_id,batch_number,date_from,date_to,
    include_redlines,status,authorized_line_count,redline_line_count,total_value,notes,created_by,
    billing_type,billing_sequence,correction_reason,parent_batch_id)
  values(v_id,v_company,v_source.job_id,v_number,v_source.date_from,v_source.date_to,
    v_source.include_redlines,'draft',v_source.authorized_line_count,v_source.redline_line_count,
    -abs(v_source.total_value),btrim(p_reason),auth.uid(),'credit',v_sequence,btrim(p_reason),v_source.id);

  insert into public.billing_export_lines(company_id,billing_batch_id,job_id,daily_report_id,
    production_location_id,report_date,foreman_name,crew_name,work_point,price_book_item_id,
    unit_code,unit_name,unit_description,work_type,quantity,unit_price,extended_value,
    authorization_status,active)
  select l.company_id,v_id,l.job_id,l.daily_report_id,l.production_location_id,l.report_date,
    l.foreman_name,l.crew_name,l.work_point,l.price_book_item_id,l.unit_code,l.unit_name,
    l.unit_description,l.work_type,l.quantity,-abs(l.unit_price),-abs(l.extended_value),
    l.authorization_status,false
  from public.billing_export_lines l
  where l.billing_batch_id=v_source.id and l.company_id=v_company;

  -- Release the original production actions from the active uniqueness lock.
  -- The immutable source and adjustment rows remain available for audit/export.
  update public.billing_export_lines
  set active=false
  where billing_batch_id=v_source.id and company_id=v_company;

  return v_id;
end;
$$;

create or replace function public.set_billing_export_batch_status_v2(
  p_batch_id uuid,p_status text,p_reason text default null
)
returns void language plpgsql security definer set search_path='' as $$
declare
  v_company uuid; v_role text; v_active boolean; v_current text; v_next text;
  v_billing_type text; v_parent_batch_id uuid;
begin
  select p.company_id,lower(coalesce(p.role,'')),p.active into v_company,v_role,v_active
  from public.profiles p where p.id=auth.uid();
  if v_company is null or not v_active or v_role not in ('owner','admin','superintendent') then
    raise exception using errcode='42501',message='Billing access is required.';
  end if;
  if v_role='superintendent' and (not public.linecrew_has_capability('reporting') or
    not public.linecrew_has_capability('actual_pricing')) then
    raise exception using errcode='42501',message='Reporting and Actual Pricing permissions are required.';
  end if;

  v_next:=lower(btrim(coalesce(p_status,'')));
  select status,billing_type,parent_batch_id
    into v_current,v_billing_type,v_parent_batch_id
  from public.billing_export_batches
  where id=p_batch_id and company_id=v_company for update;
  if v_current is null then raise exception using errcode='P0002',message='Billing batch was not found.'; end if;
  if v_current in ('paid','void') then raise exception using errcode='23514',message='Paid and void batches are locked.'; end if;
  if v_next not in ('exported','submitted','paid','void') then raise exception using errcode='22023',message='Invalid status.'; end if;
  if v_next='void' and v_current='submitted' and nullif(btrim(coalesce(p_reason,'')),'') is null then
    raise exception using errcode='23514',message='A correction reason is required to void a submitted batch.';
  end if;

  if v_next='void' and v_billing_type='credit' then
    if v_role not in ('owner','admin') then
      raise exception using errcode='42501',message='Only Admin or Owner can void a billing adjustment.';
    end if;
    if v_parent_batch_id is null then
      raise exception using errcode='23514',message='This billing adjustment has no source batch.';
    end if;
    if exists(
      select 1
      from public.billing_export_lines source_line
      join public.billing_export_lines rebill
        on rebill.company_id=source_line.company_id
       and rebill.production_location_id=source_line.production_location_id
       and rebill.work_type=source_line.work_type
       and rebill.active
      where source_line.company_id=v_company
        and source_line.billing_batch_id=v_parent_batch_id
        and rebill.billing_batch_id<>v_parent_batch_id
    ) then
      raise exception using errcode='23514',message=
        'These units were rebilled after the adjustment. Void the newer billing batch before voiding this adjustment.';
    end if;

    update public.billing_export_lines
    set active=true
    where company_id=v_company and billing_batch_id=v_parent_batch_id;
  end if;

  if v_next='void' then
    update public.billing_export_lines set active=false
    where billing_batch_id=p_batch_id and company_id=v_company;
  end if;

  update public.billing_export_batches set status=v_next,
    correction_reason=case when v_next='void' then nullif(btrim(coalesce(p_reason,'')),'') else correction_reason end,
    exported_at=case when v_next='exported' then coalesce(exported_at,now()) else exported_at end,
    submitted_at=case when v_next='submitted' then coalesce(submitted_at,now()) else submitted_at end,
    paid_at=case when v_next='paid' then coalesce(paid_at,now()) else paid_at end,
    voided_at=case when v_next='void' then coalesce(voided_at,now()) else voided_at end,
    updated_at=now(),updated_by=auth.uid()
  where id=p_batch_id and company_id=v_company;
end;
$$;

revoke all on function public.create_billing_credit_batch(uuid,text) from public,anon;
revoke all on function public.set_billing_export_batch_status_v2(uuid,text,text) from public,anon;
grant execute on function public.create_billing_credit_batch(uuid,text) to authenticated,service_role;
grant execute on function public.set_billing_export_batch_status_v2(uuid,text,text) to authenticated,service_role;
