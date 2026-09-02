begin;

alter table public.jobs
  add column if not exists closeout_status text not null default 'open',
  add column if not exists closeout_notes text,
  add column if not exists closed_by uuid references public.profiles(id),
  add column if not exists reopened_at timestamptz,
  add column if not exists reopened_by uuid references public.profiles(id);

alter table public.billing_export_batches
  add column if not exists utility_invoice_number text,
  add column if not exists payment_reference text,
  add column if not exists correction_reason text,
  add column if not exists final_override_reason text,
  add column if not exists parent_batch_id uuid references public.billing_export_batches(id) on delete restrict,
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists updated_by uuid references public.profiles(id);

alter table public.billing_export_batches
  drop constraint if exists billing_export_batches_type_check;
alter table public.billing_export_batches
  add constraint billing_export_batches_type_check
  check (billing_type in ('partial','final','credit'));

alter table public.job_packages
  add column if not exists revision_number integer,
  add column if not exists supersedes_package_id uuid references public.job_packages(id) on delete set null;

with numbered as (
  select id,
    row_number() over(partition by company_id,job_id order by created_at,id)::integer as revision_number,
    lag(id) over(partition by company_id,job_id order by created_at,id) as prior_id
  from public.job_packages
)
update public.job_packages package
set revision_number=coalesce(package.revision_number,numbered.revision_number),
    supersedes_package_id=coalesce(package.supersedes_package_id,numbered.prior_id)
from numbered where numbered.id=package.id;

alter table public.job_packages
  alter column revision_number set default 1,
  alter column revision_number set not null;

create or replace function public.assign_job_package_revision()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_prior public.job_packages%rowtype;
begin
  select * into v_prior from public.job_packages package
  where package.company_id=new.company_id and package.job_id=new.job_id
  order by package.revision_number desc,package.created_at desc limit 1 for update;
  if v_prior.id is null then
    new.revision_number:=1;
    new.supersedes_package_id:=null;
  else
    new.revision_number:=v_prior.revision_number+1;
    new.supersedes_package_id:=v_prior.id;
  end if;
  return new;
end;
$$;
drop trigger if exists assign_job_package_revision_trigger on public.job_packages;
create trigger assign_job_package_revision_trigger before insert on public.job_packages
for each row execute function public.assign_job_package_revision();

create or replace function public.supersede_prior_job_package()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.status='active' and (old.status is distinct from new.status) then
    update public.job_packages package set status='closed',updated_at=now()
    where package.company_id=new.company_id and package.job_id=new.job_id
      and package.id<>new.id and package.status='active'
      and package.revision_number<new.revision_number;
  end if;
  return new;
end;
$$;
drop trigger if exists supersede_prior_job_package_trigger on public.job_packages;
create trigger supersede_prior_job_package_trigger after update of status on public.job_packages
for each row execute function public.supersede_prior_job_package();

