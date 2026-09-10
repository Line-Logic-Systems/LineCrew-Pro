-- Add a protected Manager role and a read-only Safety role.
-- Manager receives company-wide operational access, but a database trigger
-- prevents Manager/Admin sessions from changing the Owner account.

alter table public.profiles drop constraint if exists profiles_role_supported;
alter table public.profiles add constraint profiles_role_supported
  check (lower(role) in ('foreman','gf','superintendent','admin','manager','owner','safety'));

alter table public.team_invitations drop constraint if exists team_invitations_intended_role_check;
alter table public.team_invitations add constraint team_invitations_intended_role_check
  check (lower(intended_role) in ('foreman','gf','superintendent','admin','manager','owner','safety'));

alter table public.training_videos drop constraint if exists training_video_role_supported;
alter table public.training_videos add constraint training_video_role_supported
  check (minimum_role in ('foreman','gf','superintendent','admin','manager','owner','safety'));

create or replace function public.linecrew_validate_profile_role()
returns trigger
language plpgsql
set search_path to ''
as $$
declare key text;
begin
  new.role := lower(trim(new.role));
  if new.role not in ('foreman','gf','superintendent','admin','manager','owner','safety') then
    raise exception 'Unsupported LineCrew Pro role: %', new.role;
  end if;
  new.role_permissions := coalesce(new.role_permissions, '{}'::jsonb);
  if jsonb_typeof(new.role_permissions) <> 'object' then
    raise exception 'Role permissions must be a JSON object';
  end if;
  foreach key in array array['actual_pricing','field_pricing'] loop
    if new.role_permissions ? key and jsonb_typeof(new.role_permissions -> key) <> 'boolean' then
      raise exception 'Money visibility permission % must be true or false', key;
    end if;
  end loop;
  if new.role in ('foreman','gf') then
    new.role_permissions := jsonb_strip_nulls(jsonb_build_object(
      'actual_pricing', new.role_permissions -> 'actual_pricing',
      'field_pricing', new.role_permissions -> 'field_pricing'
    ));
  elsif new.role in ('admin','manager','owner','safety') then
    new.role_permissions := '{}'::jsonb;
  end if;
  return new;
end;
$$;

create or replace function public.linecrew_protect_owner_from_management_roles()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare v_actor_role text;
begin
  if auth.uid() is null or auth.uid() = old.id then return new; end if;
  select lower(coalesce(role,'')) into v_actor_role
  from public.profiles where id = auth.uid() and active is true;
  if v_actor_role = 'manager' and (lower(coalesce(old.role,'')) = 'owner' or lower(coalesce(new.role,'')) = 'owner') then
    raise exception using errcode='42501', message='Managers cannot change, suspend, replace or assign the company Owner.';
  end if;
  if v_actor_role = 'admin' and
     (lower(coalesce(old.role,'')) in ('owner','manager') or lower(coalesce(new.role,'')) in ('owner','manager')) then
    raise exception using errcode='42501', message='Admins cannot change Owner or Manager accounts.';
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_protect_owner_from_management_roles on public.profiles;
create trigger profiles_protect_owner_from_management_roles
before update on public.profiles
for each row execute function public.linecrew_protect_owner_from_management_roles();

revoke all on function public.linecrew_protect_owner_from_management_roles() from public, anon, authenticated;
grant execute on function public.linecrew_protect_owner_from_management_roles() to service_role;

