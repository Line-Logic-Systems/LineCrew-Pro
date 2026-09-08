-- Prevent duplicate active Utility Portal organizations while retaining inactive
-- historical records. The partial unique index closes concurrent-insert races;
-- the trigger returns a clear message for ordinary duplicate attempts.

create or replace function public.utility_reject_duplicate_active_organization()
returns trigger
language plpgsql
set search_path to ''
as $function$
begin
  if new.active is true and exists (
    select 1
    from public.utility_organizations organization
    where organization.active is true
      and organization.id <> new.id
      and lower(btrim(organization.name)) = lower(btrim(new.name))
  ) then
    raise exception using
      errcode = '23505',
      message = 'An active utility organization with this name already exists.';
  end if;
  return new;
end;
$function$;

revoke all on function public.utility_reject_duplicate_active_organization()
  from public, anon, authenticated, service_role;

drop trigger if exists utility_organizations_reject_duplicate_active_name
  on public.utility_organizations;

create trigger utility_organizations_reject_duplicate_active_name
before insert or update of name, active on public.utility_organizations
for each row execute function public.utility_reject_duplicate_active_organization();

create unique index if not exists utility_organizations_active_name_uidx
  on public.utility_organizations (lower(btrim(name)))
  where active is true;
