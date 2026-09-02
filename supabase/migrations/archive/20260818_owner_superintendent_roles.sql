-- LineCrew Pro: Owner + configurable Superintendent role foundation
-- Apply in Supabase before enabling the matching frontend controls.
-- Owner is company-level full access. Superintendent starts with broad operational
-- access, but Admin/Owner may disable individual capabilities per user.

alter table public.profiles
  add column if not exists role_permissions jsonb not null default '{}'::jsonb;

comment on column public.profiles.role_permissions is
  'Per-user role overrides for Superintendent capabilities. Missing keys default to allowed; explicit false denies access.';

-- Replace the legacy three-role constraint with the full company hierarchy.
alter table public.profiles
  drop constraint if exists profiles_role_supported;

alter table public.profiles
  add constraint profiles_role_supported
  check (lower(role) in ('foreman', 'gf', 'superintendent', 'admin', 'owner'));

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
      and p.active is true
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
  if actor.id is null or actor.active is not true or lower(actor.role) <> 'admin' then
    raise exception 'Current active Admin access required';
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

-- Central role-management RPC.
-- Owner may assign/remove Admins and manage all lower roles.
-- Admin may manage Superintendent/GF/Foreman but can never create, demote, or edit an Owner or Admin.
-- A Superintendent with role_management enabled may manage GF/Foreman only.
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
  if actor.id is null or actor.active is not true or lower(actor.role) not in ('owner','admin','superintendent') then
    raise exception 'Active company management access required';
  end if;

  if lower(actor.role) = 'superintendent'
     and coalesce((actor.role_permissions ->> 'role_management')::boolean, true) is not true then
    raise exception 'Role management is disabled for this Superintendent';
  end if;

  select * into target from public.profiles where id = target_user_id;
  if target.id is null or target.company_id <> actor.company_id then
    raise exception 'Team member not found';
  end if;

  if lower(actor.role) = 'superintendent' then
    if lower(target.role) in ('owner','admin','superintendent')
       or requested_role in ('owner','admin','superintendent') then
      raise exception 'A Superintendent can manage General Foreman and Foreman roles only';
    end if;
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

-- Preserve the RPC name used by the existing Team screen, but route it through
-- the new hierarchy so a manipulated older client cannot bypass Owner protections.
create or replace function public.set_company_member_role(
  p_member_id uuid,
  p_role text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.linecrew_set_member_role(p_member_id, p_role);
end;
$$;

revoke all on function public.set_company_member_role(uuid,text) from public;
revoke all on function public.set_company_member_role(uuid,text) from anon;
grant execute on function public.set_company_member_role(uuid,text) to authenticated;

-- Owner/Admin-controlled Superintendent overrides.
-- Only known boolean capabilities are accepted so malformed JSON cannot become
-- an accidental authorization path or break boolean casts in capability checks.
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
  item record;
  allowed_keys text[] := array[
    'company_settings',
    'team_management',
    'role_management',
    'customers_contracts',
    'price_books',
    'jobs',
    'job_packages',
    'production_review',
    'reporting',
    'storm_mode',
    'safety_records',
    'actual_pricing',
    'exports',
    'ai_assistant'
  ];
begin
  select * into actor from public.profiles where id = auth.uid();
  if actor.id is null or actor.active is not true or lower(actor.role) not in ('owner','admin') then
    raise exception 'Active Admin or Owner access required';
  end if;

  select * into target from public.profiles where id = target_user_id;
  if target.id is null or target.company_id <> actor.company_id then
    raise exception 'Team member not found';
  end if;
  if lower(target.role) <> 'superintendent' then
    raise exception 'Permission overrides apply only to Superintendents';
  end if;

  permissions := coalesce(permissions, '{}'::jsonb);
  if jsonb_typeof(permissions) <> 'object' then
    raise exception 'Superintendent permissions must be a JSON object';
  end if;

  for item in select key, value from jsonb_each(permissions)
  loop
    if not (item.key = any(allowed_keys)) then
      raise exception 'Unsupported Superintendent capability: %', item.key;
    end if;
    if jsonb_typeof(item.value) <> 'boolean' then
      raise exception 'Superintendent capability % must be true or false', item.key;
    end if;
  end loop;

  update public.profiles
  set role_permissions = permissions
  where id = target_user_id and company_id = actor.company_id;
end;
$$;

revoke all on function public.linecrew_set_superintendent_permissions(uuid,jsonb) from public;
grant execute on function public.linecrew_set_superintendent_permissions(uuid,jsonb) to authenticated;
