begin;

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
begin
  if supplied_token_hash = '' then
    return new;
  end if;

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

  default_name := initcap(btrim(regexp_replace(split_part(new.email, '@', 1), '[^[:alnum:]]+', ' ', 'g')));
  if length(default_name) < 2 then
    default_name := 'New Foreman';
  end if;

  insert into public.profiles (id, company_id, full_name, role, active)
  values (new.id, invitation.company_id, left(default_name, 120), 'foreman', true);

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
for each row
execute function public.complete_team_invitation_signup();

commit;
