begin;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'daily-report-attachments',
  'daily-report-attachments',
  false,
  15728640,
  array[
    'image/jpeg','image/png','image/webp','application/pdf',
    'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'text/csv'
  ]
)
on conflict (id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

create table if not exists public.daily_report_attachments (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  daily_report_id uuid not null references public.daily_reports(id) on delete cascade,
  storage_path text not null unique,
  original_filename text not null,
  mime_type text,
  file_size_bytes bigint not null default 0 check (file_size_bytes between 0 and 15728640),
  caption text,
  uploaded_by uuid not null default auth.uid() references auth.users(id) on delete restrict,
  created_at timestamptz not null default now()
);

create index if not exists daily_report_attachments_report_idx
  on public.daily_report_attachments(company_id, daily_report_id, created_at);

alter table public.daily_report_attachments enable row level security;

drop policy if exists daily_report_attachments_company_select
  on public.daily_report_attachments;
create policy daily_report_attachments_company_select
  on public.daily_report_attachments for select
  to authenticated
  using (
    company_id = (
      select profile.company_id
      from public.profiles profile
      where profile.id = auth.uid()
    )
  );

drop policy if exists daily_report_storage_company_select on storage.objects;
create policy daily_report_storage_company_select
  on storage.objects for select
  to authenticated
  using (
    bucket_id = 'daily-report-attachments'
    and (storage.foldername(name))[1] = (
      select profile.company_id::text
      from public.profiles profile
      where profile.id = auth.uid()
    )
  );

drop policy if exists daily_report_storage_company_insert on storage.objects;
create policy daily_report_storage_company_insert
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'daily-report-attachments'
    and (storage.foldername(name))[1] = (
      select profile.company_id::text
      from public.profiles profile
      where profile.id = auth.uid()
    )
  );

drop policy if exists daily_report_storage_owner_or_lead_delete on storage.objects;
create policy daily_report_storage_owner_or_lead_delete
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'daily-report-attachments'
    and (storage.foldername(name))[1] = (
      select profile.company_id::text
      from public.profiles profile
      where profile.id = auth.uid()
    )
    and (
      owner_id = auth.uid()::text
      or lower(coalesce((
        select profile.role
        from public.profiles profile
        where profile.id = auth.uid()
      ), '')) in ('admin','gf')
    )
  );

create or replace function public.register_daily_report_attachment(
  p_report_id uuid,
  p_storage_path text,
  p_original_filename text,
  p_mime_type text default null,
  p_file_size_bytes bigint default 0,
  p_caption text default null
)
returns public.daily_report_attachments
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile public.profiles%rowtype;
  v_report public.daily_reports%rowtype;
  v_result public.daily_report_attachments;
begin
  select * into v_profile
  from public.profiles
  where id = auth.uid();

  if v_profile.id is null or v_profile.company_id is null then
    raise exception 'Active company membership required.';
  end if;

  select * into v_report
  from public.daily_reports
  where id = p_report_id
    and company_id = v_profile.company_id;

  if v_report.id is null then
    raise exception 'Daily report not found for your company.';
  end if;

  if p_storage_path is null or
     p_storage_path not like v_profile.company_id::text || '/' || p_report_id::text || '/%' then
    raise exception 'Invalid attachment storage path.';
  end if;

  if trim(coalesce(p_original_filename, '')) = '' then
    raise exception 'Attachment filename is required.';
  end if;

  if coalesce(p_file_size_bytes, 0) < 0 or
     coalesce(p_file_size_bytes, 0) > 15728640 then
    raise exception 'Attachment must be 15 MB or smaller.';
  end if;

  insert into public.daily_report_attachments(
    company_id, daily_report_id, storage_path, original_filename,
    mime_type, file_size_bytes, caption, uploaded_by
  ) values (
    v_profile.company_id, p_report_id, p_storage_path,
    left(trim(p_original_filename), 255),
    nullif(trim(coalesce(p_mime_type, '')), ''),
    coalesce(p_file_size_bytes, 0),
    nullif(left(trim(coalesce(p_caption, '')), 500), ''),
    auth.uid()
  )
  returning * into v_result;

  return v_result;
end;
$$;

create or replace function public.delete_daily_report_attachment(
  p_attachment_id uuid
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_profile public.profiles%rowtype;
  v_attachment public.daily_report_attachments%rowtype;
begin
  select * into v_profile
  from public.profiles
  where id = auth.uid();

  select * into v_attachment
  from public.daily_report_attachments attachment
  where attachment.id = p_attachment_id
    and attachment.company_id = v_profile.company_id;

  if v_attachment.id is null then
    raise exception 'Attachment not found for your company.';
  end if;

  if v_attachment.uploaded_by <> auth.uid()
     and lower(coalesce(v_profile.role, '')) not in ('admin','gf') then
    raise exception 'Only the uploader, a General Foreman or an Admin may delete this attachment.';
  end if;

  delete from public.daily_report_attachments
  where id = v_attachment.id;

  return v_attachment.storage_path;
end;
$$;

revoke all on function public.register_daily_report_attachment(
  uuid,text,text,text,bigint,text
) from public, anon;
grant execute on function public.register_daily_report_attachment(
  uuid,text,text,text,bigint,text
) to authenticated;

revoke all on function public.delete_daily_report_attachment(uuid)
  from public, anon;
grant execute on function public.delete_daily_report_attachment(uuid)
  to authenticated;

commit;
