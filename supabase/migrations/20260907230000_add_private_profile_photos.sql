alter table public.profiles
  add column if not exists avatar_path text;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'profile-photos',
  'profile-photos',
  false,
  10485760,
  array['image/jpeg', 'image/png', 'image/webp']
)
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists profile_photos_company_read on storage.objects;
create policy profile_photos_company_read
on storage.objects for select to authenticated
using (
  bucket_id = 'profile-photos'
  and (storage.foldername(name))[1] = (public.my_company_id())::text
  and public.current_user_has_active_profile()
);

drop policy if exists profile_photos_self_insert on storage.objects;
create policy profile_photos_self_insert
on storage.objects for insert to authenticated
with check (
  bucket_id = 'profile-photos'
  and (storage.foldername(name))[1] = (public.my_company_id())::text
  and (storage.foldername(name))[2] = (select auth.uid())::text
  and public.current_user_has_active_profile()
);

drop policy if exists profile_photos_self_update on storage.objects;
create policy profile_photos_self_update
on storage.objects for update to authenticated
using (
  bucket_id = 'profile-photos'
  and (storage.foldername(name))[1] = (public.my_company_id())::text
  and (storage.foldername(name))[2] = (select auth.uid())::text
  and public.current_user_has_active_profile()
)
with check (
  bucket_id = 'profile-photos'
  and (storage.foldername(name))[1] = (public.my_company_id())::text
  and (storage.foldername(name))[2] = (select auth.uid())::text
  and public.current_user_has_active_profile()
);

drop policy if exists profile_photos_self_delete on storage.objects;
create policy profile_photos_self_delete
on storage.objects for delete to authenticated
using (
  bucket_id = 'profile-photos'
  and (storage.foldername(name))[1] = (public.my_company_id())::text
  and (storage.foldername(name))[2] = (select auth.uid())::text
  and public.current_user_has_active_profile()
);

create or replace function public.update_my_profile_avatar(p_avatar_path text)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_path text := nullif(btrim(coalesce(p_avatar_path, '')), '');
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Authentication required.';
  end if;

  select profile.company_id into v_company_id
  from public.profiles profile
  where profile.id = auth.uid() and profile.active is true;

  if v_company_id is null then
    raise exception using errcode = '42501', message = 'An active company profile is required.';
  end if;

  if v_path is not null and v_path <> (v_company_id::text || '/' || auth.uid()::text || '/avatar.jpg') then
    raise exception using errcode = '22023', message = 'Invalid profile photo path.';
  end if;

  update public.profiles profile
  set avatar_path = v_path
  where profile.id = auth.uid() and profile.company_id = v_company_id;

  return v_path;
end;
$$;

revoke all on function public.update_my_profile_avatar(text) from public;
revoke all on function public.update_my_profile_avatar(text) from anon;
grant execute on function public.update_my_profile_avatar(text) to authenticated;
grant execute on function public.update_my_profile_avatar(text) to service_role;
