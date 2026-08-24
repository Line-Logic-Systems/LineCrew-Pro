-- Superintendent billing/closeout writes must honor the same permissions as
-- the matching billing reads. Owner and Admin access is unchanged.

create or replace function public.save_billing_export_batch_details(
  p_batch_id uuid,p_utility_invoice_number text default null,p_payment_reference text default null,
  p_notes text default null
)
returns void language plpgsql security definer set search_path='' as $$
declare v_company uuid; v_role text; v_active boolean;
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
  update public.billing_export_batches set
    utility_invoice_number=nullif(btrim(coalesce(p_utility_invoice_number,'')),''),
    payment_reference=nullif(btrim(coalesce(p_payment_reference,'')),''),
    notes=nullif(btrim(coalesce(p_notes,'')),''),updated_at=now(),updated_by=auth.uid()
  where id=p_batch_id and company_id=v_company;
  if not found then raise exception using errcode='P0002',message='Billing batch was not found.'; end if;
end;
$$;

create or replace function public.set_billing_export_batch_status_v2(
  p_batch_id uuid,p_status text,p_reason text default null
)
returns void language plpgsql security definer set search_path='' as $$
declare v_company uuid; v_role text; v_active boolean; v_current text; v_next text;
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
  select status into v_current from public.billing_export_batches
    where id=p_batch_id and company_id=v_company for update;
  if v_current is null then raise exception using errcode='P0002',message='Billing batch was not found.'; end if;
  if v_current in ('paid','void') then raise exception using errcode='23514',message='Paid and void batches are locked.'; end if;
  if v_next not in ('exported','submitted','paid','void') then raise exception using errcode='22023',message='Invalid status.'; end if;
  if v_next='void' and v_current='submitted' and nullif(btrim(coalesce(p_reason,'')),'') is null then
    raise exception using errcode='23514',message='A correction reason is required to void a submitted batch.';
  end if;
  if v_next='void' then update public.billing_export_lines set active=false
    where billing_batch_id=p_batch_id and company_id=v_company; end if;
  update public.billing_export_batches set status=v_next,
    correction_reason=case when v_next='void' then nullif(btrim(coalesce(p_reason,'')),'') else correction_reason end,
    exported_at=case when v_next='exported' then coalesce(exported_at,now()) else exported_at end,
    submitted_at=case when v_next='submitted' then coalesce(submitted_at,now()) else submitted_at end,
    paid_at=case when v_next='paid' then coalesce(paid_at,now()) else paid_at end,
    voided_at=case when v_next='void' then coalesce(voided_at,now()) else voided_at end,
    updated_at=now(),updated_by=auth.uid() where id=p_batch_id and company_id=v_company;
end;
$$;

create or replace function public.set_job_closeout(
  p_job_id uuid,p_close boolean,p_reason text default null
)
returns void language plpgsql security definer set search_path='' as $$
declare v_company uuid; v_role text; v_active boolean; v_rec record; v_has_paid_final boolean;
begin
  select p.company_id,lower(coalesce(p.role,'')),p.active into v_company,v_role,v_active
  from public.profiles p where p.id=auth.uid();
  if v_company is null or not v_active or v_role not in ('owner','admin','superintendent') then
    raise exception using errcode='42501',message='Job closeout access is required.';
  end if;
  if v_role='superintendent' and (not public.linecrew_has_capability('reporting') or
    not public.linecrew_has_capability('actual_pricing')) then
    raise exception using errcode='42501',message='Reporting and Actual Pricing permissions are required.';
  end if;
  if coalesce(p_close,false) then
    select * into v_rec from public.get_job_billing_reconciliation(p_job_id);
    select exists(select 1 from public.billing_export_batches b where b.company_id=v_company
      and b.job_id=p_job_id and b.billing_type='final' and b.status='paid') into v_has_paid_final;
    if (not v_has_paid_final or v_rec.approved_unbilled_value>0.01 or
        v_rec.awaiting_review_count>0 or v_rec.draft_report_count>0) and
       nullif(btrim(coalesce(p_reason,'')),'') is null then
      raise exception using errcode='23514',message=
        'Closeout requires a paid Final Bill and no unbilled or pending reports. Enter an override reason to continue.';
    end if;
    update public.jobs set active=false,closed_at=now(),closed_by=auth.uid(),
      closeout_status='closed',closeout_notes=nullif(btrim(coalesce(p_reason,'')),'')
      where id=p_job_id and company_id=v_company;
  else
    if nullif(btrim(coalesce(p_reason,'')),'') is null then
      raise exception using errcode='22023',message='Enter a reason for reopening the job.';
    end if;
    update public.jobs set active=true,closed_at=null,closeout_status='reopened',
      closeout_notes=btrim(p_reason),reopened_at=now(),reopened_by=auth.uid()
      where id=p_job_id and company_id=v_company;
  end if;
  if not found then raise exception using errcode='P0002',message='Job was not found.'; end if;
end;
$$;

revoke all on function public.save_billing_export_batch_details(uuid,text,text,text) from public,anon;
revoke all on function public.set_billing_export_batch_status_v2(uuid,text,text) from public,anon;
revoke all on function public.set_job_closeout(uuid,boolean,text) from public,anon;

grant execute on function public.save_billing_export_batch_details(uuid,text,text,text) to authenticated,service_role;
grant execute on function public.set_billing_export_batch_status_v2(uuid,text,text) to authenticated,service_role;
grant execute on function public.set_job_closeout(uuid,boolean,text) to authenticated,service_role;
