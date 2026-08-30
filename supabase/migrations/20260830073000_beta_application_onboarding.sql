begin;

create table if not exists public.beta_applications (
  id uuid primary key default gen_random_uuid(),
  company_name text not null,
  contact_name text not null,
  email text not null,
  phone text,
  active_crew_count integer not null,
  testing_notes text,
  status text not null default 'pending',
  submitted_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by uuid references auth.users(id) on delete set null,
  approved_company_id uuid references public.companies(id) on delete set null,
  invite_sent_at timestamptz,
  request_fingerprint_hash text,
  source text not null default 'website',
  constraint beta_applications_company_name_len check (char_length(btrim(company_name)) between 2 and 120),
  constraint beta_applications_contact_name_len check (char_length(btrim(contact_name)) between 2 and 120),
  constraint beta_applications_email_len check (char_length(btrim(email)) between 5 and 254),
  constraint beta_applications_phone_len check (phone is null or char_length(btrim(phone)) between 7 and 30),
  constraint beta_applications_crew_count check (active_crew_count between 1 and 500),
  constraint beta_applications_notes_len check (testing_notes is null or char_length(testing_notes) <= 2000),
  constraint beta_applications_status check (status in ('pending','approved','declined')),
  constraint beta_applications_fingerprint check (request_fingerprint_hash is null or request_fingerprint_hash ~ '^[0-9a-f]{64}$')
);

alter table public.beta_applications enable row level security;
revoke all on table public.beta_applications from public, anon, authenticated;
grant all on table public.beta_applications to service_role;

create unique index if not exists beta_applications_one_pending_email_idx
  on public.beta_applications (lower(email)) where status='pending';
create index if not exists beta_applications_status_submitted_idx
  on public.beta_applications (status, submitted_at desc);
create index if not exists beta_applications_fingerprint_submitted_idx
  on public.beta_applications (request_fingerprint_hash, submitted_at desc)
  where request_fingerprint_hash is not null;

alter table public.team_invitations
  add column if not exists intended_role text not null default 'foreman',
  add column if not exists intended_full_name text;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname='team_invitations_intended_role_check'
      and conrelid='public.team_invitations'::regclass
  ) then
    alter table public.team_invitations
      add constraint team_invitations_intended_role_check
      check (lower(intended_role) in ('foreman','gf','superintendent','admin','owner'));
  end if;
end $$;

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
$$;
revoke all on function public.accept_team_invitation(text, text) from public, anon;
grant execute on function public.accept_team_invitation(text, text) to authenticated;

create or replace function public.complete_team_invitation_signup()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  invitation public.team_invitations%rowtype;
  supplied_token_hash text := lower(coalesce(new.raw_user_meta_data ->> 'team_invitation_token_hash', ''));
  default_name text;
  v_role text;
begin
  if supplied_token_hash = '' then return new; end if;
  if supplied_token_hash !~ '^[0-9a-f]{64}$' then
    raise exception using errcode = '22023', message = 'Invalid team invitation.';
  end if;

  select * into invitation
  from public.team_invitations
  where token_hash = supplied_token_hash
    and lower(email) = lower(new.email)
    and accepted_at is null
    and expires_at > now()
  for update;

  if invitation.id is null then
    raise exception using errcode = 'P0002', message = 'This team invitation is invalid, expired, or belongs to another email address.';
  end if;

  default_name := btrim(coalesce(invitation.intended_full_name, ''));
  if length(default_name) < 2 then
    default_name := initcap(btrim(regexp_replace(split_part(new.email, '@', 1), '[^[:alnum:]]+', ' ', 'g')));
  end if;
  if length(default_name) < 2 then default_name := 'New User'; end if;

  v_role := lower(coalesce(invitation.intended_role, 'foreman'));
  if v_role not in ('foreman','gf','superintendent','admin','owner') then
    raise exception using errcode = '22023', message = 'Invalid team invitation role.';
  end if;

  insert into public.profiles (id, company_id, full_name, role, active)
  values (new.id, invitation.company_id, left(default_name, 120), v_role, true);

  update public.team_invitations
  set accepted_at = now(), accepted_by = new.id
  where id = invitation.id;
  return new;
end;
$$;
revoke all on function public.complete_team_invitation_signup() from public, anon, authenticated;
drop trigger if exists complete_team_invitation_signup on auth.users;
create trigger complete_team_invitation_signup
after insert on auth.users
for each row execute function public.complete_team_invitation_signup();

create or replace function public.platform_owner_beta_applications()
returns table (
  application_id uuid,
  company_name text,
  contact_name text,
  email text,
  phone text,
  active_crew_count integer,
  testing_notes text,
  status text,
  submitted_at timestamptz,
  reviewed_at timestamptz,
  approved_company_id uuid,
  invite_sent_at timestamptz
)
language plpgsql
security definer
set search_path = ''
stable
as $$
begin
  if not public.is_platform_owner() then
    raise exception using errcode='42501', message='Platform owner access required.';
  end if;
  return query
  select b.id, b.company_name, b.contact_name, b.email, b.phone, b.active_crew_count,
         b.testing_notes, b.status, b.submitted_at, b.reviewed_at, b.approved_company_id, b.invite_sent_at
  from public.beta_applications b
  order by case b.status when 'pending' then 0 when 'approved' then 1 else 2 end, b.submitted_at desc;
end;
$$;
revoke all on function public.platform_owner_beta_applications() from public, anon;
grant execute on function public.platform_owner_beta_applications() to authenticated;

