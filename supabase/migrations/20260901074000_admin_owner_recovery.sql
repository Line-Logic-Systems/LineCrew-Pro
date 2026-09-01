-- Let an active Admin recover company ownership when the current Owner is no
-- longer available. The replacement and former-Owner role change happen in
-- one transaction so the company never exposes zero or multiple Owners.

create or replace function public.linecrew_admin_replace_company_owner(
  current_owner_id uuid,
  replacement_admin_id uuid,
  former_owner_role text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor public.profiles%rowtype;
  current_owner public.profiles%rowtype;
  replacement public.profiles%rowtype;
  actor_company_id uuid;
  requested_former_role text := lower(btrim(coalesce(former_owner_role, '')));
begin
  if current_owner_id is null or replacement_admin_id is null then
    raise exception using
      errcode = '22004',
      message = 'Choose the current Owner and an active Admin to receive ownership.';
  end if;

  if current_owner_id = replacement_admin_id then
    raise exception using
      errcode = '22023',
      message = 'The replacement Owner must be a different active Admin.';
  end if;

  if requested_former_role not in ('foreman','gf','superintendent','admin') then
    raise exception using
      errcode = '22023',
      message = 'Choose Admin, Superintendent, General Foreman, or Foreman for the former Owner.';
  end if;

  if coalesce((select auth.jwt() ->> 'aal'), 'aal1') <> 'aal2' then
    raise exception using
      errcode = '42501',
      message = 'Complete authenticator verification before recovering company ownership.';
  end if;

  select profile.*
  into actor
  from public.profiles profile
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where profile.id = auth.uid();

  if actor.id is null or actor.active is not true or lower(coalesce(actor.role, '')) <> 'admin' then
    raise exception using
      errcode = '42501',
      message = 'Only an active Admin can use ownership recovery.';
  end if;

  actor_company_id := actor.company_id;

  -- Serialize all ownership and team-governance mutations for this company.
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

  -- Re-read the Admin after taking the governance lock so stale authority
  -- cannot be used if another request changed their role or access.
  select *
  into actor
  from public.profiles
  where id = auth.uid()
    and company_id = actor_company_id
  for update;

  if actor.id is null or actor.active is not true or lower(coalesce(actor.role, '')) <> 'admin' then
    raise exception using
      errcode = '40001',
      message = 'Your role or access changed while ownership recovery was starting. Refresh and try again.';
  end if;

  select *
  into current_owner
  from public.profiles
  where id = current_owner_id
    and company_id = actor_company_id
  for update;

  if current_owner.id is null or lower(coalesce(current_owner.role, '')) <> 'owner' then
    raise exception using
      errcode = '23514',
      message = 'The selected person is no longer the Owner of your company. Refresh and try again.';
  end if;

  select *
  into replacement
  from public.profiles
  where id = replacement_admin_id
    and company_id = actor_company_id
  for update;

  if replacement.id is null or replacement.active is not true or lower(coalesce(replacement.role, '')) <> 'admin' then
    raise exception using
      errcode = '23514',
      message = 'Ownership recovery requires an active Admin from your company.';
  end if;

  -- The company lock makes this temporary zero-Owner state invisible outside
  -- the transaction and avoids violating the non-deferrable unique index.
  update public.profiles
  set role = requested_former_role,
      role_permissions = '{}'::jsonb
  where id = current_owner.id
    and company_id = actor_company_id
    and lower(coalesce(role, '')) = 'owner';

  if not found then
    raise exception using
      errcode = '40001',
      message = 'Ownership changed during recovery. Refresh and try again.';
  end if;

  update public.profiles
  set role = 'owner',
      role_permissions = '{}'::jsonb
  where id = replacement.id
    and company_id = actor_company_id
    and active is true
    and lower(coalesce(role, '')) = 'admin';

  if not found then
    raise exception using
      errcode = '40001',
      message = 'The replacement Admin changed during recovery. Refresh and try again.';
  end if;

  if (
    select count(*)
    from public.profiles
    where company_id = actor_company_id
      and lower(coalesce(role, '')) = 'owner'
  ) <> 1 then
    raise exception using
      errcode = '23514',
      message = 'Ownership recovery did not leave exactly one company Owner.';
  end if;

  insert into public.audit_log (
    company_id, user_id, action, table_name, record_id, old_data, new_data
  ) values (
    actor_company_id,
    actor.id,
    'company_ownership_recovered_by_admin',
    'profiles',
    replacement.id,
    jsonb_build_object(
      'owner_user_id', current_owner.id,
      'owner_role', 'owner',
      'owner_active', current_owner.active,
      'replacement_user_id', replacement.id,
      'replacement_role', 'admin'
    ),
    jsonb_build_object(
      'owner_user_id', replacement.id,
      'owner_role', 'owner',
      'previous_owner_user_id', current_owner.id,
      'previous_owner_role', requested_former_role,
      'performed_by_admin_user_id', actor.id
    )
  );
end;
$$;

revoke all on function public.linecrew_admin_replace_company_owner(uuid, uuid, text)
  from public, anon, authenticated;
grant execute on function public.linecrew_admin_replace_company_owner(uuid, uuid, text)
  to authenticated;

comment on function public.linecrew_admin_replace_company_owner(uuid, uuid, text) is
  'MFA-protected company-scoped recovery that lets an active Admin atomically replace the current Owner and choose the former Owner role.';

notify pgrst, 'reload schema';
