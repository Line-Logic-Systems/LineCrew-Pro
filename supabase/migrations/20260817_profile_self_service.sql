begin;

create or replace function public.update_my_profile_name(
  p_full_name text
)
returns table(
  id uuid,
  full_name text,
  role text,
  company_id uuid
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_name text := trim(coalesce(p_full_name, ''));
begin
  if auth.uid() is null then
    raise exception 'Authentication required.';
  end if;

  if length(v_name) < 2 or length(v_name) > 120 then
    raise exception 'Display name must be between 2 and 120 characters.';
  end if;

  return query
  update public.profiles profile
  set full_name = v_name
  where profile.id = auth.uid()
  returning profile.id, profile.full_name, profile.role, profile.company_id;
end;
$$;

revoke all on function public.update_my_profile_name(text) from public, anon;
grant execute on function public.update_my_profile_name(text) to authenticated;

commit;
