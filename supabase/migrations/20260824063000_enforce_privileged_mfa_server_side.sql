begin;

-- A deliberately narrow bootstrap endpoint lets the browser learn whether it
-- must display the MFA challenge before every other Data API request is
-- rejected. It returns no company or customer data.
create or replace function public.linecrew_mfa_bootstrap_identity()
returns table (
  user_role text,
  is_support boolean,
  requires_mfa boolean,
  enforcement_active boolean,
  current_aal text
)
language sql
stable
security definer
set search_path = ''
as $$
  with identity as (
    select
      lower(coalesce(profile.role, '')) as user_role,
      exists (
        select 1
        from public.platform_support_users support_user
        where support_user.user_id = (select auth.uid())
          and support_user.active is true
      ) as is_support
    from (select 1) seed
    left join public.profiles profile
      on profile.id = (select auth.uid())
     and profile.active is true
    where (select auth.uid()) is not null
  )
  select
    identity.user_role,
    identity.is_support,
    identity.is_support or identity.user_role in ('owner', 'admin'),
    identity.is_support or (
      identity.user_role in ('owner', 'admin')
      and now() >= timestamptz '2026-08-31 05:00:00+00'
    ),
    coalesce((select auth.jwt() ->> 'aal'), 'aal1')
  from identity;
$$;

revoke all on function public.linecrew_mfa_bootstrap_identity()
  from public, anon;
grant execute on function public.linecrew_mfa_bootstrap_identity()
  to authenticated;

-- Shared by Storage RLS, which is not covered by PostgREST's pre-request hook.
create or replace function public.linecrew_privileged_mfa_satisfied()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select case
    when (select auth.uid()) is null then true
    when exists (
      select 1
      from public.platform_support_users support_user
      where support_user.user_id = (select auth.uid())
        and support_user.active is true
    ) then coalesce((select auth.jwt() ->> 'aal'), 'aal1') = 'aal2'
    when now() >= timestamptz '2026-08-31 05:00:00+00'
      and exists (
        select 1
        from public.profiles profile
        where profile.id = (select auth.uid())
          and profile.active is true
          and lower(coalesce(profile.role, '')) in ('owner', 'admin')
      ) then coalesce((select auth.jwt() ->> 'aal'), 'aal1') = 'aal2'
    else true
  end;
$$;

revoke all on function public.linecrew_privileged_mfa_satisfied()
  from public, anon;
grant execute on function public.linecrew_privileged_mfa_satisfied()
  to authenticated;

-- Preserve the existing suspended-account and subscription checks, then add
-- an AAL2 requirement for platform support immediately and Owner/Admin roles
-- when the already-advertised rollout deadline arrives.
create or replace function public.enforce_linecrew_company_access()
returns void
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_active boolean;
  v_status text;
  v_expires timestamptz;
  v_role text;
  v_is_support boolean;
  v_has_profile boolean;
  v_request_path text := coalesce(current_setting('request.path', true), '');
  v_aal text := coalesce((select auth.jwt() ->> 'aal'), 'aal1');
begin
  if auth.uid() is null then return; end if;

  select exists (
    select 1
    from public.platform_support_users support_user
    where support_user.user_id = auth.uid()
      and support_user.active is true
  ) into v_is_support;

  select
    coalesce(profile.active, true),
    lower(coalesce(company.subscription_status, 'trial')),
    company.subscription_expires_at,
    lower(coalesce(profile.role, ''))
  into v_active, v_status, v_expires, v_role
  from public.profiles profile
  join public.companies company on company.id = profile.company_id
  where profile.id = auth.uid();
  v_has_profile := found;

  -- Permit brand-new users without a profile to complete onboarding. An
  -- active platform-support identity is still MFA-protected without a profile.
  if not v_has_profile and not v_is_support then return; end if;

  if v_has_profile then
    if v_active is not true then
      raise exception using errcode = '42501',
        message = 'LineCrew profile access is inactive.';
    end if;
    if v_status in ('suspended', 'cancelled')
       or (v_status = 'trial' and v_expires is not null and v_expires <= now()) then
      raise exception using errcode = '42501',
        message = 'LineCrew company access is inactive.';
    end if;
  end if;

  -- This is the sole pre-MFA Data API exception. The RPC returns only the
  -- caller's role/MFA requirement and cannot read company records.
  if v_request_path = '/rpc/linecrew_mfa_bootstrap_identity' then return; end if;

  if (
    v_is_support
    or (
      now() >= timestamptz '2026-08-31 05:00:00+00'
      and v_role in ('owner', 'admin')
    )
  ) and v_aal <> 'aal2' then
    raise exception using errcode = '42501',
      message = 'Authenticator verification is required for privileged access.',
      hint = 'Complete the LineCrew Pro authenticator challenge and retry.';
  end if;
end;
$$;

revoke all on function public.enforce_linecrew_company_access()
  from public, anon;
grant execute on function public.enforce_linecrew_company_access()
  to authenticated, service_role;

-- Storage requests do not use pgrst.db_pre_request. Restrictive policies make
-- the same AAL rule an AND-condition on every existing storage permission.
drop policy if exists linecrew_privileged_mfa_storage_select
  on storage.objects;
create policy linecrew_privileged_mfa_storage_select
on storage.objects as restrictive
for select to authenticated
using ((select public.linecrew_privileged_mfa_satisfied()));

drop policy if exists linecrew_privileged_mfa_storage_insert
  on storage.objects;
create policy linecrew_privileged_mfa_storage_insert
on storage.objects as restrictive
for insert to authenticated
with check ((select public.linecrew_privileged_mfa_satisfied()));

drop policy if exists linecrew_privileged_mfa_storage_update
  on storage.objects;
create policy linecrew_privileged_mfa_storage_update
on storage.objects as restrictive
for update to authenticated
using ((select public.linecrew_privileged_mfa_satisfied()))
with check ((select public.linecrew_privileged_mfa_satisfied()));

drop policy if exists linecrew_privileged_mfa_storage_delete
  on storage.objects;
create policy linecrew_privileged_mfa_storage_delete
on storage.objects as restrictive
for delete to authenticated
using ((select public.linecrew_privileged_mfa_satisfied()));

alter role authenticator
  set pgrst.db_pre_request = 'public.enforce_linecrew_company_access';
notify pgrst, 'reload config';
notify pgrst, 'reload schema';

commit;
