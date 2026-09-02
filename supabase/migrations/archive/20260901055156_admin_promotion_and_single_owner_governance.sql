-- Allow active Admins to promote trusted lower-role members to Admin while
-- keeping Owner assignment separate, explicit and company-scoped.

do $$
begin
  if exists (
    select 1
    from public.profiles
    where lower(coalesce(role, '')) = 'owner'
    group by company_id
    having count(*) > 1
  ) then
    raise exception using
      errcode = '23505',
      message = 'Resolve companies with multiple Owners before applying single-Owner governance.';
  end if;
end;
$$;

create unique index if not exists profiles_one_owner_per_company_idx
  on public.profiles (company_id)
  where lower(coalesce(role, '')) = 'owner';

comment on index public.profiles_one_owner_per_company_idx is
  'Enforces exactly zero or one Owner role per company. Owner creation and transfer are serialized by company row locks.';

create or replace function public.linecrew_claim_initial_owner()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor public.profiles%rowtype;
  actor_company_id uuid;
begin
  select profile.*
  into actor
  from public.profiles profile
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where profile.id = auth.uid();

  if actor.id is null or actor.active is not true or lower(actor.role) <> 'admin' then
    raise exception using
      errcode = '42501',
      message = 'Current active Admin access is required to claim the initial Owner role.';
  end if;

  actor_company_id := actor.company_id;

  -- Serialize every ownership mutation for this company. The unique index is
  -- the final defense, but this lock also produces a clear second-claim error.
  perform 1
  from public.companies
  where id = actor_company_id
    and active is true
  for update;

  if not found then
    raise exception using
      errcode = '42501',
      message = 'The company is not active.';
  end if;

  select *
  into actor
  from public.profiles
  where id = auth.uid()
    and company_id = actor_company_id
  for update;

  if actor.id is null or actor.active is not true or lower(actor.role) <> 'admin' then
    raise exception using
      errcode = '40001',
      message = 'Your profile changed while ownership was being assigned. Refresh and try again.';
  end if;

  if exists (
    select 1
    from public.profiles
    where company_id = actor_company_id
      and lower(coalesce(role, '')) = 'owner'
  ) then
    raise exception using
      errcode = '23505',
      message = 'This company already has an Owner. The current Owner must transfer ownership.';
  end if;

  update public.profiles
  set role = 'owner'
  where id = actor.id
    and company_id = actor_company_id
    and active is true
    and lower(coalesce(role, '')) = 'admin';

  if not found then
    raise exception using
      errcode = '40001',
      message = 'Your profile changed while ownership was being assigned. Refresh and try again.';
  end if;

  insert into public.audit_log (
    company_id, user_id, action, table_name, record_id, old_data, new_data
  ) values (
    actor_company_id,
    actor.id,
    'initial_owner_claimed',
    'profiles',
    actor.id,
    jsonb_build_object('role', 'admin'),
    jsonb_build_object('role', 'owner')
  );
end;
$$;

revoke all on function public.linecrew_claim_initial_owner()
  from public, anon;
grant execute on function public.linecrew_claim_initial_owner()
  to authenticated;

