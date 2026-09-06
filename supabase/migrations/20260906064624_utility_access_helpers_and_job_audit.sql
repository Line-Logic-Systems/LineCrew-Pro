-- Utility Portal v4: internal access helpers and fail-safe job visibility audit.

comment on function public.linecrew_company_access_enabled(uuid) is
  'Internal cross-tenant entitlement predicate. Never grant client roles EXECUTE: an arbitrary company_id would expose another contractor billing state.';

revoke all on public.utility_organizations,
              public.utility_users,
              public.utility_contract_access,
              public.utility_activity_log
  from anon;

-- Additive hardening: retain the existing INSERT trigger and cover the
-- otherwise unlikely case where a privileged path changes profiles.id.
create trigger utility_identity_blocks_profile_id_update
before update of id on public.profiles
for each row
when (old.id is distinct from new.id)
execute function public.utility_block_profile_insert();

create or replace function public.utility_current_user_id()
returns uuid
language sql
stable
security definer
set search_path to ''
as $function$
  select utility_user.id
  from public.utility_users utility_user
  where utility_user.user_id = auth.uid()
    and utility_user.status = 'active'
  limit 1;
$function$;

create or replace function public.utility_current_org_id()
returns uuid
language sql
stable
security definer
set search_path to ''
as $function$
  select utility_user.utility_organization_id
  from public.utility_users utility_user
  where utility_user.id = public.utility_current_user_id()
  limit 1;
$function$;

create or replace function public.utility_visibility_hidden_reasons(
  p_contract_active boolean,
  p_contract_start_date date,
  p_contract_end_date date,
  p_grant_status text,
  p_grant_expires_at timestamptz,
  p_company_flag_enabled boolean,
  p_global_flag_enabled boolean,
  p_entitlement_enabled boolean,
  p_now timestamptz,
  p_today date
)
returns text[]
language sql
immutable
set search_path to ''
as $function$
  select array_remove(array[
    case when p_contract_active is not true then 'contract_inactive' end,
    case when p_contract_start_date is not null and p_contract_start_date > p_today then 'contract_not_started' end,
    case when p_contract_end_date is not null and p_contract_end_date < p_today then 'contract_ended' end,
    case when p_grant_status = 'expired' or (p_grant_expires_at is not null and p_grant_expires_at <= p_now) then 'grant_expired' end,
    case when p_grant_status = 'revoked' then 'grant_revoked' end,
    case when p_company_flag_enabled is not true then 'company_flag_disabled' end,
    case when p_global_flag_enabled is not true then 'global_flag_disabled' end,
    case when p_entitlement_enabled is not true then 'entitlement_inactive' end
  ]::text[], null);
$function$;

create or replace function public.utility_grant_hidden_reasons(
  p_organization_id uuid,
  p_grant_id uuid
)
returns text[]
language sql
stable
security definer
set search_path to ''
as $function$
  select public.utility_visibility_hidden_reasons(
    contract.active, contract.start_date, contract.end_date,
    access.status, access.expires_at,
    exists (
      select 1 from public.utility_portal_feature_flags company_flag
      where company_flag.company_id = access.company_id and company_flag.enabled is true
    ),
    exists (
      select 1 from public.utility_portal_feature_flags global_flag
      where global_flag.company_id is null and global_flag.enabled is true
    ),
    public.linecrew_company_access_enabled(access.company_id),
    now(), current_date
  )
  from public.utility_contract_access access
  join public.contracts contract on contract.id = access.contract_id
  where access.id = p_grant_id
    and access.utility_organization_id = p_organization_id;
$function$;

create or replace function public.utility_has_contract_access(p_contract_id uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $function$
  select coalesce(exists (
    select 1 from public.utility_contract_access access
    where access.utility_organization_id = public.utility_current_org_id()
      and access.contract_id = p_contract_id
      and cardinality(public.utility_grant_hidden_reasons(
        access.utility_organization_id, access.id
      )) = 0
  ), false);
$function$;

create or replace function public.utility_has_job_access(p_job_id uuid)
returns boolean
language sql
stable
security definer
set search_path to ''
as $function$
  select coalesce((
    select public.utility_has_contract_access(job.contract_id)
    from public.jobs job
    where job.id = p_job_id
      and job.contract_id is not null
  ), false);
$function$;

revoke all on function public.utility_current_user_id() from public, anon, authenticated, service_role;
revoke all on function public.utility_current_org_id() from public, anon, authenticated, service_role;
revoke all on function public.utility_visibility_hidden_reasons(boolean, date, date, text, timestamptz, boolean, boolean, boolean, timestamptz, date) from public, anon, authenticated, service_role;
revoke all on function public.utility_grant_hidden_reasons(uuid, uuid) from public, anon, authenticated, service_role;
revoke all on function public.utility_has_contract_access(uuid) from public, anon, authenticated, service_role;
revoke all on function public.utility_has_job_access(uuid) from public, anon, authenticated, service_role;

create or replace function public.utility_log_job_contract_visibility()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
declare
  affected_grant record;
  previous_contract_id uuid := case when tg_op = 'UPDATE' then old.contract_id else null end;
  next_contract_id uuid := new.contract_id;
begin
  -- The nested block is a PostgreSQL subtransaction. If any audit insert fails,
  -- every audit insert attempted by this trigger is rolled back, the exception
  -- is swallowed after a server warning, and the contractor's job write proceeds.
  begin
    if tg_op = 'UPDATE'
       and previous_contract_id is distinct from next_contract_id
       and previous_contract_id is not null then
      for affected_grant in
        select access.utility_organization_id, access.company_id
        from public.utility_contract_access access
        where access.contract_id = previous_contract_id
          and access.status = 'active'
      loop
        insert into public.utility_activity_log (
          utility_organization_id, actor_user_id, company_id,
          contract_id, job_id, action, detail
        ) values (
          affected_grant.utility_organization_id, auth.uid(),
          affected_grant.company_id, previous_contract_id, new.id,
          'job_left_shared_contract',
          jsonb_build_object(
            'previous_contract_id', previous_contract_id,
            'new_contract_id', next_contract_id
          )
        );
      end loop;
    end if;

    if (tg_op = 'INSERT' and next_contract_id is not null)
       or (tg_op = 'UPDATE'
           and previous_contract_id is distinct from next_contract_id
           and next_contract_id is not null) then
      for affected_grant in
        select access.utility_organization_id, access.company_id
        from public.utility_contract_access access
        where access.contract_id = next_contract_id
          and access.status = 'active'
      loop
        insert into public.utility_activity_log (
          utility_organization_id, actor_user_id, company_id,
          contract_id, job_id, action, detail
        ) values (
          affected_grant.utility_organization_id, auth.uid(),
          affected_grant.company_id, next_contract_id, new.id,
          'job_entered_shared_contract',
          jsonb_build_object(
            'previous_contract_id', previous_contract_id,
            'new_contract_id', next_contract_id
          )
        );
      end loop;
    end if;
  exception when others then
    raise warning 'Utility Portal job visibility audit failed for job %: [%] %',
      new.id, sqlstate, sqlerrm;
  end;

  return new;
end;
$function$;

revoke all on function public.utility_log_job_contract_visibility()
  from public, anon, authenticated, service_role;

create trigger utility_job_contract_visibility_audit
after insert or update of contract_id on public.jobs
for each row
execute function public.utility_log_job_contract_visibility();
