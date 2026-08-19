-- LineCrew Pro: Owner + configurable Superintendent role foundation
-- Apply in Supabase before enabling the matching frontend controls.
-- Owner is company-level full access. Superintendent starts with broad operational
-- access, but Admin/Owner may disable individual capabilities per user.

alter table public.profiles
  add column if not exists role_permissions jsonb not null default '{}'::jsonb;

comment on column public.profiles.role_permissions is
  'Per-user role overrides. Intended for superintendent access controls; keys are capability names and values are booleans.';

-- Normalize role validation through a trigger so existing deployments that used
-- a text role column can safely accept the new roles without weakening tenant scope.
create or replace function public.linecrew_validate_profile_role()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.role := lower(trim(new.role));
  if new.role not in ('foreman','general_foreman','superintendent','admin','owner') then
    raise exception 'Unsupported LineCrew Pro role: %', new.role;
  end if;

  -- Only Superintendent uses configurable role_permissions for now.
  if new.role <> 'superintendent' then
    new.role_permissions := '{}'::jsonb;
  end if;
  return new;
end;
$$;

drop trigger if exists linecrew_validate_profile_role_trigger on public.profiles;
create trigger linecrew_validate_profile_role_trigger
before insert or update of role, role_permissions on public.profiles
for each row execute function public.linecrew_validate_profile_role();

-- Capability helper. Owner/Admin always have full company-management capability.
-- Superintendent defaults to allowed unless an Admin/Owner explicitly stores false.
create or replace function public.linecrew_has_capability(capability text)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select case
      when lower(p.role) in ('owner','admin') then true
      when lower(p.role) = 'superintendent'
        then coalesce((p.role_permissions ->> capability)::boolean, true)
      else false
    end
    from public.profiles p
    where p.id = auth.uid()
  ), false);
$$;

revoke all on function public.linecrew_has_capability(text) from public;
grant execute on function public.linecrew_has_capability(text) to authenticated;

-- Admin/Owner-controlled setter. It is company-scoped and cannot modify Owner access.
create or replace function public.linecrew_set_superintendent_permissions(
  target_user_id uuid,
  permissions jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  actor public.profiles%rowtype;
  target public.profiles%rowtype;
begin
  select * into actor from public.profiles where id = auth.uid();
  if actor.id is null or lower(actor.role) not in ('owner','admin') then
    raise exception 'Admin or Owner access required';
  end if;

  select * into target from public.profiles where id = target_user_id;
  if target.id is null or target.company_id <> actor.company_id then
    raise exception 'Team member not found';
  end if;
  if lower(target.role) <> 'superintendent' then
    raise exception 'Permission overrides apply only to Superintendents';
  end if;

  update public.profiles
  set role_permissions = coalesce(permissions, '{}'::jsonb)
  where id = target_user_id and company_id = actor.company_id;
end;
$$;

revoke all on function public.linecrew_set_superintendent_permissions(uuid,jsonb) from public;
grant execute on function public.linecrew_set_superintendent_permissions(uuid,jsonb) to authenticated;
