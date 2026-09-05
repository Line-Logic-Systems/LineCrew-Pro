alter table public.billing_export_batches
  add column if not exists archived_at timestamptz,
  add column if not exists archived_by uuid references public.profiles(id);

create index if not exists billing_export_batches_company_archive_idx
  on public.billing_export_batches(company_id,archived_at,created_at desc);

create or replace function public.set_void_billing_batch_archived(
  p_batch_id uuid,
  p_archived boolean
)
returns void language plpgsql security definer set search_path='' as $$
declare v_company uuid; v_role text; v_active boolean;
begin
  select p.company_id,lower(coalesce(p.role,'')),p.active
    into v_company,v_role,v_active
  from public.profiles p where p.id=auth.uid();
  if v_company is null or not v_active or v_role not in ('owner','admin') then
    raise exception using errcode='42501',message='Only Admin or Owner can archive voided billing batches.';
  end if;

  update public.billing_export_batches b
  set archived_at=case when coalesce(p_archived,false) then coalesce(b.archived_at,now()) else null end,
      archived_by=case when coalesce(p_archived,false) then coalesce(b.archived_by,auth.uid()) else null end,
      updated_at=now(),updated_by=auth.uid()
  where b.id=p_batch_id and b.company_id=v_company and b.status='void';

  if not found then
    raise exception using errcode='P0002',message='Voided billing batch was not found in your company.';
  end if;
end;
$$;

create or replace function public.get_billing_export_batches_v4(p_archive_filter text default 'active')
returns table(
  batch_id uuid,batch_number text,job_id uuid,job_number text,job_name text,
  date_from date,date_to date,include_redlines boolean,status text,billing_type text,
  billing_sequence integer,authorized_line_count integer,redline_line_count integer,
  total_value numeric,notes text,utility_invoice_number text,payment_reference text,
  correction_reason text,final_override_reason text,parent_batch_id uuid,parent_batch_number text,
  attachment_count bigint,created_by_name text,created_at timestamptz,exported_at timestamptz,
  submitted_at timestamptz,paid_at timestamptz,voided_at timestamptz,
  archived_at timestamptz,archived_by_name text
)
language plpgsql stable security definer set search_path='' as $$
declare v_company uuid; v_role text; v_active boolean; v_filter text;
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

  v_filter:=lower(btrim(coalesce(p_archive_filter,'active')));
  if v_filter not in ('active','archived','all') then
    raise exception using errcode='22023',message='Invalid billing archive filter.';
  end if;
  if v_role not in ('owner','admin') and v_filter<>'active' then
    raise exception using errcode='42501',message='Only Admin or Owner can view archived billing batches.';
  end if;

  return query
  select b.id,b.batch_number,b.job_id,j.job_number,j.job_name,b.date_from,b.date_to,
    b.include_redlines,b.status,b.billing_type,b.billing_sequence,b.authorized_line_count,
    b.redline_line_count,b.total_value,b.notes,b.utility_invoice_number,b.payment_reference,
    b.correction_reason,b.final_override_reason,b.parent_batch_id,parent.batch_number,
    (select count(*) from public.billing_export_attachments a where a.billing_batch_id=b.id),
    creator.full_name,b.created_at,b.exported_at,b.submitted_at,b.paid_at,b.voided_at,
    b.archived_at,archiver.full_name
  from public.billing_export_batches b
  join public.jobs j on j.id=b.job_id and j.company_id=b.company_id
  left join public.billing_export_batches parent on parent.id=b.parent_batch_id
  left join public.profiles creator on creator.id=b.created_by
  left join public.profiles archiver on archiver.id=b.archived_by
  where b.company_id=v_company
    and (
      (v_filter='active' and b.archived_at is null)
      or (v_filter='archived' and b.archived_at is not null)
      or v_filter='all'
    )
  order by b.created_at desc;
end;
$$;

revoke all on function public.set_void_billing_batch_archived(uuid,boolean) from public,anon;
revoke all on function public.get_billing_export_batches_v4(text) from public,anon;
grant execute on function public.set_void_billing_batch_archived(uuid,boolean) to authenticated,service_role;
grant execute on function public.get_billing_export_batches_v4(text) to authenticated,service_role;

-- Permanent deletion is retired. Voided batches remain preserved for audit.
revoke all on function public.delete_void_billing_export_batch(uuid)
  from public,anon,authenticated,service_role;
