-- Utility Portal v4 security checkpoint: data model, crossover trigger, and
-- contractor identity-function guards. The rollout flag remains disabled.

create table public.utility_organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  active boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint utility_organizations_name_valid
    check (name = btrim(name) and length(name) >= 2)
);

create table public.utility_users (
  id uuid primary key default gen_random_uuid(),
  utility_organization_id uuid not null
    references public.utility_organizations(id) on delete cascade,
  invited_by_company_id uuid
    references public.companies(id) on delete restrict,
  user_id uuid references auth.users(id) on delete set null,
  email text not null,
  full_name text,
  status text not null,
  invite_token_hash text,
  invite_expires_at timestamptz,
  accepted_at timestamptz,
  last_sign_in_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint utility_users_email_normalized
    check (email = lower(btrim(email)) and length(email) >= 3),
  constraint utility_users_status_valid
    check (status in ('invited', 'active', 'revoked')),
  constraint utility_users_token_hash_valid
    check (invite_token_hash is null or invite_token_hash ~ '^[0-9a-f]{64}$'),
  constraint utility_users_active_identity_valid
    check (status <> 'active' or (user_id is not null and accepted_at is not null and invite_token_hash is null)),
  constraint utility_users_inviter_required
    check (status <> 'invited' or invited_by_company_id is not null)
);

create unique index utility_users_org_email_uidx
  on public.utility_users (utility_organization_id, lower(email));

create unique index utility_users_user_id_uidx
  on public.utility_users (user_id)
  where user_id is not null;