create table if not exists public.billing_export_attachments(
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  billing_batch_id uuid not null references public.billing_export_batches(id) on delete cascade,
  storage_path text not null unique,
  original_filename text not null,
  mime_type text,
  file_size_bytes bigint not null default 0,
  caption text,
  uploaded_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now()
);
alter table public.billing_export_attachments enable row level security;
revoke all on public.billing_export_attachments from public,anon,authenticated;
create index if not exists billing_export_attachments_batch_idx
  on public.billing_export_attachments(company_id,billing_batch_id,created_at);

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('billing-export-attachments','billing-export-attachments',false,15728640,
  array['application/pdf','image/jpeg','image/png','image/webp',
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet','text/csv'])
on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,
  allowed_mime_types=excluded.allowed_mime_types;

drop policy if exists "billing attachment company read" on storage.objects;
create policy "billing attachment company read" on storage.objects for select to authenticated
using(bucket_id='billing-export-attachments' and exists(
  select 1 from public.profiles profile where profile.id=(select auth.uid())
    and profile.active=true and profile.company_id::text=(storage.foldername(name))[1]
    and lower(coalesce(profile.role,'')) in ('owner','admin','superintendent')
));
drop policy if exists "billing attachment company upload" on storage.objects;
create policy "billing attachment company upload" on storage.objects for insert to authenticated
with check(bucket_id='billing-export-attachments' and exists(
  select 1 from public.profiles profile where profile.id=(select auth.uid())
    and profile.active=true and profile.company_id::text=(storage.foldername(name))[1]
    and lower(coalesce(profile.role,'')) in ('owner','admin','superintendent')
));
drop policy if exists "billing attachment company delete" on storage.objects;
create policy "billing attachment company delete" on storage.objects for delete to authenticated
using(bucket_id='billing-export-attachments' and exists(
  select 1 from public.profiles profile where profile.id=(select auth.uid())
    and profile.active=true and profile.company_id::text=(storage.foldername(name))[1]
    and lower(coalesce(profile.role,'')) in ('owner','admin','superintendent')
));

create or replace function public.get_job_billing_reconciliation(p_job_id uuid)
returns table(
  job_id uuid,authorized_value numeric,approved_value numeric,remaining_authorized_value numeric,
  billed_value numeric,credit_value numeric,net_billed_value numeric,approved_unbilled_value numeric,
  awaiting_review_count bigint,draft_report_count bigint,pending_packet_count bigint,
  redline_count bigint,active_batch_count bigint,final_bill_count bigint
)
language plpgsql stable security definer set search_path='' as $$
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
  if not exists(select 1 from public.jobs j where j.id=p_job_id and j.company_id=v_company) then
    raise exception using errcode='P0002',message='Job was not found in your company.';
  end if;
  return query
  with progress as (
    select * from public.get_job_progress_dashboard() p where p.job_id=p_job_id
  ), batches as (
    select
      coalesce(sum(case when b.status<>'void' and b.billing_type<>'credit' then b.total_value else 0 end),0) billed,
      coalesce(sum(case when b.status<>'void' and b.billing_type='credit' then b.total_value else 0 end),0) credits,
      count(*) filter(where b.status<>'void') active_batches,
      count(*) filter(where b.status<>'void' and b.billing_type='final') finals
    from public.billing_export_batches b where b.company_id=v_company and b.job_id=p_job_id
  ), reports as (
    select count(*) filter(where lower(coalesce(r.status,''))='submitted') awaiting,
      count(*) filter(where lower(coalesce(r.status,'')) in ('draft','returned')) drafts
    from public.daily_reports r where r.company_id=v_company and r.job_id=p_job_id and not r.archived
  )
  select p_job_id,coalesce(p.authorized_value,0),coalesce(p.approved_value,0),
    greatest(coalesce(p.remaining_value,0),0),b.billed,abs(b.credits),b.billed+b.credits,
    greatest(coalesce(p.approved_value,0)-b.billed,0),r.awaiting,r.drafts,
    coalesce(p.pending_packet_count,0),coalesce(p.redline_count,0),b.active_batches,b.finals
  from progress p cross join batches b cross join reports r;
end;
$$;

create or replace function public.create_billing_export_batch_v3(
  p_job_id uuid,p_date_from date default null,p_date_to date default null,
  p_separate_redline_summary boolean default false,p_notes text default null,
  p_is_final boolean default false,p_final_override_reason text default null
)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_rec record; v_id uuid;
begin
  if coalesce(p_is_final,false) then
    select * into v_rec from public.get_job_billing_reconciliation(p_job_id);
    if (v_rec.remaining_authorized_value>0.01 or v_rec.awaiting_review_count>0 or
        v_rec.draft_report_count>0 or v_rec.pending_packet_count>0) and
       nullif(btrim(coalesce(p_final_override_reason,'')),'') is null then
      raise exception using errcode='23514',message=
        'Final Bill has unresolved work or reports. Enter an override reason to continue.';
    end if;
  end if;
  v_id:=public.create_billing_export_batch_v2(p_job_id,p_date_from,p_date_to,
    p_separate_redline_summary,p_notes,p_is_final);
  if p_is_final then
    update public.billing_export_batches set
      final_override_reason=nullif(btrim(coalesce(p_final_override_reason,'')),''),
      updated_at=now(),updated_by=auth.uid() where id=v_id;
  end if;
  return v_id;
end;
$$;

create or replace function public.get_billing_export_batches_v3()
returns table(
  batch_id uuid,batch_number text,job_id uuid,job_number text,job_name text,
  date_from date,date_to date,include_redlines boolean,status text,billing_type text,
  billing_sequence integer,authorized_line_count integer,redline_line_count integer,
  total_value numeric,notes text,utility_invoice_number text,payment_reference text,
  correction_reason text,final_override_reason text,parent_batch_id uuid,parent_batch_number text,
  attachment_count bigint,created_by_name text,created_at timestamptz,exported_at timestamptz,
  submitted_at timestamptz,paid_at timestamptz,voided_at timestamptz
)
language plpgsql stable security definer set search_path='' as $$
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
  return query select b.id,b.batch_number,b.job_id,j.job_number,j.job_name,b.date_from,b.date_to,
    b.include_redlines,b.status,b.billing_type,b.billing_sequence,b.authorized_line_count,
    b.redline_line_count,b.total_value,b.notes,b.utility_invoice_number,b.payment_reference,
    b.correction_reason,b.final_override_reason,b.parent_batch_id,parent.batch_number,
    (select count(*) from public.billing_export_attachments a where a.billing_batch_id=b.id),
    creator.full_name,b.created_at,b.exported_at,b.submitted_at,b.paid_at,b.voided_at
  from public.billing_export_batches b join public.jobs j on j.id=b.job_id and j.company_id=b.company_id
  left join public.billing_export_batches parent on parent.id=b.parent_batch_id
  left join public.profiles creator on creator.id=b.created_by
  where b.company_id=v_company order by b.created_at desc;
end;
$$;

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

create or replace function public.create_billing_credit_batch(p_paid_batch_id uuid,p_reason text)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_company uuid; v_role text; v_active boolean; v_source public.billing_export_batches%rowtype;
  v_id uuid:=gen_random_uuid(); v_number text; v_sequence integer;
begin
  select p.company_id,lower(coalesce(p.role,'')),p.active into v_company,v_role,v_active
  from public.profiles p where p.id=auth.uid();
  if v_company is null or not v_active or v_role not in ('owner','admin') then
    raise exception using errcode='42501',message='Only Admin or Owner can create a credit batch.';
  end if;
  if nullif(btrim(coalesce(p_reason,'')),'') is null then
    raise exception using errcode='22023',message='A credit reason is required.';
  end if;
  select * into v_source from public.billing_export_batches b
    where b.id=p_paid_batch_id and b.company_id=v_company and b.status='paid' for update;
  if v_source.id is null then raise exception using errcode='23514',message='Choose a paid billing batch.'; end if;
  if exists(select 1 from public.billing_export_batches b where b.parent_batch_id=v_source.id and b.billing_type='credit' and b.status<>'void') then
    raise exception using errcode='23505',message='An active credit already exists for this paid batch.';
  end if;
  select coalesce(max(b.billing_sequence),0)+1 into v_sequence from public.billing_export_batches b
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
    l.authorization_status,false from public.billing_export_lines l
  where l.billing_batch_id=v_source.id and l.company_id=v_company;
  return v_id;
end;
$$;

create or replace function public.register_billing_export_attachment(
  p_batch_id uuid,p_storage_path text,p_original_filename text,p_mime_type text,
  p_file_size_bytes bigint,p_caption text default null
)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_company uuid; v_role text; v_active boolean; v_id uuid;
begin
  select p.company_id,lower(coalesce(p.role,'')),p.active into v_company,v_role,v_active
  from public.profiles p where p.id=auth.uid();
  if v_company is null or not v_active or v_role not in ('owner','admin','superintendent') then
    raise exception using errcode='42501',message='Billing access is required.';
  end if;
  if not exists(select 1 from public.billing_export_batches b where b.id=p_batch_id and b.company_id=v_company) then
    raise exception using errcode='P0002',message='Billing batch was not found.';
  end if;
  if split_part(p_storage_path,'/',1)<>v_company::text or split_part(p_storage_path,'/',2)<>p_batch_id::text then
    raise exception using errcode='22023',message='Invalid attachment path.';
  end if;
  insert into public.billing_export_attachments(company_id,billing_batch_id,storage_path,
    original_filename,mime_type,file_size_bytes,caption,uploaded_by)
  values(v_company,p_batch_id,p_storage_path,btrim(p_original_filename),p_mime_type,
    greatest(coalesce(p_file_size_bytes,0),0),nullif(btrim(coalesce(p_caption,'')),''),auth.uid())
  returning id into v_id; return v_id;
end;
$$;

create or replace function public.get_billing_export_attachments(p_batch_id uuid)
returns table(id uuid,storage_path text,original_filename text,mime_type text,file_size_bytes bigint,
  caption text,uploaded_by uuid,created_at timestamptz)
language plpgsql stable security definer set search_path='' as $$
declare v_company uuid;
begin
  select p.company_id into v_company from public.profiles p where p.id=auth.uid() and p.active;
  if v_company is null or not exists(select 1 from public.billing_export_batches b where b.id=p_batch_id and b.company_id=v_company) then
    raise exception using errcode='42501',message='Billing batch access is required.';
  end if;
  return query select a.id,a.storage_path,a.original_filename,a.mime_type,a.file_size_bytes,
    a.caption,a.uploaded_by,a.created_at from public.billing_export_attachments a
    where a.company_id=v_company and a.billing_batch_id=p_batch_id order by a.created_at;
end;
$$;

create or replace function public.delete_billing_export_attachment(p_attachment_id uuid)
returns text language plpgsql security definer set search_path='' as $$
declare v_company uuid; v_role text; v_path text;
begin
  select p.company_id,lower(coalesce(p.role,'')) into v_company,v_role from public.profiles p
    where p.id=auth.uid() and p.active;
  if v_company is null or v_role not in ('owner','admin','superintendent') then
    raise exception using errcode='42501',message='Billing access is required.';
  end if;
  delete from public.billing_export_attachments a where a.id=p_attachment_id and a.company_id=v_company
    returning a.storage_path into v_path;
  if v_path is null then raise exception using errcode='P0002',message='Attachment was not found.'; end if;
  return v_path;
end;
$$;

create or replace function public.get_job_packages_v2(p_job_id uuid default null)
returns table(id uuid,job_id uuid,contract_id uuid,package_name text,package_number text,
  received_date date,source_filename text,notes text,status text,revision_number integer,
  supersedes_package_id uuid,created_at timestamptz,updated_at timestamptz)
language plpgsql stable security definer set search_path='' as $$
declare v_company uuid;
begin
  select p.company_id into v_company from public.profiles p where p.id=auth.uid() and p.active;
  if v_company is null then raise exception using errcode='42501',message='Company access is required.'; end if;
  return query select package.id,package.job_id,package.contract_id,package.package_name,
    package.package_number,package.received_date,package.source_filename,package.notes,package.status,
    package.revision_number,package.supersedes_package_id,package.created_at,package.updated_at
  from public.job_packages package where package.company_id=v_company
    and (p_job_id is null or package.job_id=p_job_id)
  order by package.job_id,package.revision_number desc;
end;
$$;

create or replace function public.get_job_package_revision_delta(p_package_id uuid)
returns table(work_point text,unit_code text,prior_install numeric,new_install numeric,install_change numeric,
  prior_remove numeric,new_remove numeric,remove_change numeric)
language plpgsql stable security definer set search_path='' as $$
declare v_company uuid; v_prior uuid;
begin
  select p.company_id into v_company from public.profiles p where p.id=auth.uid() and p.active;
  select package.supersedes_package_id into v_prior from public.job_packages package
    where package.id=p_package_id and package.company_id=v_company;
  return query with old_units as (
    select wp.work_point_code wp,u.unit_code,sum(u.authorized_install_quantity) install,
      sum(u.authorized_retirement_quantity) remove_qty
    from public.job_package_authorized_units u join public.job_package_work_points wp on wp.id=u.work_point_id
    where u.job_package_id=v_prior group by wp.work_point_code,u.unit_code
  ), new_units as (
    select wp.work_point_code wp,u.unit_code,sum(u.authorized_install_quantity) install,
      sum(u.authorized_retirement_quantity) remove_qty
    from public.job_package_authorized_units u join public.job_package_work_points wp on wp.id=u.work_point_id
    where u.job_package_id=p_package_id group by wp.work_point_code,u.unit_code
  ) select coalesce(n.wp,o.wp),coalesce(n.unit_code,o.unit_code),coalesce(o.install,0),
    coalesce(n.install,0),coalesce(n.install,0)-coalesce(o.install,0),coalesce(o.remove_qty,0),
    coalesce(n.remove_qty,0),coalesce(n.remove_qty,0)-coalesce(o.remove_qty,0)
  from old_units o full join new_units n on n.wp=o.wp and n.unit_code=o.unit_code
  where coalesce(n.install,0)<>coalesce(o.install,0) or coalesce(n.remove_qty,0)<>coalesce(o.remove_qty,0)
  order by coalesce(n.wp,o.wp),coalesce(n.unit_code,o.unit_code);
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

revoke all on function public.get_job_billing_reconciliation(uuid) from public,anon;
revoke all on function public.create_billing_export_batch_v3(uuid,date,date,boolean,text,boolean,text) from public,anon;
revoke all on function public.get_billing_export_batches_v3() from public,anon;
revoke all on function public.save_billing_export_batch_details(uuid,text,text,text) from public,anon;
revoke all on function public.set_billing_export_batch_status_v2(uuid,text,text) from public,anon;
revoke all on function public.create_billing_credit_batch(uuid,text) from public,anon;
revoke all on function public.register_billing_export_attachment(uuid,text,text,text,bigint,text) from public,anon;
revoke all on function public.get_billing_export_attachments(uuid) from public,anon;
revoke all on function public.delete_billing_export_attachment(uuid) from public,anon;
revoke all on function public.get_job_packages_v2(uuid) from public,anon;
revoke all on function public.get_job_package_revision_delta(uuid) from public,anon;
revoke all on function public.set_job_closeout(uuid,boolean,text) from public,anon;
grant execute on function public.get_job_billing_reconciliation(uuid) to authenticated;
grant execute on function public.create_billing_export_batch_v3(uuid,date,date,boolean,text,boolean,text) to authenticated;
grant execute on function public.get_billing_export_batches_v3() to authenticated;
grant execute on function public.save_billing_export_batch_details(uuid,text,text,text) to authenticated;
grant execute on function public.set_billing_export_batch_status_v2(uuid,text,text) to authenticated;
grant execute on function public.create_billing_credit_batch(uuid,text) to authenticated;
grant execute on function public.register_billing_export_attachment(uuid,text,text,text,bigint,text) to authenticated;
grant execute on function public.get_billing_export_attachments(uuid) to authenticated;
grant execute on function public.delete_billing_export_attachment(uuid) to authenticated;
grant execute on function public.get_job_packages_v2(uuid) to authenticated;
grant execute on function public.get_job_package_revision_delta(uuid) to authenticated;
grant execute on function public.set_job_closeout(uuid,boolean,text) to authenticated;

commit;
