-- Flexible JSA workflow: digital LineCrew Pro JSA, uploaded company form, or both.
-- JSA remains optional and does not gate daily production/report submission.

alter table public.companies
  add column if not exists jsa_method text not null default 'both';

alter table public.companies
  drop constraint if exists companies_jsa_method_supported;
alter table public.companies
  add constraint companies_jsa_method_supported
  check (jsa_method in ('digital','upload','both'));

alter table public.daily_report_jsas
  add column if not exists jsa_source text not null default 'digital',
  add column if not exists upload_notes text;

alter table public.daily_report_jsas
  drop constraint if exists daily_report_jsas_source_supported;
alter table public.daily_report_jsas
  add constraint daily_report_jsas_source_supported
  check (jsa_source in ('digital','upload'));

create table if not exists public.jsa_upload_attachments (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  jsa_id uuid not null references public.daily_report_jsas(id) on delete cascade,
  storage_path text not null,
  original_filename text not null,
  mime_type text not null,
  file_size_bytes bigint not null,
  page_order integer not null default 1,
  uploaded_by uuid not null references auth.users(id),
  created_at timestamptz not null default now(),
  unique(jsa_id, storage_path)
);

alter table public.jsa_upload_attachments enable row level security;

create index if not exists jsa_upload_attachments_company_jsa_idx
  on public.jsa_upload_attachments(company_id, jsa_id, page_order);

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'jsa-uploads',
  'jsa-uploads',
  false,
  15728640,
  array['application/pdf','image/jpeg','image/png','image/heic','image/heif']
)
on conflict (id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create or replace function public.set_company_jsa_method(p_method text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_method text := lower(trim(coalesce(p_method,'')));
begin
  select p.company_id, lower(coalesce(p.role,''))
  into v_company_id, v_role
  from public.profiles p
  where p.id = auth.uid() and p.active is true;

  if v_company_id is null or v_role not in ('owner','admin') then
    raise exception using errcode='42501', message='Only an active Owner or Admin can change the company JSA method.';
  end if;
  if v_method not in ('digital','upload','both') then
    raise exception using errcode='22023', message='JSA method must be digital, upload, or both.';
  end if;

  update public.companies set jsa_method=v_method where id=v_company_id;
  return v_method;
end;
$$;
revoke all on function public.set_company_jsa_method(text) from public, anon;
grant execute on function public.set_company_jsa_method(text) to authenticated;

create or replace function public.create_uploaded_company_jsa(
  p_job_id uuid,
  p_work_date date,
  p_crew_name text,
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
  v_method text;
  v_jsa_id uuid;
begin
  select p.company_id, lower(coalesce(p.role,'')), c.jsa_method
  into v_company_id, v_role, v_method
  from public.profiles p
  join public.companies c on c.id=p.company_id
  where p.id=auth.uid() and p.active is true;

  if v_company_id is null or v_role not in ('foreman','gf','superintendent','admin','owner') then
    raise exception using errcode='42501', message='An active company member is required.';
  end if;
  if v_role='superintendent' and not public.linecrew_has_capability('safety_records') then
    raise exception using errcode='42501', message='Safety Records permission is disabled for this Superintendent.';
  end if;
  if v_method not in ('upload','both') then
    raise exception using errcode='42501', message='Uploaded company JSAs are disabled in Company Settings.';
  end if;
  if p_work_date is null or length(trim(coalesce(p_crew_name,'')))=0 then
    raise exception using errcode='22023', message='Work date and crew name are required.';
  end if;
  if not exists(select 1 from public.jobs j where j.id=p_job_id and j.company_id=v_company_id and j.active is true) then
    raise exception using errcode='P0002', message='An active job was not found for your company.';
  end if;

  insert into public.daily_report_jsas(
    company_id,daily_report_id,job_id,created_by,work_date,crew_name,
    job_briefing,hazards,controls,ppe,emergency_plan,crew_members,
    foreman_acknowledged,jsa_source,upload_notes,updated_at
  ) values (
    v_company_id,null,p_job_id,auth.uid(),p_work_date,trim(p_crew_name),
    'See uploaded company JSA','See uploaded company JSA','See uploaded company JSA',
    'See uploaded company JSA','See uploaded company JSA','See uploaded company JSA',
    false,'upload',nullif(trim(coalesce(p_notes,'')),''),now()
  ) returning id into v_jsa_id;
  return v_jsa_id;
end;
$$;
revoke all on function public.create_uploaded_company_jsa(uuid,date,text,text) from public, anon;
grant execute on function public.create_uploaded_company_jsa(uuid,date,text,text) to authenticated;

create or replace function public.register_jsa_upload_attachment(
  p_jsa_id uuid,
  p_storage_path text,
  p_original_filename text,
  p_mime_type text,
  p_file_size_bytes bigint,
  p_page_order integer default 1
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_jsa_creator uuid;
  v_jsa_source text;
  v_id uuid;
begin
  select p.company_id into v_company_id from public.profiles p
  where p.id=auth.uid() and p.active is true;
  select j.created_by,j.jsa_source into v_jsa_creator,v_jsa_source
  from public.daily_report_jsas j where j.id=p_jsa_id and j.company_id=v_company_id;
  if v_jsa_creator is null or v_jsa_source <> 'upload' then
    raise exception using errcode='P0002', message='Uploaded JSA record was not found for your company.';
  end if;
  if v_jsa_creator <> auth.uid() and not exists(
    select 1 from public.profiles p where p.id=auth.uid() and p.company_id=v_company_id
      and (lower(p.role) in ('owner','admin','gf') or (lower(p.role)='superintendent' and public.linecrew_has_capability('safety_records')))
  ) then
    raise exception using errcode='42501', message='You cannot add files to this JSA.';
  end if;
  if p_mime_type not in ('application/pdf','image/jpeg','image/png','image/heic','image/heif')
     or p_file_size_bytes <= 0 or p_file_size_bytes > 15728640 then
    raise exception using errcode='22023', message='Upload a PDF or supported image no larger than 15 MB.';
  end if;
  if p_storage_path not like v_company_id::text || '/%' then
    raise exception using errcode='42501', message='Invalid company storage path.';
  end if;
  insert into public.jsa_upload_attachments(company_id,jsa_id,storage_path,original_filename,mime_type,file_size_bytes,page_order,uploaded_by)
  values(v_company_id,p_jsa_id,p_storage_path,p_original_filename,p_mime_type,p_file_size_bytes,greatest(coalesce(p_page_order,1),1),auth.uid())
  returning id into v_id;
  return v_id;
end;
$$;
revoke all on function public.register_jsa_upload_attachment(uuid,text,text,text,bigint,integer) from public, anon;
grant execute on function public.register_jsa_upload_attachment(uuid,text,text,text,bigint,integer) to authenticated;

-- Storage access is company-scoped. Object names must begin with company UUID.
drop policy if exists "jsa uploads company read" on storage.objects;
create policy "jsa uploads company read" on storage.objects for select to authenticated
using (
  bucket_id='jsa-uploads' and
  (storage.foldername(name))[1] = (select company_id::text from public.profiles where id=auth.uid() and active is true)
);
drop policy if exists "jsa uploads company insert" on storage.objects;
create policy "jsa uploads company insert" on storage.objects for insert to authenticated
with check (
  bucket_id='jsa-uploads' and
  (storage.foldername(name))[1] = (select company_id::text from public.profiles where id=auth.uid() and active is true)
);
drop policy if exists "jsa uploads company delete" on storage.objects;
create policy "jsa uploads company delete" on storage.objects for delete to authenticated
using (
  bucket_id='jsa-uploads' and
  (storage.foldername(name))[1] = (select company_id::text from public.profiles where id=auth.uid() and active is true)
);
