create or replace function public.linecrew_protect_owner_from_management_roles()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_actor_role text;
  v_authorized_transfer boolean := coalesce(current_setting('linecrew.owner_change_authorized', true),'off') = 'on';
begin
  if v_authorized_transfer then
    return new;
  end if;

  if auth.uid() is null or auth.uid() = old.id then
    return new;
  end if;

  select lower(coalesce(role,'')) into v_actor_role
  from public.profiles
  where id = auth.uid()
    and active is true;

  if v_actor_role = 'manager' and
     (lower(coalesce(old.role,'')) = 'owner' or lower(coalesce(new.role,'')) = 'owner') then
    raise exception using errcode='42501',
      message='Managers cannot change, suspend, replace or assign the company Owner.';
  end if;

  if v_actor_role in ('admin','manager') and
     (lower(coalesce(old.role,'')) in ('owner','manager') or lower(coalesce(new.role,'')) in ('owner','manager')) then
    raise exception using errcode='42501',
      message='Admins cannot change Owner or Manager accounts.';
  end if;

  return new;
end;
$$;

create or replace function public.linecrew_transfer_company_owner(target_admin_id uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  actor public.profiles%rowtype;
  target public.profiles%rowtype;
  actor_company_id uuid;
begin
  if target_admin_id is null or target_admin_id = auth.uid() then
    raise exception using errcode='22023',
      message='Choose another active Admin to receive ownership.';
  end if;

  select profile.* into actor
  from public.profiles profile
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where profile.id = auth.uid();

  if actor.id is null or actor.active is not true or lower(actor.role) <> 'owner' then
    raise exception using errcode='42501',
      message='Only the current active Owner can transfer company ownership.';
  end if;

  actor_company_id := actor.company_id;

  perform 1 from public.companies
  where id = actor_company_id and active is true
  for update;
  if not found then
    raise exception using errcode='42501', message='The company is not active.';
  end if;

  select * into actor
  from public.profiles
  where id = auth.uid() and company_id = actor_company_id
  for update;
  if actor.id is null or actor.active is not true or lower(actor.role) <> 'owner' then
    raise exception using errcode='40001',
      message='Ownership changed while the transfer was starting. Refresh and try again.';
  end if;

  select * into target
  from public.profiles
  where id = target_admin_id and company_id = actor_company_id
  for update;
  if target.id is null or target.active is not true or lower(target.role) <> 'admin' then
    raise exception using errcode='23514',
      message='Ownership can be transferred only to another active Admin in your company.';
  end if;

  perform set_config('linecrew.owner_change_authorized','on',true);

  update public.profiles
  set role='admin', role_permissions='{}'::jsonb
  where id=actor.id and company_id=actor_company_id and lower(coalesce(role,''))='owner';
  if not found then
    raise exception using errcode='40001',
      message='Ownership changed during transfer. Refresh and try again.';
  end if;

  update public.profiles
  set role='owner', role_permissions='{}'::jsonb
  where id=target.id and company_id=actor_company_id and active is true and lower(coalesce(role,''))='admin';
  if not found then
    raise exception using errcode='40001',
      message='The replacement Admin changed during transfer. Refresh and try again.';
  end if;

  perform set_config('linecrew.owner_change_authorized','off',true);

  if (select count(*) from public.profiles where company_id=actor_company_id and lower(coalesce(role,''))='owner') <> 1 then
    raise exception using errcode='23514',
      message='Ownership transfer did not leave exactly one company Owner.';
  end if;

  insert into public.audit_log(company_id,user_id,action,table_name,record_id,old_data,new_data)
  values(
    actor_company_id, actor.id, 'company_ownership_transferred', 'profiles', target.id,
    jsonb_build_object('owner_user_id',actor.id,'owner_role','owner','target_user_id',target.id,'target_role','admin'),
    jsonb_build_object('owner_user_id',target.id,'owner_role','owner','previous_owner_user_id',actor.id,'previous_owner_role','admin')
  );
end;
$$;

create or replace function public.linecrew_admin_replace_company_owner(current_owner_id uuid, replacement_admin_id uuid, former_owner_role text)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  actor public.profiles%rowtype;
  current_owner public.profiles%rowtype;
  replacement public.profiles%rowtype;
  actor_company_id uuid;
  requested_former_role text := lower(btrim(coalesce(former_owner_role,'')));
begin
  if current_owner_id is null or replacement_admin_id is null then
    raise exception using errcode='22004',
      message='Choose the current Owner and an active Admin to receive ownership.';
  end if;
  if current_owner_id = replacement_admin_id then
    raise exception using errcode='22023',
      message='The replacement Owner must be a different active Admin.';
  end if;
  if requested_former_role not in ('foreman','gf','superintendent','admin') then
    raise exception using errcode='22023',
      message='Choose Admin, Superintendent, General Foreman, or Foreman for the former Owner.';
  end if;
  if coalesce((select auth.jwt() ->> 'aal'),'aal1') <> 'aal2' then
    raise exception using errcode='42501',
      message='Complete authenticator verification before recovering company ownership.';
  end if;

  select profile.* into actor
  from public.profiles profile
  join public.companies company
    on company.id=profile.company_id and company.active is true
  where profile.id=auth.uid();

  if actor.id is null or actor.active is not true or lower(coalesce(actor.role,'')) <> 'admin' then
    raise exception using errcode='42501',
      message='Only an active Admin can use ownership recovery.';
  end if;
  if actor.id = replacement_admin_id then
    raise exception using errcode='42501',
      message='An Admin cannot nominate themselves as replacement Owner.';
  end if;

  actor_company_id := actor.company_id;

  perform 1 from public.companies
  where id=actor_company_id and active is true
  for update;
  if not found then
    raise exception using errcode='42501', message='The company is not active.';
  end if;

  select * into actor
  from public.profiles
  where id=auth.uid() and company_id=actor_company_id
  for update;
  if actor.id is null or actor.active is not true or lower(coalesce(actor.role,'')) <> 'admin' then
    raise exception using errcode='40001',
      message='Your role or access changed while ownership recovery was starting. Refresh and try again.';
  end if;

  select * into current_owner
  from public.profiles
  where id=current_owner_id and company_id=actor_company_id
  for update;
  if current_owner.id is null or lower(coalesce(current_owner.role,'')) <> 'owner' then
    raise exception using errcode='23514',
      message='The selected person is no longer the Owner of your company. Refresh and try again.';
  end if;
  if current_owner.active is true then
    raise exception using errcode='42501',
      message='Ownership recovery is available only when the current Owner is inactive. An active Owner must transfer ownership themselves.';
  end if;

  select * into replacement
  from public.profiles
  where id=replacement_admin_id and company_id=actor_company_id
  for update;
  if replacement.id is null or replacement.active is not true or lower(coalesce(replacement.role,'')) <> 'admin' then
    raise exception using errcode='23514',
      message='Ownership recovery requires a different active Admin from your company.';
  end if;

  perform set_config('linecrew.owner_change_authorized','on',true);

  update public.profiles
  set role=requested_former_role, role_permissions='{}'::jsonb
  where id=current_owner.id and company_id=actor_company_id and lower(coalesce(role,''))='owner' and active is not true;
  if not found then
    raise exception using errcode='40001',
      message='Ownership changed during recovery. Refresh and try again.';
  end if;

  update public.profiles
  set role='owner', role_permissions='{}'::jsonb
  where id=replacement.id and company_id=actor_company_id and active is true and lower(coalesce(role,''))='admin';
  if not found then
    raise exception using errcode='40001',
      message='The replacement Admin changed during recovery. Refresh and try again.';
  end if;

  perform set_config('linecrew.owner_change_authorized','off',true);

  if (select count(*) from public.profiles where company_id=actor_company_id and lower(coalesce(role,''))='owner') <> 1 then
    raise exception using errcode='23514',
      message='Ownership recovery did not leave exactly one company Owner.';
  end if;

  insert into public.audit_log(company_id,user_id,action,table_name,record_id,old_data,new_data)
  values(
    actor_company_id, actor.id, 'company_ownership_recovered_by_admin', 'profiles', replacement.id,
    jsonb_build_object('owner_user_id',current_owner.id,'owner_role','owner','owner_active',current_owner.active,'replacement_user_id',replacement.id,'replacement_role','admin'),
    jsonb_build_object('owner_user_id',replacement.id,'owner_role','owner','previous_owner_user_id',current_owner.id,'previous_owner_role',requested_former_role,'performed_by_admin_user_id',actor.id)
  );
end;
$$;

revoke all on function public.linecrew_transfer_company_owner(uuid) from public, anon;
grant execute on function public.linecrew_transfer_company_owner(uuid) to authenticated, service_role;
revoke all on function public.linecrew_admin_replace_company_owner(uuid,uuid,text) from public, anon;
grant execute on function public.linecrew_admin_replace_company_owner(uuid,uuid,text) to authenticated, service_role;