create or replace function public.linecrew_set_member_role(
  target_user_id uuid,
  new_role text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor public.profiles%rowtype;
  target public.profiles%rowtype;
  actor_company_id uuid;
  actor_role text;
  target_role text;
  requested_role text := lower(btrim(coalesce(new_role, '')));
begin
  if target_user_id is null or
     requested_role not in ('foreman','gf','superintendent','admin') then
    raise exception using
      errcode = '22023',
      message = 'Choose Foreman, General Foreman, Superintendent, or Admin. Owner changes use the ownership controls.';
  end if;

  select profile.*
  into actor
  from public.profiles profile
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where profile.id = auth.uid();

  actor_role := lower(coalesce(actor.role, ''));
  if actor.id is null or actor.active is not true or
     actor_role not in ('owner','admin','superintendent') then
    raise exception using
      errcode = '42501',
      message = 'Active company role-management access is required.';
  end if;

  actor_company_id := actor.company_id;

  if actor_role = 'superintendent' and
     coalesce((actor.role_permissions ->> 'role_management')::boolean, true) is not true then
    raise exception using
      errcode = '42501',
      message = 'Role management is disabled for this Superintendent.';
  end if;

  if target_user_id = actor.id then
    raise exception using
      errcode = '42501',
      message = 'You cannot change your own role. Use the initial Owner claim or ownership-transfer control when applicable.';
  end if;

  -- Keep role and ownership changes ordered per company and make the target's
  -- authorization state stable until this transaction commits.
  perform 1
  from public.companies
  where id = actor_company_id
    and active is true
  for update;

  if not found then
    raise exception using
      errcode = '42501',
      message = 'The company is not active.';
  end if;

  select *
  into actor
  from public.profiles
  where id = auth.uid()
    and company_id = actor_company_id
  for update;

  actor_role := lower(coalesce(actor.role, ''));
  if actor.id is null or actor.active is not true or
     actor_role not in ('owner','admin','superintendent') then
    raise exception using
      errcode = '40001',
      message = 'Your role or access changed while the role update was starting. Refresh and try again.';
  end if;

  if actor_role = 'superintendent' and
     coalesce((actor.role_permissions ->> 'role_management')::boolean, true) is not true then
    raise exception using
      errcode = '42501',
      message = 'Role management is disabled for this Superintendent.';
  end if;

  select *
  into target
  from public.profiles
  where id = target_user_id
    and company_id = actor_company_id
  for update;

  if target.id is null then
    raise exception using
      errcode = 'P0002',
      message = 'Team member was not found in your company.';
  end if;

  target_role := lower(coalesce(target.role, ''));

  if target_role = 'owner' then
    raise exception using
      errcode = '42501',
      message = 'Owner changes require the ownership-transfer control.';
  end if;

  if target.active is not true then
    raise exception using
      errcode = '23514',
      message = 'Restore this team member''s access before changing their role.';
  end if;

  if actor_role = 'admin' then
    if target_role = 'admin' then
      raise exception using
        errcode = '42501',
        message = 'Only the Owner can change an existing Admin. Admins may promote a Foreman, General Foreman, or Superintendent to Admin.';
    end if;
  end if;

  if actor_role = 'superintendent' then
    if target_role not in ('foreman','gf') or requested_role not in ('foreman','gf') then
      raise exception using
        errcode = '42501',
        message = 'A Superintendent can manage General Foreman and Foreman roles only.';
    end if;
  end if;

  if target_role = requested_role then
    return;
  end if;

  update public.profiles
  set role = requested_role,
      role_permissions = case
        when requested_role = 'superintendent' then role_permissions
        else '{}'::jsonb
      end
  where id = target.id
    and company_id = actor_company_id;

  insert into public.audit_log (
    company_id, user_id, action, table_name, record_id, old_data, new_data
  ) values (
    actor_company_id,
    actor.id,
    'team_member_role_changed',
    'profiles',
    target.id,
    jsonb_build_object(
      'role', target_role,
      'role_permissions', target.role_permissions
    ),
    jsonb_build_object(
      'role', requested_role,
      'role_permissions', case
        when requested_role = 'superintendent' then target.role_permissions
        else '{}'::jsonb
      end
    )
  );
end;
$$;

revoke all on function public.linecrew_set_member_role(uuid, text)
  from public, anon;
grant execute on function public.linecrew_set_member_role(uuid, text)
  to authenticated;

-- Ownership is a single, explicit handoff. The current Owner becomes Admin in
-- the same transaction in which the chosen active Admin becomes Owner.
create or replace function public.linecrew_transfer_company_owner(
  target_admin_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor public.profiles%rowtype;
  target public.profiles%rowtype;
  actor_company_id uuid;
begin
  if target_admin_id is null or target_admin_id = auth.uid() then
    raise exception using
      errcode = '22023',
      message = 'Choose another active Admin to receive ownership.';
  end if;

  select profile.*
  into actor
  from public.profiles profile
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where profile.id = auth.uid();

  if actor.id is null or actor.active is not true or lower(actor.role) <> 'owner' then
    raise exception using
      errcode = '42501',
      message = 'Only the current active Owner can transfer company ownership.';
  end if;

  actor_company_id := actor.company_id;

  perform 1
  from public.companies
  where id = actor_company_id
    and active is true
  for update;

  if not found then
    raise exception using
      errcode = '42501',
      message = 'The company is not active.';
  end if;

  -- Re-check the actor after taking the company governance lock.
  select *
  into actor
  from public.profiles
  where id = auth.uid()
    and company_id = actor_company_id
  for update;

  if actor.id is null or actor.active is not true or lower(actor.role) <> 'owner' then
    raise exception using
      errcode = '40001',
      message = 'Ownership changed while the transfer was starting. Refresh and try again.';
  end if;

  select *
  into target
  from public.profiles
  where id = target_admin_id
    and company_id = actor_company_id
  for update;

  if target.id is null or target.active is not true or lower(target.role) <> 'admin' then
    raise exception using
      errcode = '23514',
      message = 'Ownership can be transferred only to another active Admin in your company.';
  end if;

  -- Temporarily having zero Owners is safe inside this atomic transaction and
  -- avoids violating the non-deferrable single-Owner unique index.
  update public.profiles
  set role = 'admin'
  where id = actor.id and company_id = actor_company_id;

  update public.profiles
  set role = 'owner'
  where id = target.id and company_id = actor_company_id;

  insert into public.audit_log (
    company_id, user_id, action, table_name, record_id, old_data, new_data
  ) values (
    actor_company_id,
    actor.id,
    'company_ownership_transferred',
    'profiles',
    target.id,
    jsonb_build_object(
      'owner_user_id', actor.id,
      'owner_role', 'owner',
      'target_user_id', target.id,
      'target_role', 'admin'
    ),
    jsonb_build_object(
      'owner_user_id', target.id,
      'owner_role', 'owner',
      'previous_owner_user_id', actor.id,
      'previous_owner_role', 'admin'
    )
  );
end;
$$;

revoke all on function public.linecrew_transfer_company_owner(uuid)
  from public, anon;
grant execute on function public.linecrew_transfer_company_owner(uuid)
  to authenticated;

-- Team-access changes share the same company governance lock as role and
-- ownership changes. Re-reading the actor after that lock prevents a former
-- Owner from using stale Owner authority if ownership transfers concurrently.
create or replace function public.set_company_member_active(
  p_member_id uuid,
  p_active boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor public.profiles%rowtype;
  target public.profiles%rowtype;
  actor_company_id uuid;
  actor_role text;
  target_role text;
begin
  if p_member_id is null or p_active is null then
    raise exception using
      errcode = '22004',
      message = 'Team member and access status are required.';
  end if;

  select profile.*
  into actor
  from public.profiles profile
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where profile.id = auth.uid();

  actor_role := lower(coalesce(actor.role, ''));
  if actor.id is null or actor.active is not true or
     actor_role not in ('owner','admin','superintendent') then
    raise exception using
      errcode = '42501',
      message = 'Active company leadership access is required.';
  end if;

  actor_company_id := actor.company_id;

  if p_member_id = actor.id then
    raise exception using
      errcode = '42501',
      message = 'You cannot suspend your own account.';
  end if;

  perform 1
  from public.companies
  where id = actor_company_id
    and active is true
  for update;

  if not found then
    raise exception using
      errcode = '42501',
      message = 'The company is not active.';
  end if;

  select *
  into actor
  from public.profiles
  where id = auth.uid()
    and company_id = actor_company_id
  for update;

  actor_role := lower(coalesce(actor.role, ''));
  if actor.id is null or actor.active is not true or
     actor_role not in ('owner','admin','superintendent') then
    raise exception using
      errcode = '40001',
      message = 'Your role or access changed while the access update was starting. Refresh and try again.';
  end if;

  if actor_role = 'superintendent' and
     coalesce((actor.role_permissions ->> 'team_management')::boolean, true) is not true then
    raise exception using
      errcode = '42501',
      message = 'Team access management is disabled for this Superintendent.';
  end if;

  select *
  into target
  from public.profiles
  where id = p_member_id
    and company_id = actor_company_id
  for update;

  if target.id is null then
    raise exception using
      errcode = 'P0002',
      message = 'Team member was not found in your company.';
  end if;

  target_role := lower(coalesce(target.role, ''));

  if actor_role = 'admin' and target_role in ('owner','admin') then
    raise exception using
      errcode = '42501',
      message = 'Only an Owner can change Owner or Admin account access.';
  end if;

  if actor_role = 'superintendent' and target_role not in ('foreman','gf') then
    raise exception using
      errcode = '42501',
      message = 'A Superintendent can change access for General Foremen and Foremen only.';
  end if;

  if p_active is false and target_role = 'owner' then
    raise exception using
      errcode = '23514',
      message = 'Transfer ownership before suspending the company Owner.';
  end if;

  update public.profiles
  set active = p_active
  where id = target.id
    and company_id = actor_company_id;
end;
$$;

revoke all on function public.set_company_member_active(uuid, boolean)
  from public, anon;
grant execute on function public.set_company_member_active(uuid, boolean)
  to authenticated;

comment on function public.linecrew_set_member_role(uuid, text) is
  'Company-scoped role management. Admin may promote lower roles to Admin but cannot alter an existing Admin or any Owner.';
comment on function public.linecrew_claim_initial_owner() is
  'Allows one active Admin to claim Owner only when the company has no Owner.';
comment on function public.linecrew_transfer_company_owner(uuid) is
  'Atomically transfers the company''s single Owner role to another active Admin.';
comment on function public.set_company_member_active(uuid, boolean) is
  'Company-scoped team access management serialized with role and ownership changes.';
