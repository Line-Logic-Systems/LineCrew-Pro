begin;

insert into storage.buckets (id,name,public,file_size_limit,allowed_mime_types)
values ('job-packet-documents','job-packet-documents',false,104857600,array['application/pdf'])
on conflict (id) do update set
  public=false,
  file_size_limit=excluded.file_size_limit,
  allowed_mime_types=excluded.allowed_mime_types;

create table if not exists public.job_package_documents (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  job_id uuid not null references public.jobs(id) on delete cascade,
  job_package_id uuid not null references public.job_packages(id) on delete cascade,
  storage_path text not null,
  original_filename text not null,
  mime_type text not null default 'application/pdf',
  file_size_bytes bigint not null check (file_size_bytes >= 0),
  page_count integer check (page_count is null or page_count > 0),
  source_sha256 text,
  uploaded_by uuid references auth.users(id),
  created_at timestamptz not null default now(),
  unique (job_package_id, storage_path)
);

create index if not exists job_package_documents_company_job_idx on public.job_package_documents(company_id,job_id);
create index if not exists job_package_documents_package_idx on public.job_package_documents(job_package_id,created_at desc);

alter table public.job_package_documents enable row level security;
revoke all on public.job_package_documents from anon, authenticated;

create or replace function public.register_job_package_document(
  p_job_package_id uuid,
  p_storage_path text,
  p_original_filename text,
  p_mime_type text,
  p_file_size_bytes bigint,
  p_page_count integer default null,
  p_source_sha256 text default null
) returns uuid
language plpgsql
security definer
set search_path = public, storage, auth
as $$
declare
  v_uid uuid := auth.uid();
  v_company uuid;
  v_job uuid;
  v_id uuid;
begin
  if v_uid is null then raise exception 'Authentication required' using errcode='42501'; end if;
  if not public.current_user_has_active_profile() then raise exception 'Active company profile required' using errcode='42501'; end if;
  if not public.linecrew_can_manage_job_packages() then raise exception 'Job package management permission required' using errcode='42501'; end if;
  select jp.company_id,jp.job_id into v_company,v_job from public.job_packages jp where jp.id=p_job_package_id and jp.company_id=public.my_company_id();
  if v_company is null then raise exception 'Job package not found' using errcode='P0002'; end if;
  if p_mime_type <> 'application/pdf' then raise exception 'Only PDF job packets are supported'; end if;
  if p_file_size_bytes < 0 or p_file_size_bytes > 104857600 then raise exception 'Job packet PDF exceeds 100 MB'; end if;
  if p_storage_path is null or split_part(p_storage_path,'/',1) <> v_company::text or split_part(p_storage_path,'/',2) <> v_job::text or split_part(p_storage_path,'/',3) <> p_job_package_id::text then raise exception 'Invalid job packet storage path' using errcode='42501'; end if;
  insert into public.job_package_documents(company_id,job_id,job_package_id,storage_path,original_filename,mime_type,file_size_bytes,page_count,source_sha256,uploaded_by)
  values(v_company,v_job,p_job_package_id,p_storage_path,left(coalesce(p_original_filename,'Job Packet.pdf'),255),p_mime_type,p_file_size_bytes,p_page_count,p_source_sha256,v_uid)
  on conflict (job_package_id,storage_path) do update set original_filename=excluded.original_filename,mime_type=excluded.mime_type,file_size_bytes=excluded.file_size_bytes,page_count=excluded.page_count,source_sha256=excluded.source_sha256,uploaded_by=excluded.uploaded_by,created_at=now()
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.get_job_package_documents(p_job_package_id uuid default null,p_job_id uuid default null)
returns table(id uuid,job_id uuid,job_package_id uuid,storage_path text,original_filename text,mime_type text,file_size_bytes bigint,page_count integer,created_at timestamptz)
language plpgsql
security definer
set search_path = public, auth
as $$
begin
  if auth.uid() is null or not public.current_user_has_active_profile() then raise exception 'Authentication required' using errcode='42501'; end if;
  return query
  select d.id,d.job_id,d.job_package_id,d.storage_path,d.original_filename,d.mime_type,d.file_size_bytes,d.page_count,d.created_at
  from public.job_package_documents d
  where d.company_id=public.my_company_id() and (p_job_package_id is null or d.job_package_id=p_job_package_id) and (p_job_id is null or d.job_id=p_job_id)
  order by d.created_at desc;
