-- Release 1 utility viewer RPCs. The declared result columns are mirrored in
-- tests/utility-portal/approved-rpc-columns.json and checked statically and at runtime.

create or replace function public.utility_me()
returns table(full_name text, organization_name text)
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_utility_user_id uuid;
  v_organization_id uuid;
begin
  v_utility_user_id := public.utility_current_user_id();
  if v_utility_user_id is null then
    raise exception using errcode = '42501', message = 'Access denied.';
  end if;

  select utility_user.utility_organization_id
  into v_organization_id
  from public.utility_users utility_user
  where utility_user.id = v_utility_user_id;

  insert into public.utility_activity_log (
    utility_organization_id, utility_user_id, actor_user_id, action
  ) values (
    v_organization_id, v_utility_user_id, auth.uid(), 'sign_in'
  );

  return query
  select utility_user.full_name, organization.name
  from public.utility_users utility_user
  join public.utility_organizations organization
    on organization.id = utility_user.utility_organization_id
  where utility_user.id = v_utility_user_id;
end;
$$;

create or replace function public.utility_list_jobs()
returns table(
  job_id uuid,
  job_number text,
  job_name text,
  contractor_company_name text,
  contract_name text,
  job_status text,
  overall_approved_percent numeric,
  last_updated timestamptz
)
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_utility_user_id uuid;
  v_organization_id uuid;
begin
  v_utility_user_id := public.utility_current_user_id();
  if v_utility_user_id is null then
    raise exception using errcode = '42501', message = 'Access denied.';
  end if;
  v_organization_id := public.utility_current_org_id();

  insert into public.utility_activity_log (
    utility_organization_id, utility_user_id, actor_user_id, action
  ) values (
    v_organization_id, v_utility_user_id, auth.uid(), 'job_list_viewed'
  );

  return query
  with visible_jobs as (
    select job.id, job.job_number, job.job_name, job.active, job.closed_at,
           job.created_at, job.company_id, job.contract_id
    from public.jobs job
    where job.contract_id is not null
      and public.utility_has_contract_access(job.contract_id)
      and exists (
        select 1
        from public.utility_contract_access access
        where access.contract_id = job.contract_id
          and access.company_id = job.company_id
          and access.utility_organization_id = v_organization_id
          and cardinality(public.utility_grant_hidden_reasons(
            access.utility_organization_id, access.id
          )) = 0
      )
  ), progress as (
    -- Utility progress is quantity-weighted only. Pricing must never influence a
    -- returned percentage, even indirectly.
    select visible.id as job_id,
      coalesce(sum(
        least(coalesce(approved.install_quantity, 0), authorized.authorized_install_quantity)
        + least(coalesce(approved.retirement_quantity, 0), authorized.authorized_retirement_quantity)
      ), 0)::numeric as approved_quantity,
      coalesce(sum(
        authorized.authorized_install_quantity
        + authorized.authorized_retirement_quantity
      ), 0)::numeric as authorized_quantity,
      max(package.updated_at) as package_updated_at
    from visible_jobs visible
    left join public.job_packages package
      on package.job_id = visible.id
     and package.company_id = visible.company_id
     and package.status = 'active'
    left join public.job_package_work_points point
      on point.job_package_id = package.id and point.company_id = package.company_id
    left join public.job_package_authorized_units authorized
      on authorized.work_point_id = point.id and authorized.company_id = point.company_id
    left join lateral (
      select coalesce(sum(location.install_quantity), 0)::numeric install_quantity,
             coalesce(sum(location.retirement_quantity), 0)::numeric retirement_quantity
      from public.daily_production_unit_locations location
      join public.daily_reports report
        on report.id = location.daily_report_id and report.company_id = location.company_id
      join public.daily_production_units production_unit
        on production_unit.id = location.daily_production_unit_id
       and production_unit.company_id = location.company_id
      where report.job_id = visible.id
        and coalesce(report.archived, false) is false
        and lower(coalesce(report.status, '')) = 'approved'
        and public.normalize_work_point_key(location.pole_location) =
            public.normalize_work_point_key(point.work_point_code)
        and lower(trim(production_unit.item_code)) = lower(trim(authorized.unit_code))
    ) approved on authorized.id is not null
    group by visible.id
  ), report_updates as (
    select report.job_id, max(report.updated_at) last_report_updated
    from public.daily_reports report
    join visible_jobs visible on visible.id = report.job_id
    where coalesce(report.archived, false) is false
      and lower(coalesce(report.status, '')) = 'approved'
    group by report.job_id
  )
  select visible.id, visible.job_number, visible.job_name,
         company.name, contract.contract_name,
         case when visible.active is true and visible.closed_at is null then 'active' else 'closed' end,
         case when coalesce(progress.authorized_quantity, 0) > 0
           then round(least(progress.approved_quantity / progress.authorized_quantity * 100, 100), 1)
           else 0::numeric end,
         greatest(visible.created_at, visible.closed_at,
                  progress.package_updated_at, report_updates.last_report_updated)
  from visible_jobs visible
  join public.companies company on company.id = visible.company_id
  join public.contracts contract on contract.id = visible.contract_id
  left join progress on progress.job_id = visible.id
  left join report_updates on report_updates.job_id = visible.id
  order by company.name, contract.contract_name, visible.job_number, visible.id;
