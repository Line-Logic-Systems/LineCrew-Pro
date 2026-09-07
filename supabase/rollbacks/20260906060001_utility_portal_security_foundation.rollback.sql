-- Reverse order: 182620, 134013, 071452, 070834, 064624, 064002, 060001, 055947, 055940.
-- Restore the exact production-baseline onboarding bodies before removing the
-- utility identity helper they currently call.

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
  if coalesce(p_token_hash, '') !~ '^[0-9a-f]{64}$' then
    raise exception using errcode = '22023', message = 'Invalid invitation link.';
  end if;
  if length(normalized_name) < 2 or length(normalized_name) > 120 then
    raise exception using errcode = '22023', message = 'Enter your full name.';
  end if;
  if exists (select 1 from public.profiles where id = auth.uid()) then
    raise exception using errcode = '23505', message = 'This account already belongs to a company.';
  end if;

  select lower(email) into authenticated_email
  from auth.users where id = auth.uid();

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

drop trigger if exists utility_identity_blocks_profile_insert on public.profiles;
drop trigger if exists contractor_identity_blocks_utility_membership on public.utility_users;
drop trigger if exists utility_users_invitation_owner_immutable on public.utility_users;
drop trigger if exists utility_contract_access_company_match on public.utility_contract_access;

drop function if exists public.utility_block_profile_insert();
drop function if exists public.utility_block_contractor_identity();
drop function if exists public.utility_enforce_contract_company_match();
drop function if exists public.utility_block_invitation_owner_change();
drop function if exists public.is_utility_user();

alter table public.customers drop column if exists utility_organization_id;
drop table if exists public.utility_activity_log;
drop table if exists public.utility_contract_access;
drop table if exists public.utility_users;
drop table if exists public.utility_organizations;