create or replace function public.platform_owner_prepare_beta_company(
  p_application_id uuid,
  p_token_hash text,
  p_invite_expires_at timestamptz,
  p_pilot_ends_at timestamptz
)
returns table (company_id uuid, applicant_email text, applicant_name text)
language plpgsql
security definer
set search_path = ''
as $$
declare
  app public.beta_applications%rowtype;
  v_company_id uuid;
begin
  if not public.is_platform_owner() then
    raise exception using errcode='42501', message='Platform owner access required.';
  end if;
  if coalesce(p_token_hash,'') !~ '^[0-9a-f]{64}$' then
    raise exception using errcode='22023', message='Invalid invitation token.';
  end if;
  if p_invite_expires_at <= now() + interval '15 minutes' or p_invite_expires_at > now() + interval '7 days' then
    raise exception using errcode='22023', message='Invalid invitation expiration.';
  end if;
  if p_pilot_ends_at <= now() + interval '7 days' or p_pilot_ends_at > now() + interval '180 days' then
    raise exception using errcode='22023', message='Invalid pilot expiration.';
  end if;

  select * into app from public.beta_applications where id=p_application_id for update;
  if app.id is null then raise exception using errcode='P0002', message='Beta application not found.'; end if;
  if app.status <> 'pending' then raise exception using errcode='23514', message='Beta application has already been reviewed.'; end if;
  if exists(select 1 from public.companies c where lower(coalesce(c.contact_email,''))=lower(app.email)) then
    raise exception using errcode='23505', message='A company already exists for this contact email.';
  end if;

  insert into public.companies(name, contact_email, contact_phone, active)
  values (btrim(app.company_name), lower(btrim(app.email)), nullif(btrim(coalesce(app.phone,'')),''), true)
  returning id into v_company_id;

  update public.company_subscriptions cs
  set plan_code='pilot',
      monthly_price_cents=0,
      currency='usd',
      status='trialing',
      access_enabled=true,
      access_override=null,
      trial_ends_at=p_pilot_ends_at,
      provider='manual',
      notes='Approved Beta/Pilot company',
      updated_at=now()
  where cs.company_id=v_company_id;

  if not found then
    insert into public.company_subscriptions(company_id, plan_code, monthly_price_cents, currency, status, access_enabled, access_override, trial_ends_at, provider, notes)
    values (v_company_id, 'pilot', 0, 'usd', 'trialing', true, null, p_pilot_ends_at, 'manual', 'Approved Beta/Pilot company');
  end if;

  insert into public.team_invitations(company_id, email, token_hash, invited_by, expires_at, intended_role, intended_full_name)
  values (v_company_id, lower(btrim(app.email)), lower(p_token_hash), null, p_invite_expires_at, 'admin', left(btrim(app.contact_name),120));

  update public.beta_applications b
  set status='approved', reviewed_at=now(), reviewed_by=auth.uid(), approved_company_id=v_company_id
  where b.id=app.id;

  insert into public.platform_owner_audit_events(actor_user_id, company_id, action, before_state, after_state)
  values(auth.uid(), v_company_id, 'beta_application_approved', to_jsonb(app), jsonb_build_object('application_id',app.id,'plan_code','pilot','pilot_ends_at',p_pilot_ends_at));

  return query select v_company_id, lower(btrim(app.email)), btrim(app.contact_name);
end;
$$;
revoke all on function public.platform_owner_prepare_beta_company(uuid,text,timestamptz,timestamptz) from public, anon;
grant execute on function public.platform_owner_prepare_beta_company(uuid,text,timestamptz,timestamptz) to authenticated;

create or replace function public.platform_owner_mark_beta_invite_sent(p_application_id uuid)
returns void
language plpgsql
security definer
set search_path=''
as $$
begin
  if not public.is_platform_owner() then
    raise exception using errcode='42501', message='Platform owner access required.';
  end if;
  update public.beta_applications b
  set invite_sent_at=now()
  where b.id=p_application_id and b.status='approved';
  if not found then
    raise exception using errcode='P0002', message='Approved beta application not found.';
  end if;
end;
$$;
revoke all on function public.platform_owner_mark_beta_invite_sent(uuid) from public, anon;
grant execute on function public.platform_owner_mark_beta_invite_sent(uuid) to authenticated;

create or replace function public.platform_owner_decline_beta_application(p_application_id uuid)
returns void
language plpgsql
security definer
set search_path=''
as $$
declare
  app public.beta_applications%rowtype;
begin
  if not public.is_platform_owner() then
    raise exception using errcode='42501', message='Platform owner access required.';
  end if;
  select * into app from public.beta_applications where id=p_application_id for update;
  if app.id is null then raise exception using errcode='P0002', message='Beta application not found.'; end if;
  if app.status <> 'pending' then raise exception using errcode='23514', message='Beta application has already been reviewed.'; end if;

  update public.beta_applications b
  set status='declined', reviewed_at=now(), reviewed_by=auth.uid()
  where b.id=app.id;

  insert into public.platform_owner_audit_events(actor_user_id, company_id, action, before_state, after_state)
  values(auth.uid(), null, 'beta_application_declined', to_jsonb(app), jsonb_build_object('application_id',app.id,'status','declined'));
end;
$$;
revoke all on function public.platform_owner_decline_beta_application(uuid) from public, anon;
grant execute on function public.platform_owner_decline_beta_application(uuid) to authenticated;

commit;
