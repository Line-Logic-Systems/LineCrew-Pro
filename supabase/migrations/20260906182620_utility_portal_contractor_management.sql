-- Utility Portal R1 contractor-management checkpoint.
-- All public entry points fail closed, derive company identity from auth.uid(),
-- use the existing customers_contracts capability, and write audit state in the
-- same transaction as the mutation.

create or replace function public.utility_require_contractor_manager()
returns uuid
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_company_id uuid;
begin
  select profile.company_id into v_company_id
  from public.profiles profile
  where profile.id = auth.uid()
    and profile.active is true
    and lower(profile.role) in ('owner', 'admin');

  if v_company_id is null
     or not public.linecrew_has_capability('customers_contracts') then
    raise exception using errcode = '42501', message = 'This action is not available.';
  end if;

  return v_company_id;
end;
$function$;

revoke all on function public.utility_require_contractor_manager()
  from public, anon, authenticated, service_role;

create or replace function public.utility_require_portal_enabled(p_company_id uuid)
returns void
language plpgsql
stable
security definer
set search_path to ''
as $function$
begin
  if not public.linecrew_company_access_enabled(p_company_id)
     or not exists (
       select 1 from public.utility_portal_feature_flags flag
       where flag.company_id is null and flag.enabled is true
     )
     or not exists (
       select 1 from public.utility_portal_feature_flags flag
       where flag.company_id = p_company_id and flag.enabled is true
     ) then
    raise exception using errcode = '42501', message = 'This action is not available.';
  end if;
end;
$function$;

revoke all on function public.utility_require_portal_enabled(uuid)
  from public, anon, authenticated, service_role;

create or replace function public.utility_create_organization_with_grants(
  p_name text,
  p_contract_ids uuid[],
  p_show_quantities boolean[]
)
returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_company_id uuid := public.utility_require_contractor_manager();
  v_organization_id uuid;
  v_contract_id uuid;
  v_show boolean;
  v_index integer;
begin
  perform public.utility_require_portal_enabled(v_company_id);
  if btrim(coalesce(p_name, '')) = ''
     or coalesce(cardinality(p_contract_ids), 0) = 0
     or cardinality(p_contract_ids) > 200
     or p_show_quantities is null
     or cardinality(p_contract_ids) <> cardinality(p_show_quantities)
     or cardinality(p_contract_ids) <> (
       select count(distinct value) from unnest(p_contract_ids) value
     ) then
    raise exception using errcode = '22023', message = 'Invalid organization grants.';
  end if;

  if exists (
    select 1 from unnest(p_contract_ids) contract_id
    where contract_id is null or not exists (
      select 1 from public.contracts contract
      where contract.id = contract_id and contract.company_id = v_company_id
    )
  ) then
    raise exception using errcode = '42501', message = 'Access denied.';
  end if;

  insert into public.utility_organizations(name, created_by)
  values (btrim(p_name), auth.uid())
  returning id into v_organization_id;

  for v_index in 1..cardinality(p_contract_ids) loop
    v_contract_id := p_contract_ids[v_index];
    v_show := p_show_quantities[v_index];
    insert into public.utility_contract_access(
      utility_organization_id, company_id, contract_id, show_quantities,
      granted_by, status
    ) values (
      v_organization_id, v_company_id, v_contract_id, coalesce(v_show, false),
      auth.uid(), 'active'
    );
    insert into public.utility_activity_log(
      utility_organization_id, actor_user_id, company_id, contract_id, action, detail
    ) values (
      v_organization_id, auth.uid(), v_company_id, v_contract_id, 'access_granted',
      jsonb_build_object('show_quantities', coalesce(v_show, false))
    );
  end loop;

  insert into public.audit_log(company_id, user_id, action, table_name, record_id, new_data)
  values (v_company_id, auth.uid(), 'utility_organization_created',
          'utility_organizations', v_organization_id,
          jsonb_build_object('name', btrim(p_name), 'contract_count', cardinality(p_contract_ids)));
  return v_organization_id;
end;
$function$;

create or replace function public.utility_add_contract_grants(
  p_organization_id uuid,
  p_contract_ids uuid[],
  p_show_quantities boolean[]
)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_company_id uuid := public.utility_require_contractor_manager();
  v_index integer;
  v_grant_id uuid;
