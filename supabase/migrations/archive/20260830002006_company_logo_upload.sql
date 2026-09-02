-- Direct company-logo uploads for Company Settings.
-- Logos are publicly readable for app headers and printed/shared reports, while
-- writes remain restricted to an active member with Company Settings access.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'company-logos',
  'company-logos',
  true,
  2097152,
  array['image/png','image/jpeg','image/webp']
)
on conflict (id) do update set
  public = true,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists company_logo_company_settings_insert on storage.objects;
create policy company_logo_company_settings_insert
  on storage.objects for insert
  to authenticated
  with check (
    bucket_id = 'company-logos'
    and (storage.foldername(name))[1] = (
      select p.company_id::text
      from public.profiles p
      where p.id = (select auth.uid())
        and p.active is true
    )
    and public.linecrew_has_capability('company_settings')
  );

drop policy if exists company_logo_company_settings_delete on storage.objects;
create policy company_logo_company_settings_delete
  on storage.objects for delete
  to authenticated
  using (
    bucket_id = 'company-logos'
    and (storage.foldername(name))[1] = (
      select p.company_id::text
      from public.profiles p
      where p.id = (select auth.uid())
        and p.active is true
    )
    and public.linecrew_has_capability('company_settings')
  );
