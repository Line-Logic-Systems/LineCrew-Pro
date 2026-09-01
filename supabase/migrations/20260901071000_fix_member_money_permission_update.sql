-- Use scalar authorization values and assert the exact target row update.
create or replace function public.linecrew_set_member_money_permissions(
  target_user_id uuid,
  can_see_actual boolean,
  can_see_field boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_company_id uuid;
  v_actor_role text;
  v_actor_active boolean;
  v_target_role text;
  v_updated integer;
begin
  if target_user_id is null or can_see_actual is null or can_see_field is null then
    raise exception using
      errcode = '22004',
      message = 'Team member and both money visibility choices are required.';
  end if;

  select profile.company_id, lower(coalesce(profile.role,'')), profile.active
  into v_actor_company_id, v_actor_role, v_actor_active
  from public.profiles profile
  where profile.id = auth.uid()
  for update;

  if v_actor_company_id is null or v_actor_active is not true or
     v_actor_role not in ('owner','admin') then
    raise exception using
      errcode = '42501',
      message = 'Active Owner or Admin access is required.';
  end if;

  select lower(coalesce(profile.role,''))
  into v_target_role
  from public.profiles profile
  where profile.id = target_user_id
    and profile.company_id = v_actor_company_id
  for update;

  if v_target_role is null then
    raise exception using
      errcode = 'P0002',
      message = 'Team member was not found in your company.';
  end if;
  if v_target_role not in ('foreman','gf','superintendent') then
    raise exception using
      errcode = '42501',
      message = 'Money visibility can be changed only for Foremen, General Foremen and Superintendents.';
  end if;

  update public.profiles profile
  set role_permissions = coalesce(profile.role_permissions, '{}'::jsonb) ||
    jsonb_build_object(
      'actual_pricing', can_see_actual,
      'field_pricing', can_see_field
    )
  where profile.id = target_user_id
    and profile.company_id = v_actor_company_id;
  get diagnostics v_updated = row_count;

  if v_updated <> 1 then
    raise exception using
      errcode = '40001',
      message = 'Money visibility was not saved. Refresh Team and try again.';
  end if;
end;
$$;

revoke all on function public.linecrew_set_member_money_permissions(uuid,boolean,boolean)
  from public, anon;
grant execute on function public.linecrew_set_member_money_permissions(uuid,boolean,boolean)
  to authenticated;