begin
  perform public.utility_require_portal_enabled(v_company_id);
  if p_organization_id is null
     or coalesce(cardinality(p_contract_ids), 0) = 0
     or cardinality(p_contract_ids) > 200
     or p_show_quantities is null
     or cardinality(p_contract_ids) <> cardinality(p_show_quantities)
     or cardinality(p_contract_ids) <> (select count(distinct value) from unnest(p_contract_ids) value)
     or not exists (
       select 1 from public.utility_contract_access access
       where access.utility_organization_id = p_organization_id
         and access.company_id = v_company_id
         and access.status = 'active'
         and (access.expires_at is null or access.expires_at > now())
     )
     or exists (
       select 1 from unnest(p_contract_ids) contract_id
       where contract_id is null or not exists (
         select 1 from public.contracts contract
         where contract.id = contract_id and contract.company_id = v_company_id
       )
     ) then
    raise exception using errcode = '42501', message = 'Access denied.';
  end if;

  if exists (
    select 1
    from public.utility_contract_access access
    join unnest(p_contract_ids) requested(contract_id)
      on requested.contract_id = access.contract_id
    where access.utility_organization_id = p_organization_id
      and access.company_id = v_company_id
      and access.status = 'active'
  ) then
    raise exception using errcode = '42501', message = 'Access denied.';
  end if;

  for v_index in 1..cardinality(p_contract_ids) loop
    begin
      insert into public.utility_contract_access(
        utility_organization_id, company_id, contract_id, show_quantities,
        granted_by, status
      ) values (
        p_organization_id, v_company_id, p_contract_ids[v_index],
        coalesce(p_show_quantities[v_index], false), auth.uid(), 'active'
      ) returning id into v_grant_id;
    exception
      when unique_violation then
        raise exception using errcode = '42501', message = 'Access denied.';
    end;

    insert into public.utility_activity_log(
      utility_organization_id, actor_user_id, company_id, contract_id, action, detail
    ) values (
      p_organization_id, auth.uid(), v_company_id, p_contract_ids[v_index],
      'access_granted', jsonb_build_object('show_quantities', coalesce(p_show_quantities[v_index], false))
    );
    insert into public.audit_log(company_id, user_id, action, table_name, record_id, new_data)
    values (v_company_id, auth.uid(), 'utility_access_granted',
            'utility_contract_access', v_grant_id,
            jsonb_build_object('organization_id', p_organization_id,
                               'contract_id', p_contract_ids[v_index],
                               'show_quantities', coalesce(p_show_quantities[v_index], false)));
  end loop;
end;
$function$;

