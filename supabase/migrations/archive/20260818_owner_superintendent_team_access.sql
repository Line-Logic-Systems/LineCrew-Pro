-- LineCrew Pro team access hierarchy for Owner/Admin/Superintendent.
-- Apply after 20260818_owner_superintendent_roles.sql.

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
  actor_role text;
  target_role text;
begin
  if p_member_id is null or p_active is null then
    raise exception using errcode = '22004', message = 'Team member and access status are required.';
  end if;

  select * into actor from public.profiles where id = auth.uid();
  if actor.id is null or actor.active is not true then
    raise exception using errcode = '42501', message = 'Active company leadership access is required.';
  end if;

  actor_role := lower(coalesce(actor.role, ''));
  if actor_role not in ('owner','admin','superintendent') then
    raise exception using errcode = '42501', message = 'Company leadership access is required.';
  end if;
  if actor_role = 'superintendent'
     and coalesce((actor.role_permissions ->> 'team_management')::boolean, true) is not true then
    raise exception using errcode = '42501', message = 'Team access management is disabled for this Superintendent.';
  end if;

  if p_member_id = auth.uid() then
    raise exception using errcode = '42501', message = 'You cannot suspend your own account.';
  end if;

  select * into target
  from public.profiles
  where id = p_member_id and company_id = actor.company_id
  for update;
  if target.id is null then
    raise exception using errcode = 'P0002', message = 'Team member was not found in your company.';
  end if;

  target_role := lower(coalesce(target.role, ''));

  if actor_role = 'admin' and target_role in ('owner','admin') then
    raise exception using errcode = '42501', message = 'Only an Owner can change Owner or Admin account access.';
  end if;

  if actor_role = 'superintendent' and target_role not in ('foreman','gf') then
    raise exception using errcode = '42501', message = 'A Superintendent can change access for General Foremen and Foremen only.';
  end if;

  if p_active is false and target_role = 'owner' then
    if not exists (
      select 1 from public.profiles
      where company_id = actor.company_id
        and id <> target.id
        and lower(coalesce(role,'')) = 'owner'
        and active is true
    ) then
      raise exception using errcode = '23514', message = 'Assign another active Owner before suspending the last Owner.';
    end if;
  end if;

  update public.profiles
  set active = p_active
  where id = target.id and company_id = actor.company_id;
end;
$$;

revoke all on function public.set_company_member_active(uuid, boolean) from public;
revoke all on function public.set_company_member_active(uuid, boolean) from anon;
grant execute on function public.set_company_member_active(uuid, boolean) to authenticated;