create table public.utility_contract_access (
  id uuid primary key default gen_random_uuid(),
  utility_organization_id uuid not null
    references public.utility_organizations(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  contract_id uuid not null references public.contracts(id) on delete cascade,
  show_quantities boolean not null default false,
  granted_by uuid not null references auth.users(id),
  granted_at timestamptz not null default now(),
  revoked_by uuid references auth.users(id) on delete set null,
  revoked_at timestamptz,
  expires_at timestamptz,
  status text not null,
  constraint utility_contract_access_status_valid
    check (status in ('active', 'revoked', 'expired'))
);

create unique index utility_contract_access_active_uidx
  on public.utility_contract_access (utility_organization_id, company_id, contract_id)
  where status = 'active';

create index utility_contract_access_contract_id_idx
  on public.utility_contract_access (contract_id);

create index utility_contract_access_company_id_idx
  on public.utility_contract_access (company_id);

create index utility_contract_access_org_id_idx
  on public.utility_contract_access (utility_organization_id);

create or replace function public.utility_enforce_contract_company_match()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if not exists (
    select 1
    from public.contracts contract
    where contract.id = new.contract_id
      and contract.company_id = new.company_id
  ) then
    raise exception using
      errcode = '23514',
      message = 'Contract does not belong to the specified company.';
  end if;
  return new;
end;
$function$;

create trigger utility_contract_access_company_match
before insert or update of company_id, contract_id
on public.utility_contract_access
for each row
execute function public.utility_enforce_contract_company_match();

create table public.utility_activity_log (
  id bigint generated always as identity primary key,
  utility_organization_id uuid
    references public.utility_organizations(id) on delete set null,
  -- Deliberately not a foreign key: this immutable audit subject identifier
  -- must survive cancellation deleting the pending utility_users row.
  utility_user_id uuid,
  actor_user_id uuid references auth.users(id) on delete set null,
  company_id uuid references public.companies(id) on delete set null,
  contract_id uuid references public.contracts(id) on delete set null,
  job_id uuid references public.jobs(id) on delete set null,
  action text not null,
  detail jsonb,
  created_at timestamptz not null default now(),
  constraint utility_activity_log_action_valid check (action in (
    'invite_sent', 'invite_resent', 'invite_cancelled', 'invite_accepted',
    'access_granted', 'access_changed', 'access_revoked',
    'job_entered_shared_contract', 'job_left_shared_contract',
    'sign_in', 'job_list_viewed', 'job_viewed'
  )),
  constraint utility_activity_log_detail_object
    check (detail is null or jsonb_typeof(detail) = 'object')
);

create index utility_activity_log_company_created_idx
  on public.utility_activity_log (company_id, created_at desc, id desc);

create index utility_activity_log_org_created_idx
  on public.utility_activity_log (utility_organization_id, created_at desc);

create index utility_activity_log_job_id_idx
  on public.utility_activity_log (job_id);

create or replace function public.utility_block_invitation_owner_change()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if new.invited_by_company_id is distinct from old.invited_by_company_id then
    raise exception using errcode = '42501', message = 'Access denied.';
  end if;
  return new;
end;
$function$;

create trigger utility_users_invitation_owner_immutable
before update of invited_by_company_id on public.utility_users
for each row execute function public.utility_block_invitation_owner_change();

alter table public.customers
  add column utility_organization_id uuid
    references public.utility_organizations(id) on delete set null;

create index customers_utility_organization_id_idx
  on public.customers (utility_organization_id)
  where utility_organization_id is not null;

alter table public.utility_organizations enable row level security;
alter table public.utility_users enable row level security;
alter table public.utility_contract_access enable row level security;
alter table public.utility_activity_log enable row level security;

create policy utility_organizations_contractor_read
  on public.utility_organizations
  for select to authenticated
  using (
    (select public.is_platform_owner())
    or exists (
      select 1
      from public.utility_contract_access access
      where access.utility_organization_id = utility_organizations.id
        and access.company_id = (select public.my_company_id())
        and access.status = 'active'
        and (access.expires_at is null or access.expires_at > now())
        and lower(coalesce((select public.my_role()), '')) in ('owner', 'admin')
    )
  );

create policy utility_users_contractor_read
  on public.utility_users
  for select to authenticated
  using (
    (select public.is_platform_owner())
    or exists (
      select 1
      from public.utility_contract_access access
      where access.utility_organization_id = utility_users.utility_organization_id
        and access.company_id = (select public.my_company_id())
        and access.status = 'active'
        and (access.expires_at is null or access.expires_at > now())
        and lower(coalesce((select public.my_role()), '')) in ('owner', 'admin')
    )
  );

create policy utility_contract_access_contractor_read
  on public.utility_contract_access
  for select to authenticated
  using (
    (select public.is_platform_owner())
    or (
      company_id = (select public.my_company_id())
      and lower(coalesce((select public.my_role()), '')) in ('owner', 'admin')
    )
  );

create policy utility_activity_log_contractor_read
  on public.utility_activity_log
  for select to authenticated
  using (
    (select public.is_platform_owner())
    or (
      company_id = (select public.my_company_id())
      and lower(coalesce((select public.my_role()), '')) in ('owner', 'admin')
    )
  );

-- Remove direct writes. Later contractor-only SECURITY DEFINER RPCs perform
-- atomic organization, invitation, grant, and audit mutations.
revoke insert, update, delete, truncate, references, trigger
  on public.utility_organizations,
     public.utility_users,
     public.utility_contract_access,
     public.utility_activity_log
  from public, anon, authenticated;

-- The token hash is never selectable. Safe utility-user columns are exposed
-- only to rows admitted by RLS for contractor Admin/Owner or platform owner.
revoke select on public.utility_users from public, anon, authenticated;
grant select (
  id, utility_organization_id, user_id, email, full_name, status,
  invite_expires_at, accepted_at, last_sign_in_at, created_at, updated_at
) on public.utility_users to authenticated;

revoke all on sequence public.utility_activity_log_id_seq from public, anon, authenticated;

create or replace function public.is_utility_user()
returns boolean
language sql
stable
security definer
set search_path to ''
as $function$
  select exists (
    select 1
    from public.utility_users utility_user
    where utility_user.user_id = auth.uid()
  );
$function$;

revoke all on function public.is_utility_user() from public, anon;
grant execute on function public.is_utility_user() to authenticated, service_role;

create or replace function public.utility_block_profile_insert()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if exists (
    select 1
    from public.utility_users utility_user
    where utility_user.user_id = new.id
  ) then
    raise exception using
      errcode = '42501',
      message = 'This action is not available.';
  end if;
  return new;
end;
$function$;

create trigger utility_identity_blocks_profile_insert
before insert on public.profiles
for each row
execute function public.utility_block_profile_insert();

-- Reverse crossover defence: no utility membership may attach to an existing
-- contractor identity. Invited rows have a null user_id and are unaffected.
create or replace function public.utility_block_contractor_identity()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if new.user_id is not null and exists (
    select 1 from public.profiles profile where profile.id = new.user_id
  ) then
    raise exception using errcode = '42501', message = 'This action is not available.';
  end if;
  return new;
end;
$function$;

create trigger contractor_identity_blocks_utility_membership
before insert or update of user_id on public.utility_users
for each row
execute function public.utility_block_contractor_identity();

create or replace function public.create_company(company_name text, admin_name text)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  new_company_id uuid;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if public.is_utility_user() then
    raise exception using errcode = '42501', message = 'This action is not available.';
  end if;

  if exists (select 1 from public.profiles where id = auth.uid()) then
    raise exception 'User already belongs to a company';
  end if;

  insert into public.companies(name, created_by)
  values (company_name, auth.uid())
  returning id into new_company_id;

  insert into public.profiles(id, company_id, full_name, role)
  values (auth.uid(), new_company_id, admin_name, 'admin');

  insert into public.company_settings(company_id, display_name)
  values (new_company_id, company_name);

  return new_company_id;
end;
$function$;

create or replace function public.join_company(company_code text, user_name text)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_company_id uuid;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in before joining a company.';
  end if;

  if public.is_utility_user() then
    raise exception using errcode = '42501', message = 'This action is not available.';
  end if;

  if nullif(btrim(company_code), '') is null or nullif(btrim(user_name), '') is null then
    raise exception using errcode = '22004', message = 'Company code and name are required.';
  end if;

  if exists (select 1 from public.profiles where id = auth.uid()) then
    raise exception using errcode = '23505', message = 'This account already belongs to a company.';
  end if;

  select id into v_company_id
  from public.companies
  where upper(btrim(join_code)) = upper(btrim(company_code))
  limit 1;

  if v_company_id is null then
    raise exception using errcode = 'P0002', message = 'Company code was not found.';
  end if;

  insert into public.profiles(id, company_id, full_name, role)
  values (auth.uid(), v_company_id, btrim(user_name), 'foreman');
end;
$function$;

create or replace function public.accept_team_invitation(p_token_hash text, p_user_name text)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  invitation public.team_invitations%rowtype;
  authenticated_email text;
  normalized_name text := btrim(coalesce(p_user_name, ''));
  v_role text;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Sign in before accepting an invitation.';
  end if;

  if public.is_utility_user() then
    raise exception using errcode = '42501', message = 'This action is not available.';
  end if;

  if coalesce(p_token_hash, '') !~ '^[0-9a-f]{64}$' then
    raise exception using errcode = '22023', message = 'Invalid invitation link.';
  end if;

  if length(normalized_name) < 2 or length(normalized_name) > 120 then
    raise exception using errcode = '22023', message = 'Enter your full name.';
  end if;

  if exists (select 1 from public.profiles where id = auth.uid()) then
    raise exception using errcode = '23505', message = 'This account already belongs to a company.';
  end if;

  select lower(email) into authenticated_email from auth.users where id = auth.uid();

  select * into invitation
  from public.team_invitations
  where token_hash = lower(p_token_hash)
    and accepted_at is null
    and expires_at > now()
  for update;

  if invitation.id is null then
    raise exception using errcode = 'P0002', message = 'This invitation is invalid, expired, or already used.';
  end if;

  if authenticated_email is null or authenticated_email <> lower(invitation.email) then
    raise exception using errcode = '42501', message = 'Sign in with the email address that received this invitation.';
  end if;

  v_role := lower(coalesce(invitation.intended_role, 'foreman'));
  if v_role not in ('foreman','gf','superintendent','admin','owner') then
    raise exception using errcode = '22023', message = 'Invalid invitation role.';
  end if;

  insert into public.profiles (id, company_id, full_name, role, active)
  values (auth.uid(), invitation.company_id, normalized_name, v_role, true);

  update public.team_invitations
  set accepted_at = now(), accepted_by = auth.uid()
  where id = invitation.id;
end;
$function$;

revoke all on function public.utility_enforce_contract_company_match() from public, anon, authenticated;
revoke all on function public.utility_block_invitation_owner_change() from public, anon, authenticated;
revoke all on function public.utility_block_profile_insert() from public, anon, authenticated;
revoke all on function public.utility_block_contractor_identity() from public, anon, authenticated;