end;
$$;

create or replace function public.utility_get_job_progress(p_job_id uuid)
returns table(
  work_point_code text,
  work_point_description text,
  unit_code text,
  unit_description text,
  percent_complete numeric,
  authorized_install_quantity numeric,
  approved_install_quantity numeric,
  authorized_retirement_quantity numeric,
  approved_retirement_quantity numeric
)
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_utility_user_id uuid;
  v_organization_id uuid;
  v_company_id uuid;
  v_contract_id uuid;
  v_show_quantities boolean;
begin
  v_utility_user_id := public.utility_current_user_id();
  if v_utility_user_id is null then
    raise exception using errcode = '42501', message = 'Access denied.';
  end if;
  if not public.utility_has_job_access(p_job_id) then
    raise exception using errcode = '42501', message = 'Access denied.';
  end if;

  v_organization_id := public.utility_current_org_id();
  select job.company_id, job.contract_id, access.show_quantities
  into v_company_id, v_contract_id, v_show_quantities
  from public.jobs job
  join public.utility_contract_access access
    on access.contract_id = job.contract_id
   and access.company_id = job.company_id
   and access.utility_organization_id = v_organization_id
   and cardinality(public.utility_grant_hidden_reasons(
     access.utility_organization_id, access.id
   )) = 0
  where job.id = p_job_id;

  if not found then
    raise exception using errcode = '42501', message = 'Access denied.';
  end if;

  insert into public.utility_activity_log (
    utility_organization_id, utility_user_id, actor_user_id,
    company_id, contract_id, job_id, action
  ) values (
    v_organization_id, v_utility_user_id, auth.uid(),
    v_company_id, v_contract_id, p_job_id, 'job_viewed'
  );

  return query
  -- Descriptions come from approved production snapshots so this RPC never
  -- needs to read price_book_items. Units with no approved production yet may
  -- therefore have a null description.
  select point.work_point_code, point.description,
         authorized.unit_code, approved.unit_description,
         case when (
           authorized.authorized_install_quantity
           + authorized.authorized_retirement_quantity
         ) > 0 then round(least((
           least(coalesce(approved.install_quantity, 0), authorized.authorized_install_quantity)
           + least(coalesce(approved.retirement_quantity, 0), authorized.authorized_retirement_quantity)
         ) / (
           authorized.authorized_install_quantity
           + authorized.authorized_retirement_quantity
         ) * 100, 100), 1) else 0::numeric end,
         case when v_show_quantities then authorized.authorized_install_quantity else null end,
         case when v_show_quantities then coalesce(approved.install_quantity, 0) else null end,
         case when v_show_quantities then authorized.authorized_retirement_quantity else null end,
         case when v_show_quantities then coalesce(approved.retirement_quantity, 0) else null end
  from public.job_packages package
  join public.job_package_work_points point
    on point.job_package_id = package.id and point.company_id = package.company_id
  join public.job_package_authorized_units authorized
    on authorized.work_point_id = point.id and authorized.company_id = point.company_id
  left join lateral (
    select coalesce(sum(location.install_quantity), 0)::numeric install_quantity,
           coalesce(sum(location.retirement_quantity), 0)::numeric retirement_quantity,
           max(nullif(btrim(production_unit.description), ''))::text unit_description
    from public.daily_production_unit_locations location
    join public.daily_reports report
      on report.id = location.daily_report_id and report.company_id = location.company_id
    join public.daily_production_units production_unit
      on production_unit.id = location.daily_production_unit_id
     and production_unit.company_id = location.company_id
    where report.job_id = p_job_id
      and coalesce(report.archived, false) is false
      and lower(coalesce(report.status, '')) = 'approved'
      and public.normalize_work_point_key(location.pole_location) =
          public.normalize_work_point_key(point.work_point_code)
      and lower(trim(production_unit.item_code)) = lower(trim(authorized.unit_code))
  ) approved on true
  where package.job_id = p_job_id
    and package.company_id = v_company_id
    and package.status = 'active'
  order by point.work_point_key, authorized.unit_code;
