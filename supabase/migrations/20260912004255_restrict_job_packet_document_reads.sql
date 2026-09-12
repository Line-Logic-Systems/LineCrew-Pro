create or replace function public.linecrew_can_view_job_packet_job(p_job_id uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $$
  select exists (
    select 1
    from public.profiles profile
    join public.jobs job
      on job.id = p_job_id
     and job.company_id = profile.company_id
    where profile.id = auth.uid()
      and profile.active is true
      and (
        lower(coalesce(profile.role,'')) in ('owner','admin','manager','superintendent','gf')
        or (
          lower(coalesce(profile.role,'')) = 'foreman'
          and exists (
            select 1
            from public.job_leader_assignments assignment
            where assignment.company_id = profile.company_id
              and assignment.job_id = job.id
              and assignment.member_id = profile.id
          )
        )
      )
  );
$$;

revoke all on function public.linecrew_can_view_job_packet_job(uuid) from public, anon;
grant execute on function public.linecrew_can_view_job_packet_job(uuid) to authenticated, service_role;

create or replace function public.get_job_package_documents(
  p_job_package_id uuid default null,
  p_job_id uuid default null
)
returns table(
  id uuid,
  job_id uuid,
  job_package_id uuid,
  storage_path text,
  original_filename text,
  mime_type text,
  file_size_bytes bigint,
  page_count integer,
  created_at timestamptz
)
language plpgsql
security definer
set search_path to ''
as $$
begin
  if auth.uid() is null or not public.current_user_has_active_profile() then
    raise exception 'Authentication required' using errcode='42501';
  end if;

  return query
  select d.id,d.job_id,d.job_package_id,d.storage_path,d.original_filename,d.mime_type,d.file_size_bytes,d.page_count,d.created_at
  from public.job_package_documents d
  where d.company_id=public.my_company_id()
    and public.linecrew_can_view_job_packet_job(d.job_id)
    and (p_job_package_id is null or d.job_package_id=p_job_package_id)
    and (p_job_id is null or d.job_id=p_job_id)
  order by d.created_at desc;
end;
$$;

revoke all on function public.get_job_package_documents(uuid,uuid) from public, anon;
grant execute on function public.get_job_package_documents(uuid,uuid) to authenticated, service_role;

create or replace function public.get_job_map_page(
  p_job_id uuid,
  p_work_point_code text default null
)
returns table(
  job_package_id uuid,
  storage_path text,
  original_filename text,
  page_number integer,
  page_count integer
)
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_company uuid;
  v_key text;
begin
  if auth.uid() is null or not public.current_user_has_active_profile() then
    raise exception 'Authentication required' using errcode='42501';
  end if;
  v_company := public.my_company_id();
  if not exists(select 1 from public.jobs j where j.id=p_job_id and j.company_id=v_company) then
    raise exception 'Job not found' using errcode='P0002';
  end if;
  if not public.linecrew_can_view_job_packet_job(p_job_id) then
    raise exception 'You do not have access to this job packet.' using errcode='42501';
  end if;

  v_key := public.normalize_work_point_key(coalesce(p_work_point_code,''));

  return query
  with candidates as (
    select d.job_package_id,d.storage_path,d.original_filename,d.page_count,d.created_at,
      case when v_key<>'' then (
        select min(r.source_page)
        from public.utility_packet_imports i
        join public.utility_packet_import_rows r on r.import_id=i.id and r.company_id=v_company
        where i.job_package_id=d.job_package_id and i.company_id=v_company
          and public.normalize_work_point_key(coalesce(r.work_point_code,''))=v_key
          and coalesce(r.include_in_import,true)
      ) end as matched_page
    from public.job_package_documents d
    join public.job_packages jp on jp.id=d.job_package_id
    where d.company_id=v_company and d.job_id=p_job_id
    order by jp.revision_number desc, d.created_at desc
  )
  select c.job_package_id,c.storage_path,c.original_filename,c.matched_page,c.page_count
  from candidates c
  order by (c.matched_page is not null) desc,c.created_at desc
  limit 1;
end;
$$;

revoke all on function public.get_job_map_page(uuid,text) from public, anon;
grant execute on function public.get_job_map_page(uuid,text) to authenticated, service_role;

drop policy if exists job_packet_documents_company_read on storage.objects;
create policy job_packet_documents_company_read
on storage.objects
for select
to authenticated
using (
  bucket_id = 'job-packet-documents'
  and public.current_user_has_active_profile()
  and (storage.foldername(name))[1] = public.my_company_id()::text
  and exists (
    select 1
    from public.jobs job
    where job.company_id = public.my_company_id()
      and job.id::text = (storage.foldername(objects.name))[2]
      and public.linecrew_can_view_job_packet_job(job.id)
  )
);