create or replace function public.utility_revoke_contract_grant(p_grant_id uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_company_id uuid := public.utility_require_contractor_manager();
  v_grant public.utility_contract_access%rowtype;
begin
  perform public.utility_require_portal_enabled(v_company_id);
  select * into v_grant from public.utility_contract_access access
  where access.id = p_grant_id and access.company_id = v_company_id
    and access.status = 'active'
  for update;
  if v_grant.id is null then
    raise exception using errcode = '42501', message = 'Access denied.';
  end if;

  update public.utility_contract_access
  set status = 'revoked', revoked_by = auth.uid(), revoked_at = now()
  where id = v_grant.id;
  insert into public.utility_activity_log(
    utility_organization_id, actor_user_id, company_id, contract_id, action
  ) values (v_grant.utility_organization_id, auth.uid(), v_company_id,
            v_grant.contract_id, 'access_revoked');
  insert into public.audit_log(company_id, user_id, action, table_name, record_id, old_data, new_data)
  values (v_company_id, auth.uid(), 'utility_access_revoked', 'utility_contract_access',
          v_grant.id, to_jsonb(v_grant), jsonb_build_object('status', 'revoked'));
end;
$function$;

create or replace function public.utility_set_grant_show_quantities(
  p_grant_id uuid,
  p_show_quantities boolean
)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_company_id uuid := public.utility_require_contractor_manager();
  v_grant public.utility_contract_access%rowtype;
begin
  perform public.utility_require_portal_enabled(v_company_id);
  select * into v_grant from public.utility_contract_access access
  where access.id = p_grant_id and access.company_id = v_company_id
    and access.status = 'active'
  for update;
  if v_grant.id is null or p_show_quantities is null then
    raise exception using errcode = '42501', message = 'Access denied.';
  end if;

  update public.utility_contract_access
  set show_quantities = p_show_quantities where id = v_grant.id;
  insert into public.utility_activity_log(
    utility_organization_id, actor_user_id, company_id, contract_id, action, detail
  ) values (v_grant.utility_organization_id, auth.uid(), v_company_id,
            v_grant.contract_id, 'access_changed',
            jsonb_build_object('show_quantities', p_show_quantities));
  insert into public.audit_log(company_id, user_id, action, table_name, record_id, old_data, new_data)
  values (v_company_id, auth.uid(), 'utility_access_changed', 'utility_contract_access',
          v_grant.id, jsonb_build_object('show_quantities', v_grant.show_quantities),
          jsonb_build_object('show_quantities', p_show_quantities));
end;
$function$;

create or replace function public.utility_upsert_invitation(
  p_organization_id uuid,
  p_email text,
  p_full_name text,
  p_token_hash text,
  p_expires_at timestamptz
)
returns uuid
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_company_id uuid := public.utility_require_contractor_manager();
  v_user_id uuid;
  v_action text := 'invite_sent';
begin
  perform public.utility_require_portal_enabled(v_company_id);
  if p_email is null or lower(btrim(p_email)) !~ '^[^@[:space:]]+@[^@[:space:]]+$'
     or p_token_hash !~ '^[0-9a-f]{64}$' or p_expires_at <= now()
     or not exists (
       select 1 from public.utility_contract_access access
       where access.utility_organization_id = p_organization_id
         and access.company_id = v_company_id and access.status = 'active'
         and (access.expires_at is null or access.expires_at > now())
     ) then
    raise exception using errcode = '42501', message = 'Access denied.';
  end if;

  select utility_user.id into v_user_id
  from public.utility_users utility_user
  where utility_user.utility_organization_id = p_organization_id
    and utility_user.email = lower(btrim(p_email))
  for update;

  if v_user_id is null then
    insert into public.utility_users(
      utility_organization_id, invited_by_company_id, email, full_name, status,
      invite_token_hash, invite_expires_at
    ) values (
      p_organization_id, v_company_id, lower(btrim(p_email)), nullif(btrim(p_full_name), ''),
      'invited', p_token_hash, p_expires_at
    ) returning id into v_user_id;
  else
    if not exists (
      select 1 from public.utility_users utility_user
      where utility_user.id = v_user_id
        and utility_user.status = 'invited'
        and utility_user.invited_by_company_id = v_company_id
    ) then
      raise exception using errcode = '42501', message = 'Access denied.';
    end if;
    v_action := 'invite_resent';
    update public.utility_users
    set full_name = coalesce(nullif(btrim(p_full_name), ''), full_name),
        invite_token_hash = p_token_hash, invite_expires_at = p_expires_at,
        updated_at = now()
    where id = v_user_id;
  end if;

  insert into public.utility_activity_log(
    utility_organization_id, utility_user_id, actor_user_id, company_id, action
  ) values (p_organization_id, v_user_id, auth.uid(), v_company_id, v_action);
  insert into public.audit_log(company_id, user_id, action, table_name, record_id, new_data)
  values (v_company_id, auth.uid(), v_action, 'utility_users', v_user_id,
          jsonb_build_object('organization_id', p_organization_id,
                             'email', lower(btrim(p_email)),
                             'expires_at', p_expires_at));
  return v_user_id;
end;
$function$;

create or replace function public.utility_cancel_invitation(p_utility_user_id uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_company_id uuid := public.utility_require_contractor_manager();
  v_invitation public.utility_users%rowtype;
begin
  perform public.utility_require_portal_enabled(v_company_id);
  select * into v_invitation from public.utility_users utility_user
  where utility_user.id = p_utility_user_id and utility_user.status = 'invited'
    and utility_user.invited_by_company_id = v_company_id
  for update;
  if v_invitation.id is null then
    raise exception using errcode = '42501', message = 'Access denied.';
  end if;

  insert into public.utility_activity_log(
    utility_organization_id, utility_user_id, actor_user_id, company_id, action, detail
  ) values (v_invitation.utility_organization_id, v_invitation.id,
            auth.uid(), v_company_id, 'invite_cancelled',
            jsonb_build_object('utility_user_id', v_invitation.id,
                               'email', v_invitation.email));
  delete from public.utility_users where id = v_invitation.id;
  insert into public.audit_log(company_id, user_id, action, table_name, record_id, old_data, new_data)
  values (v_company_id, auth.uid(), 'invite_cancelled', 'utility_users', v_invitation.id,
          jsonb_build_object('status', v_invitation.status), jsonb_build_object('status', 'deleted'));
end;
$function$;

-- Accepted membership is organization-global. Only a platform owner may revoke
-- it, preventing one contractor from disabling a representative for every
-- contractor that shares the cooperative.
create or replace function public.utility_revoke_representative(p_utility_user_id uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_representative public.utility_users%rowtype;
begin
  if not public.is_platform_owner()
     or coalesce((select auth.jwt()->>'aal'), 'aal1') <> 'aal2'
     or not exists (
       select 1 from public.utility_portal_feature_flags flag
       where flag.company_id is null and flag.enabled is true
     ) then
    raise exception using errcode = '42501', message = 'Access denied.';
  end if;
  select * into v_representative from public.utility_users utility_user
  where utility_user.id = p_utility_user_id and utility_user.status = 'active'
  for update;
  if v_representative.id is null then
    raise exception using errcode = '42501', message = 'Access denied.';
  end if;
  update public.utility_users
  set status = 'revoked', updated_at = now() where id = v_representative.id;
  insert into public.utility_activity_log(
    utility_organization_id, utility_user_id, actor_user_id, action
  ) values (v_representative.utility_organization_id, v_representative.id,
            auth.uid(), 'access_revoked');
  insert into public.platform_owner_audit_events(
    actor_user_id, action, before_state, after_state
  ) values (
    auth.uid(), 'utility_representative_revoked',
    jsonb_build_object('utility_user_id', v_representative.id,
                       'status', v_representative.status),
    jsonb_build_object('utility_user_id', v_representative.id,
                       'status', 'revoked')
  );
end;
$function$;

-- Revocation is reversible only by another MFA-verified platform owner. This
-- avoids orphaning an existing Auth identity or allowing a contractor to
-- reactivate an organization-global membership.
create or replace function public.utility_restore_representative(p_utility_user_id uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_representative public.utility_users%rowtype;
begin
  if not public.is_platform_owner()
     or coalesce((select auth.jwt()->>'aal'), 'aal1') <> 'aal2'
     or not exists (
       select 1 from public.utility_portal_feature_flags flag
       where flag.company_id is null and flag.enabled is true
     ) then
    raise exception using errcode = '42501', message = 'Access denied.';
  end if;
  select * into v_representative from public.utility_users utility_user
  where utility_user.id = p_utility_user_id
    and utility_user.status = 'revoked'
    and utility_user.user_id is not null
    and utility_user.accepted_at is not null
  for update;
  if v_representative.id is null then
    raise exception using errcode = '42501', message = 'Access denied.';
  end if;
  update public.utility_users set status = 'active', updated_at = now()
  where id = v_representative.id;
  insert into public.platform_owner_audit_events(actor_user_id, action, before_state, after_state)
  values (auth.uid(), 'utility_representative_restored',
          jsonb_build_object('utility_user_id', v_representative.id, 'status', 'revoked'),
          jsonb_build_object('utility_user_id', v_representative.id, 'status', 'active'));
end;
$function$;

revoke all on function public.utility_create_organization_with_grants(text, uuid[], boolean[]),
  public.utility_add_contract_grants(uuid, uuid[], boolean[]),
  public.utility_revoke_contract_grant(uuid),
  public.utility_set_grant_show_quantities(uuid, boolean),
  public.utility_upsert_invitation(uuid, text, text, text, timestamptz),
  public.utility_cancel_invitation(uuid),
  public.utility_revoke_representative(uuid),
  public.utility_restore_representative(uuid)
  from public, anon, authenticated, service_role;

grant execute on function public.utility_create_organization_with_grants(text, uuid[], boolean[]),
  public.utility_add_contract_grants(uuid, uuid[], boolean[]),
  public.utility_revoke_contract_grant(uuid),
  public.utility_set_grant_show_quantities(uuid, boolean),
  public.utility_upsert_invitation(uuid, text, text, text, timestamptz),
  public.utility_cancel_invitation(uuid)
  to authenticated;

-- The Edge Function invokes utility_upsert_invitation with the initiating
-- manager's JWT. That preserves auth.uid()-derived company isolation; the raw
-- token is minted and retained only by the Edge Function.

grant execute on function public.utility_revoke_representative(uuid)
  to authenticated, service_role;
grant execute on function public.utility_restore_representative(uuid)
  to authenticated, service_role;

create or replace function public.utility_list_organizations(
  p_include_inactive boolean default false
)
returns table(
  organization_id uuid,
  organization_name text,
  active boolean,
  active_grant_count integer,
  total_grant_count integer,
  invited_representative_count integer,
  active_representative_count integer,
  revoked_representative_count integer,
  earliest_granted_at timestamptz,
  latest_granted_at timestamptz
)
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_company_id uuid;
begin
  v_company_id := public.utility_require_contractor_manager();
  perform public.utility_require_portal_enabled(v_company_id);
  return query
  select organization.id, organization.name, organization.active,
         count(*) filter (
           where access.status = 'active'
             and (access.expires_at is null or access.expires_at > now())
         )::integer,
         count(*)::integer,
         case when bool_or(
           access.status = 'active'
           and (access.expires_at is null or access.expires_at > now())
         ) then (select count(*)::integer from public.utility_users representative
          where representative.utility_organization_id = organization.id
            and representative.status = 'invited') else 0 end,
         case when bool_or(
           access.status = 'active'
           and (access.expires_at is null or access.expires_at > now())
         ) then (select count(*)::integer from public.utility_users representative
          where representative.utility_organization_id = organization.id
            and representative.status = 'active') else 0 end,
         case when bool_or(
           access.status = 'active'
           and (access.expires_at is null or access.expires_at > now())
         ) then (select count(*)::integer from public.utility_users representative
          where representative.utility_organization_id = organization.id
            and representative.status = 'revoked') else 0 end,
         min(access.granted_at), max(access.granted_at)
  from public.utility_contract_access access
  join public.utility_organizations organization
    on organization.id = access.utility_organization_id
  where access.company_id = v_company_id
  group by organization.id, organization.name, organization.active
  having coalesce(p_include_inactive, false)
      or count(*) filter (
        where access.status = 'active'
          and (access.expires_at is null or access.expires_at > now())
      ) > 0
  order by organization.name, organization.id;
end;
$function$;

create or replace function public.utility_list_representatives(
  p_utility_organization_id uuid
)
returns table(
  representative_id uuid,
  email text,
  full_name text,
  status text,
  invite_expires_at timestamptz,
  accepted_at timestamptz,
  last_sign_in_at timestamptz,
  created_at timestamptz,
  invited_by_this_company boolean
)
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_company_id uuid;
begin
  v_company_id := public.utility_require_contractor_manager();
  perform public.utility_require_portal_enabled(v_company_id);
  if not exists (
    select 1 from public.utility_contract_access access
    where access.company_id = v_company_id
      and access.utility_organization_id = p_utility_organization_id
      and access.status = 'active'
      and (access.expires_at is null or access.expires_at > now())
  ) then
    return;
  end if;
  return query
  select representative.id, representative.email, representative.full_name,
         representative.status, representative.invite_expires_at,
         representative.accepted_at, representative.last_sign_in_at,
         representative.created_at,
         representative.invited_by_company_id = v_company_id
  from public.utility_users representative
  where representative.utility_organization_id = p_utility_organization_id
  order by representative.created_at, representative.id;
end;
$function$;

create or replace function public.utility_contract_visibility_state(
  p_utility_organization_id uuid default null,
  p_contract_id uuid default null
)
returns table(
  grant_id uuid,
  utility_organization_id uuid,
  contract_id uuid,
  is_visible boolean,
  hidden_reasons text[],
  show_quantities boolean,
  expires_at timestamptz
)
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_company_id uuid;
begin
  v_company_id := public.utility_require_contractor_manager();
  return query
  select access.id, access.utility_organization_id, access.contract_id,
         cardinality(reason.reasons) = 0,
         reason.reasons,
         access.show_quantities,
         access.expires_at
  from public.utility_contract_access access
  cross join lateral (
    select public.utility_grant_hidden_reasons(
      access.utility_organization_id, access.id
    ) as reasons
  ) reason
  where access.company_id = v_company_id
    and (p_utility_organization_id is null
         or access.utility_organization_id = p_utility_organization_id)
    and (p_contract_id is null or access.contract_id = p_contract_id)
  order by access.granted_at desc, access.id desc;
end;
$function$;

create or replace function public.utility_activity_feed(
  p_before_created_at timestamptz default null,
  p_before_id bigint default null,
  p_limit integer default 50
)
returns table(
  activity_id bigint,
  occurred_at timestamptz,
  action text,
  actor_name text,
  organization_name text,
  contract_name text,
  job_number text,
  detail jsonb
)
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_company_id uuid;
  v_limit integer := coalesce(p_limit, 50);
begin
  v_company_id := public.utility_require_contractor_manager();
  perform public.utility_require_portal_enabled(v_company_id);
  if v_limit < 1 or v_limit > 100
     or ((p_before_created_at is null) <> (p_before_id is null)) then
    raise exception using errcode = '22023', message = 'Invalid activity feed cursor.';
  end if;
  return query
  select log.id, log.created_at, log.action,
         case when actor.id is not null then actor.full_name
              else coalesce(utility_actor.full_name, utility_actor.email) end,
         organization.name, contract.contract_name, job.job_number, log.detail
  from public.utility_activity_log log
  left join public.profiles actor
    on actor.id = log.actor_user_id and actor.company_id = v_company_id
  left join public.utility_users utility_actor
    on utility_actor.id = log.utility_user_id
  left join public.utility_organizations organization
    on organization.id = log.utility_organization_id
  left join public.contracts contract
    on contract.id = log.contract_id and contract.company_id = v_company_id
  left join public.jobs job
    on job.id = log.job_id and job.company_id = v_company_id
  where log.company_id = v_company_id
    and (p_before_created_at is null
         or (log.created_at, log.id) < (p_before_created_at, p_before_id))
  order by log.created_at desc, log.id desc
  limit v_limit;
end;
$function$;

create or replace function public.utility_job_contract_warning(p_job_ids uuid[])
returns table(
  job_id uuid,
  contract_id uuid,
  visible_org_count integer,
  visible_org_names text[],
  show_quantities_anywhere boolean
)
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_company_id uuid;
begin
  v_company_id := public.utility_require_contractor_manager();
  perform public.utility_require_portal_enabled(v_company_id);
  if p_job_ids is null or cardinality(p_job_ids) < 1
     or cardinality(p_job_ids) > 200
     or array_position(p_job_ids, null) is not null then
    raise exception using errcode = '22023', message = 'Invalid job list.';
  end if;
  return query
  with requested as (
    select distinct requested_id as job_id from unnest(p_job_ids) requested_id
  ), owned_job as (
    select requested.job_id, job.contract_id
    from requested
    left join public.jobs job
      on job.id = requested.job_id and job.company_id = v_company_id
  ), grant_state as materialized (
    select access.contract_id, access.utility_organization_id,
           access.show_quantities,
           cardinality(public.utility_grant_hidden_reasons(
             access.utility_organization_id, access.id
           )) = 0 as visible
    from public.utility_contract_access access
    where access.company_id = v_company_id
      and access.contract_id in (
        select owned_job.contract_id from owned_job
        where owned_job.contract_id is not null
      )
  )
  select owned_job.job_id, owned_job.contract_id,
         count(distinct grant_state.utility_organization_id)
           filter (where coalesce(grant_state.visible, false))::integer,
         coalesce(array_agg(distinct organization.name order by organization.name)
           filter (where coalesce(grant_state.visible, false)), array[]::text[]),
         coalesce(bool_or(grant_state.show_quantities)
           filter (where coalesce(grant_state.visible, false)), false)
  from owned_job
  left join grant_state on grant_state.contract_id = owned_job.contract_id
  left join public.utility_organizations organization
    on organization.id = grant_state.utility_organization_id
  group by owned_job.job_id, owned_job.contract_id
  order by owned_job.job_id;
end;
$function$;

create or replace function public.utility_unassigned_job_count()
returns table(unassigned_count integer)
language plpgsql
stable
security definer
set search_path to ''
as $function$
declare
  v_company_id uuid;
begin
  v_company_id := public.utility_require_contractor_manager();
  perform public.utility_require_portal_enabled(v_company_id);
  return query
  select count(*)::integer from public.jobs job
  where job.company_id = v_company_id and job.contract_id is null;
end;
$function$;

revoke all on function public.utility_list_organizations(boolean) from public, anon;
revoke all on function public.utility_list_representatives(uuid) from public, anon;
revoke all on function public.utility_contract_visibility_state(uuid, uuid) from public, anon;
revoke all on function public.utility_activity_feed(timestamptz, bigint, integer) from public, anon;
revoke all on function public.utility_job_contract_warning(uuid[]) from public, anon;
revoke all on function public.utility_unassigned_job_count() from public, anon;

grant execute on function public.utility_list_organizations(boolean) to authenticated;
grant execute on function public.utility_list_representatives(uuid) to authenticated;
grant execute on function public.utility_contract_visibility_state(uuid, uuid) to authenticated;
grant execute on function public.utility_activity_feed(timestamptz, bigint, integer) to authenticated;
grant execute on function public.utility_job_contract_warning(uuid[]) to authenticated;
grant execute on function public.utility_unassigned_job_count() to authenticated;