end;
$$;

create or replace function public.utility_accept_invitation(
  p_token_hash text,
  p_full_name text
)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_invitation public.utility_users%rowtype;
  v_auth_email text;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Access denied.';
  end if;
  if p_token_hash is null or p_token_hash !~ '^[0-9a-f]{64}$' then
    raise exception using errcode = '22023', message = 'Invitation is invalid or expired.';
  end if;
  if nullif(btrim(coalesce(p_full_name, '')), '') is null then
    raise exception using errcode = '22023', message = 'A name is required.';
  end if;
  if exists (select 1 from public.profiles profile where profile.id = auth.uid()) then
    raise exception using errcode = '42501', message = 'Access denied.';
  end if;
  if public.is_utility_user() then
    raise exception using errcode = '42501', message = 'Invitation is invalid or expired.';
  end if;

  select utility_user.* into v_invitation
  from public.utility_users utility_user
  where utility_user.invite_token_hash = p_token_hash
    and utility_user.status = 'invited'
    and utility_user.invite_expires_at > now()
  for update;
  if not found then
    raise exception using errcode = '42501', message = 'Invitation is invalid or expired.';
  end if;

  select lower(auth_user.email)
  into v_auth_email
  from auth.users auth_user
  where auth_user.id = auth.uid()
    and auth_user.email_confirmed_at is not null;
  if v_auth_email is null or v_auth_email <> v_invitation.email then
    raise exception using errcode = '42501', message = 'Access denied.';
  end if;

  if not exists (
    select 1 from public.utility_portal_feature_flags global_flag
    where global_flag.company_id is null and global_flag.enabled is true
  ) or not exists (
    select 1
    from public.utility_contract_access access
    join public.utility_portal_feature_flags company_flag
      on company_flag.company_id = access.company_id and company_flag.enabled is true
    where access.utility_organization_id = v_invitation.utility_organization_id
      and access.status = 'active'
  ) then
    raise exception using errcode = '42501', message = 'Access denied.';
  end if;

  update public.utility_users
  set user_id = auth.uid(), status = 'active', full_name = btrim(p_full_name),
      accepted_at = now(), invite_token_hash = null, invite_expires_at = null,
      updated_at = now()
  where id = v_invitation.id;

  insert into public.utility_activity_log (
    utility_organization_id, utility_user_id, actor_user_id, action
  ) values (
    v_invitation.utility_organization_id, v_invitation.id, auth.uid(), 'invite_accepted'
  );
end;
$$;

create or replace function public.utility_log_view(p_job_id uuid, p_action text)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_utility_user_id uuid;
  v_organization_id uuid;
  v_company_id uuid;
  v_contract_id uuid;
