-- Preserve only the reviewed money-visibility flags for Foreman/GF profiles.
-- Operational capability overrides remain Superintendent-only.
create or replace function public.linecrew_validate_profile_role()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  key text;
begin
  new.role := lower(trim(new.role));
  if new.role not in ('foreman','gf','superintendent','admin','owner') then
    raise exception 'Unsupported LineCrew Pro role: %', new.role;
  end if;

  new.role_permissions := coalesce(new.role_permissions, '{}'::jsonb);
  if jsonb_typeof(new.role_permissions) <> 'object' then
    raise exception 'Role permissions must be a JSON object';
  end if;

  foreach key in array array['actual_pricing','field_pricing']
  loop
    if new.role_permissions ? key and
       jsonb_typeof(new.role_permissions -> key) <> 'boolean' then
      raise exception 'Money visibility permission % must be true or false', key;
    end if;
  end loop;

  if new.role in ('foreman','gf') then
    new.role_permissions := jsonb_strip_nulls(jsonb_build_object(
      'actual_pricing', new.role_permissions -> 'actual_pricing',
      'field_pricing', new.role_permissions -> 'field_pricing'
    ));
  elsif new.role in ('admin','owner') then
    new.role_permissions := '{}'::jsonb;
  end if;

  return new;
end;
$$;

alter function public.linecrew_validate_profile_role() set search_path = '';