end $$;

create or replace function public.get_job_map_page(p_job_id uuid,p_work_point_code text default null)
returns table(job_package_id uuid,storage_path text,original_filename text,page_number integer,page_count integer)
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_company uuid;
  v_key text;
begin
  if auth.uid() is null or not public.current_user_has_active_profile() then raise exception 'Authentication required' using errcode='42501'; end if;
  v_company:=public.my_company_id();
  if not exists(select 1 from public.jobs j where j.id=p_job_id and j.company_id=v_company) then raise exception 'Job not found' using errcode='P0002'; end if;
  v_key:=public.normalize_work_point_key(coalesce(p_work_point_code,''));
  return query
  with candidates as (
    select d.job_package_id,d.storage_path,d.original_filename,d.page_count,d.created_at,
      case when v_key<>'' then (
        select min(r.source_page)
        from public.utility_packet_imports i
        join public.utility_packet_import_rows r on r.import_id=i.id and r.company_id=v_company
        where i.job_package_id=d.job_package_id and i.company_id=v_company and public.normalize_work_point_key(coalesce(r.work_point_code,''))=v_key and coalesce(r.include_in_import,true)
      ) end as matched_page
    from public.job_package_documents d
    join public.job_packages jp on jp.id=d.job_package_id
    where d.company_id=v_company and d.job_id=p_job_id
    order by jp.revision_number desc,d.created_at desc
  )
  select c.job_package_id,c.storage_path,c.original_filename,c.matched_page,c.page_count
  from candidates c
  order by (c.matched_page is not null) desc,c.created_at desc
  limit 1;
end $$;

revoke all on function public.register_job_package_document(uuid,text,text,text,bigint,integer,text) from public,anon;
grant execute on function public.register_job_package_document(uuid,text,text,text,bigint,integer,text) to authenticated;
revoke all on function public.get_job_package_documents(uuid,uuid) from public,anon;
grant execute on function public.get_job_package_documents(uuid,uuid) to authenticated;
revoke all on function public.get_job_map_page(uuid,text) from public,anon;
grant execute on function public.get_job_map_page(uuid,text) to authenticated;

drop policy if exists job_packet_documents_company_read on storage.objects;
create policy job_packet_documents_company_read on storage.objects for select to authenticated using (bucket_id='job-packet-documents' and public.current_user_has_active_profile() and (storage.foldername(name))[1]=(public.my_company_id())::text);

drop policy if exists job_packet_documents_manager_insert on storage.objects;
create policy job_packet_documents_manager_insert on storage.objects for insert to authenticated with check (bucket_id='job-packet-documents' and public.current_user_has_active_profile() and public.linecrew_can_manage_job_packages() and (storage.foldername(name))[1]=(public.my_company_id())::text and exists(select 1 from public.job_packages jp where jp.id::text=(storage.foldername(name))[3] and jp.job_id::text=(storage.foldername(name))[2] and jp.company_id=public.my_company_id()));

drop policy if exists job_packet_documents_manager_update on storage.objects;
create policy job_packet_documents_manager_update on storage.objects for update to authenticated using (bucket_id='job-packet-documents' and public.current_user_has_active_profile() and public.linecrew_can_manage_job_packages() and (storage.foldername(name))[1]=(public.my_company_id())::text) with check (bucket_id='job-packet-documents' and public.current_user_has_active_profile() and public.linecrew_can_manage_job_packages() and (storage.foldername(name))[1]=(public.my_company_id())::text);

commit;
