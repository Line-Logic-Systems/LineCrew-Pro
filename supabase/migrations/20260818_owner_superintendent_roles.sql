-- LineCrew Pro: Owner + configurable Superintendent role foundation
-- Apply in Supabase before enabling the matching frontend controls.
-- Existing role codes are: foreman, gf, admin. New codes: superintendent, owner.

alter table public.profiles
  add column if not exists role_permissions jsonb not null default '{}'::jsonb;

comment on column public.profiles.role_permissions is
  'Per-user role overrides. Intended for superintendent access controls; keys are capability names and values are booleans.';

create or replace function public.linecrew_validate_profile_role()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.role := lower(trim(new.role));
  if new.role not in ('foreman','gf','superintendent','admin','owner') then
    raise exception 'Unsupported LineCrew Pro role: %', new.role;
  end if;
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

-- Existing companies can promote one current Admin to Owner only when no Owner exists.
create or replace function public.linecrew_claim_initial_owner()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  actor public.profiles%rowtype;
  owner_count integer;
begin
  select * into actor from public.profiles where id = auth.uid();
  if actor.id is null or lower(actor.role) <> 'admin' then
    raise exception 'Current Admin access required';
  end if;

  select count(*) into owner_count
  from public.profiles
  where company_id = actor.company_id and lower(role) = 'owner';

  if owner_count > 0 then
    raise exception 'This company already has an Owner';
  end if;

  update public.profiles set role = 'owner' where id = actor.id;
end;
$$;

revoke all on function public.linecrew_claim_initial_owner() from public;
grant execute on function public.linecrew_claim_initial_owner() to authenticated;

-- Owner may assign/remove Admins and manage all lower roles.
-- Admin may manage Superintendent/GF/Foreman but can never create, demote, or edit an Owner or another Admin.
create or replace function public.linecrew_set_member_role(
  target_user_id uuid,
  new_role text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  actor public.profiles%rowtype;
  target public.profiles%rowtype;
  requested_role text := lower(trim(new_role));
  remaining_owners integer;
begin
  if requested_role not in ('foreman','gf','superintendent','admin','owner') then
    raise exception 'Unsupported role';
  end if;

  select * into actor from public.profiles where id = auth.uid();
  if actor.id is null or lower(actor.role) not in ('owner','admin') then
    raise exception 'Owner or Admin access required';
  end if;

  select * into target from public.profiles where id = target_user_id;
  if target.id is null or target.company_id <> actor.company_id then
    raise exception 'Team member not found';
  end if;

  if lower(actor.role) = 'admin' then
    if lower(target.role) in ('owner','admin') or requested_role in ('owner','admin') then
      raise exception 'Only an Owner can manage Owner or Admin roles';
    end if;
  end if;

  if lower(target.role) = 'owner' and requested_role <> 'owner' then
    select count(*) into remaining_owners
    from public.profiles
    where company_id = actor.company_id
      and lower(role) = 'owner'
      and id <> target.id;

    if remaining_owners = 0 then
      raise exception 'Assign another Owner before removing the last Owner';
    end if;
  end if;

  if requested_role = 'owner' and lower(actor.role) <> 'owner' then
    raise exception 'Only an Owner can assign another Owner';
  end if;

  update public.profiles
  set role = requested_role,
      role_permissions = case when requested_role = 'superintendent' then role_permissions else '{}'::jsonb end
  where id = target.id and company_id = actor.company_id;
end;
$$;

revoke all on function public.linecrew_set_member_role(uuid,text) from public;
grant execute on function public.linecrew_set_member_role(uuid,text) to authenticated;

-- Owner/Admin-controlled Superintendent overrides.
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