begin
  v_utility_user_id := public.utility_current_user_id();
  if v_utility_user_id is null then
    raise exception using errcode = '42501', message = 'Access denied.';
  end if;
  if p_action not in ('job_list_viewed', 'job_viewed') then
    raise exception using errcode = '22023', message = 'Invalid view action.';
  end if;
  v_organization_id := public.utility_current_org_id();

  if p_action = 'job_viewed' then
    if p_job_id is null or not public.utility_has_job_access(p_job_id) then
      raise exception using errcode = '42501', message = 'Access denied.';
    end if;
    select job.company_id, job.contract_id into v_company_id, v_contract_id
    from public.jobs job where job.id = p_job_id;
  elsif p_job_id is not null then
    raise exception using errcode = '22023', message = 'Invalid view action.';
  elsif not exists (
    select 1 from public.utility_contract_access access
    where access.utility_organization_id = v_organization_id
      and public.utility_has_contract_access(access.contract_id)
  ) then
    raise exception using errcode = '42501', message = 'Access denied.';
  end if;

  insert into public.utility_activity_log (
    utility_organization_id, utility_user_id, actor_user_id,
    company_id, contract_id, job_id, action
  ) values (
    v_organization_id, v_utility_user_id, auth.uid(),
    v_company_id, v_contract_id, p_job_id, p_action
  );
end;
$$;

revoke all on function public.utility_me() from public, anon, authenticated, service_role;
revoke all on function public.utility_list_jobs() from public, anon, authenticated, service_role;
revoke all on function public.utility_get_job_progress(uuid) from public, anon, authenticated, service_role;
revoke all on function public.utility_accept_invitation(text, text) from public, anon, authenticated, service_role;
revoke all on function public.utility_log_view(uuid, text) from public, anon, authenticated, service_role;
grant execute on function public.utility_me() to authenticated;
grant execute on function public.utility_list_jobs() to authenticated;
grant execute on function public.utility_get_job_progress(uuid) to authenticated;
grant execute on function public.utility_accept_invitation(text, text) to authenticated;
grant execute on function public.utility_log_view(uuid, text) to authenticated;

-- Utility identities may use only the explicit viewer RPC surface. Invitation
-- acceptance is the sole pre-identity escape and performs its own crossover checks.
create or replace function public.enforce_linecrew_company_access()
returns void
language plpgsql
stable security definer
set search_path to ''
as $$
declare
 v_company_id uuid;
 v_profile_active boolean;
 v_role text;
 v_is_support boolean;
 v_has_profile boolean;
 v_effective_access boolean;
 v_request_path text:=coalesce(current_setting('request.path',true),'');
 v_aal text:=coalesce((select auth.jwt()->>'aal'),'aal1');
begin
 if auth.uid() is null then return; end if;

 if v_request_path = '/rpc/utility_accept_invitation' then return; end if;
 if public.is_utility_user() then
  if v_request_path in (
    '/rpc/utility_me', '/rpc/utility_list_jobs',
    '/rpc/utility_get_job_progress', '/rpc/utility_log_view'
  ) then return; end if;
  raise exception using errcode='42501',message='Access denied.';
 end if;

 select exists(select 1 from public.platform_support_users s where s.user_id=auth.uid() and s.active is true) into v_is_support;
 select p.company_id,coalesce(p.active,true),lower(coalesce(p.role,''))
 into v_company_id,v_profile_active,v_role
 from public.profiles p where p.id=auth.uid();
 v_has_profile:=found;
 if not v_has_profile and not v_is_support then return; end if;
 if v_has_profile and v_profile_active is not true then
  raise exception using errcode='42501',message='LineCrew profile access is inactive.';
 end if;
 if v_request_path='/rpc/linecrew_mfa_bootstrap_identity' then return; end if;
 if (v_is_support or v_role in ('owner','admin')) and v_aal<>'aal2' then
  raise exception using errcode='42501',message='Authenticator verification is required for privileged access.',hint='Complete the LineCrew Pro authenticator challenge and retry.';
 end if;
 if v_request_path='/rpc/my_company_billing_summary' then return; end if;
 if v_has_profile then
  v_effective_access:=public.linecrew_company_access_enabled(v_company_id);
  if v_effective_access is not true then
   raise exception using errcode='42501',message='LineCrew company access is inactive.';
  end if;
 end if;
end;
$$;
