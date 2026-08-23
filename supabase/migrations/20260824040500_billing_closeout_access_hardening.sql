begin;

create or replace function public.linecrew_can_use_billing_exports_internal()
returns boolean language sql stable security definer set search_path='' as $$
  select exists(
    select 1 from public.profiles p where p.id=auth.uid() and p.active=true and (
      lower(coalesce(p.role,'')) in ('owner','admin') or
      (lower(coalesce(p.role,''))='superintendent' and
       public.linecrew_has_capability('reporting') and
       public.linecrew_has_capability('actual_pricing'))
    )
  );
$$;
revoke all on function public.linecrew_can_use_billing_exports_internal() from public,anon;
grant execute on function public.linecrew_can_use_billing_exports_internal() to authenticated;

drop policy if exists "billing attachment company read" on storage.objects;
create policy "billing attachment company read" on storage.objects for select to authenticated
using(bucket_id='billing-export-attachments' and public.linecrew_can_use_billing_exports_internal()
  and exists(select 1 from public.profiles p where p.id=(select auth.uid()) and p.active
    and p.company_id::text=(storage.foldername(name))[1]));
drop policy if exists "billing attachment company upload" on storage.objects;
create policy "billing attachment company upload" on storage.objects for insert to authenticated
with check(bucket_id='billing-export-attachments' and public.linecrew_can_use_billing_exports_internal()
  and exists(select 1 from public.profiles p where p.id=(select auth.uid()) and p.active
    and p.company_id::text=(storage.foldername(name))[1]));
drop policy if exists "billing attachment company delete" on storage.objects;
create policy "billing attachment company delete" on storage.objects for delete to authenticated
using(bucket_id='billing-export-attachments' and public.linecrew_can_use_billing_exports_internal()
  and exists(select 1 from public.profiles p where p.id=(select auth.uid()) and p.active
    and p.company_id::text=(storage.foldername(name))[1]));

create or replace function public.get_billing_export_attachments(p_batch_id uuid)
returns table(id uuid,storage_path text,original_filename text,mime_type text,file_size_bytes bigint,
  caption text,uploaded_by uuid,created_at timestamptz)
language plpgsql stable security definer set search_path='' as $$
declare v_company uuid;
begin
  if not public.linecrew_can_use_billing_exports_internal() then
    raise exception using errcode='42501',message='Billing attachment access is required.';
  end if;
  select p.company_id into v_company from public.profiles p where p.id=auth.uid() and p.active;
  if not exists(select 1 from public.billing_export_batches b where b.id=p_batch_id and b.company_id=v_company) then
    raise exception using errcode='P0002',message='Billing batch was not found.';
  end if;
  return query select a.id,a.storage_path,a.original_filename,a.mime_type,a.file_size_bytes,
    a.caption,a.uploaded_by,a.created_at from public.billing_export_attachments a
  where a.company_id=v_company and a.billing_batch_id=p_batch_id order by a.created_at;
end;
$$;

create or replace function public.register_billing_export_attachment(
  p_batch_id uuid,p_storage_path text,p_original_filename text,p_mime_type text,
  p_file_size_bytes bigint,p_caption text default null
)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_company uuid; v_id uuid;
begin
  if not public.linecrew_can_use_billing_exports_internal() then
    raise exception using errcode='42501',message='Billing attachment access is required.';
  end if;
  select p.company_id into v_company from public.profiles p where p.id=auth.uid() and p.active;
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

create or replace function public.delete_billing_export_attachment(p_attachment_id uuid)
returns text language plpgsql security definer set search_path='' as $$
declare v_company uuid; v_path text;
begin
  if not public.linecrew_can_use_billing_exports_internal() then
    raise exception using errcode='42501',message='Billing attachment access is required.';
  end if;
  select p.company_id into v_company from public.profiles p where p.id=auth.uid() and p.active;
  delete from public.billing_export_attachments a where a.id=p_attachment_id and a.company_id=v_company
    returning a.storage_path into v_path;
  if v_path is null then raise exception using errcode='P0002',message='Attachment was not found.'; end if;
  return v_path;
end;
$$;

revoke all on function public.get_billing_export_attachments(uuid) from public,anon;
revoke all on function public.register_billing_export_attachment(uuid,text,text,text,bigint,text) from public,anon;
revoke all on function public.delete_billing_export_attachment(uuid) from public,anon;
grant execute on function public.get_billing_export_attachments(uuid) to authenticated;
grant execute on function public.register_billing_export_attachment(uuid,text,text,text,bigint,text) to authenticated;
grant execute on function public.delete_billing_export_attachment(uuid) to authenticated;

commit;