-- Re-emit operational functions with Manager alongside Owner/Admin. Ownership
-- bootstrap, transfer and platform-owner functions are deliberately excluded.
do $do$
declare fn record; original_definition text; updated_definition text;
begin
  for fn in
    select p.oid, p.proname
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.prokind='f'
      and pg_get_functiondef(p.oid) ~ $pattern$('owner'[^\n]{0,60}'admin'|'admin'[^\n]{0,60}'owner'|[<>=]+[[:space:]]*'admin')$pattern$
      and p.proname not in (
        'is_platform_owner','linecrew_claim_initial_owner','linecrew_transfer_company_owner',
        'linecrew_replace_company_owner','platform_owner_company_dashboard',
        'platform_owner_set_subscription','platform_owner_beta_applications',
        'platform_owner_decline_beta_application','platform_owner_mark_beta_invite_sent',
        'platform_owner_prepare_beta_company'
      )
  loop
    original_definition := pg_get_functiondef(fn.oid);
    updated_definition := original_definition;
    updated_definition := replace(updated_definition, '(''owner'',''admin'')', '(''owner'',''manager'',''admin'')');
    updated_definition := replace(updated_definition, '(''owner'', ''admin'')', '(''owner'', ''manager'', ''admin'')');
    updated_definition := replace(updated_definition, '(''admin'',''owner'')', '(''admin'',''manager'',''owner'')');
    updated_definition := replace(updated_definition, '(''admin'', ''owner'')', '(''admin'', ''manager'', ''owner'')');
    updated_definition := replace(updated_definition, '<> ''admin''', 'not in (''admin'',''manager'')');
    updated_definition := regexp_replace(
      updated_definition,
      '([^:<>!])=[[:space:]]*''admin''',
      E'\\1 in (''admin'',''manager'')',
      'g'
    );
    if fn.proname = 'linecrew_set_member_role' then
      updated_definition := replace(updated_definition,
        '(''foreman'',''gf'',''superintendent'',''admin'')',
        '(''foreman'',''gf'',''superintendent'',''admin'',''manager'',''safety'')');
      updated_definition := replace(updated_definition,
        '(''owner'',''admin'',''superintendent'')',
        '(''owner'',''manager'',''admin'',''superintendent'')');
    end if;
    if fn.proname in ('accept_team_invitation','complete_team_invitation_signup') then
      updated_definition := replace(updated_definition,
        '(''foreman'',''gf'',''superintendent'',''admin'',''owner'')',
        '(''foreman'',''gf'',''superintendent'',''admin'',''manager'',''owner'',''safety'')');
    end if;
    if fn.proname = 'get_company_jsas_scoped' then
      updated_definition := replace(updated_definition,
        '(''foreman'',''gf'',''admin'',''owner'',''superintendent'')',
        '(''foreman'',''gf'',''admin'',''manager'',''owner'',''superintendent'',''safety'')');
      updated_definition := replace(updated_definition,
        'or v_role in (''admin'',''manager'',''owner'',''superintendent'')',
        'or v_role in (''admin'',''manager'',''owner'',''superintendent'',''safety'')');
    end if;
    if updated_definition is distinct from original_definition then execute updated_definition; end if;
  end loop;
end;
$do$;

-- Manager gets the same tenant-scoped RLS paths already granted to Owner/Admin.
-- Profiles stay excluded: all member mutations remain behind the audited RPCs
-- and the Owner-protection trigger above.
do $do$
declare pol record; using_sql text; check_sql text; role_sql text; command_sql text;
begin
  for pol in
    select * from pg_policies
    where schemaname in ('public','storage')
      and tablename <> 'profiles'
      and (coalesce(qual,'') || coalesce(with_check,'')) like '%''owner''::text%'
      and (coalesce(qual,'') || coalesce(with_check,'')) like '%ANY (ARRAY[%'
      and (coalesce(qual,'') || coalesce(with_check,'')) not like '%is_platform_owner%'
  loop
    using_sql := replace(pol.qual, '''owner''::text', '''owner''::text, ''manager''::text');
    check_sql := replace(pol.with_check, '''owner''::text', '''owner''::text, ''manager''::text');
    if using_sql is distinct from pol.qual or check_sql is distinct from pol.with_check then
      role_sql := array_to_string(array(select quote_ident(r) from unnest(pol.roles) r), ', ');
      command_sql := case pol.cmd when 'ALL' then 'ALL' else pol.cmd end;
      execute format('drop policy %I on %I.%I', pol.policyname, pol.schemaname, pol.tablename);
      execute format('create policy %I on %I.%I as %s for %s to %s%s%s',
        pol.policyname, pol.schemaname, pol.tablename, pol.permissive, command_sql, role_sql,
        case when using_sql is null then '' else ' using (' || using_sql || ')' end,
        case when check_sql is null then '' else ' with check (' || check_sql || ')' end);
    end if;
  end loop;
end;
$do$;

-- Safety can read company JSA records and stored JSA pages, but receives no
-- insert/update/delete policy and no JSA mutation RPC permission path.
drop policy if exists safety_read_company_jsas on public.daily_report_jsas;
create policy safety_read_company_jsas on public.daily_report_jsas for select to authenticated
using (
  company_id = (select public.my_company_id())
  and (select public.current_user_has_active_profile())
  and lower(coalesce((select public.my_role()),'')) = 'safety'
);

drop policy if exists safety_read_jsa_uploads on storage.objects;
create policy safety_read_jsa_uploads on storage.objects for select to authenticated
using (
  bucket_id='jsa-uploads'
  and (storage.foldername(name))[1] = (public.my_company_id())::text
  and lower(coalesce(public.my_role(),'')) = 'safety'
);

create or replace function public.training_role_rank(p_role text)
returns integer language sql immutable set search_path to '' as $$
  select case lower(coalesce(p_role,''))
    when 'owner' then 6 when 'manager' then 5 when 'admin' then 4
    when 'superintendent' then 3 when 'gf' then 2 when 'general foreman' then 2
    when 'foreman' then 1 when 'safety' then 1 else 0 end;
$$;

comment on function public.linecrew_protect_owner_from_management_roles() is
  'Defense-in-depth: Manager can administer all company operations and lower roles but cannot affect Owner; Admin cannot affect Manager or Owner.';
