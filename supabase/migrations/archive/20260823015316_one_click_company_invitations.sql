begin;

create table if not exists public.team_invitations (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  email text not null,
  token_hash text not null unique,
  invited_by uuid references public.profiles(id) on delete set null,
  expires_at timestamptz not null,
  accepted_at timestamptz,
  accepted_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  constraint team_invitations_email_present check (length(btrim(email)) between 3 and 254),
  constraint team_invitations_token_hash_sha256 check (token_hash ~ '^[0-9a-f]{64}$')
);

alter table public.team_invitations enable row level security;
revoke all on table public.team_invitations from public, anon, authenticated;

create index if not exists team_invitations_company_email_pending_idx
  on public.team_invitations (company_id, lower(email), expires_at)
  where accepted_at is null;

create or replace function public.create_team_invitation(
  p_email text,
  p_token_hash text,
  p_expires_at timestamptz
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  actor public.profiles%rowtype;
  normalized_email text := lower(btrim(coalesce(p_email, '')));
  invitation_id uuid;
begin
  select * into actor
  from public.profiles
  where id = auth.uid();

  if actor.id is null or actor.active is not true then
    raise exception using errcode = '42501', message = 'Active company access required.';
  end if;

  if lower(actor.role) not in ('owner', 'admin') and not (
    lower(actor.role) = 'superintendent' and
    coalesce((actor.role_permissions ->> 'team_management')::boolean, true)
  ) then
    raise exception using errcode = '42501', message = 'Team invitation access denied.';
  end if;

  if normalized_email !~ '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' or
     length(normalized_email) > 254 then
    raise exception using errcode = '22023', message = 'Enter a valid email address.';
  end if;

  if coalesce(p_token_hash, '') !~ '^[0-9a-f]{64}$' then
    raise exception using errcode = '22023', message = 'Invalid invitation token.';
  end if;

  if p_expires_at <= now() + interval '5 minutes' or
     p_expires_at > now() + interval '7 days' then
    raise exception using errcode = '22023', message = 'Invalid invitation expiration.';
  end if;

  delete from public.team_invitations
  where company_id = actor.company_id
    and lower(email) = normalized_email
    and accepted_at is null;

  insert into public.team_invitations (
    company_id,
    email,
    token_hash,
    invited_by,
    expires_at
  ) values (
    actor.company_id,
    normalized_email,
    p_token_hash,
    actor.id,
    p_expires_at
  )
  returning id into invitation_id;

  return invitation_id;
end;
$$;

revoke all on function public.create_team_invitation(text, text, timestamptz) from public, anon;
grant execute on function public.create_team_invitation(text, text, timestamptz) to authenticated;

create or replace function public.accept_team_invitation(
  p_token_hash text,
  p_user_name text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  invitation public.team_invitations%rowtype;
  authenticated_email text;
  normalized_name text := btrim(coalesce(p_user_name, ''));
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
  from auth.users
  where id = auth.uid();

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

  insert into public.profiles (
    id,
    company_id,
    full_name,
    role,
    active
  ) values (
    auth.uid(),
    invitation.company_id,
    normalized_name,
    'foreman',
    true
  );

  update public.team_invitations
  set accepted_at = now(),
      accepted_by = auth.uid()
  where id = invitation.id;
end;
$$;

revoke all on function public.accept_team_invitation(text, text) from public, anon;
grant execute on function public.accept_team_invitation(text, text) to authenticated;

commit;
