begin;

-- Spreadsheet review is replacement-based while a package is still a draft.
-- Active baselines are immutable: corrections must be uploaded as a new
-- revision so approved field history keeps its original authorization context.
-- The RPC is one transaction, so a draft validation/import failure restores
-- every prior draft row together with the package status.
create or replace function public.finalize_job_package_spreadsheet_import(
  p_package_id uuid,
  p_rows jsonb,
  p_source_filename text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_result jsonb;
  v_package_status text;
begin
  if not public.linecrew_can_manage_job_packages() then
    raise exception using
      errcode = '42501',
      message = 'You do not have permission to import job packets.';
  end if;

  select profile.company_id
  into v_company_id
  from public.profiles profile
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where profile.id = auth.uid()
    and profile.active is true;

  perform 1
  from public.job_packages package
  join public.jobs job
    on job.id = package.job_id
   and job.company_id = package.company_id
   and job.contract_id = package.contract_id
  where package.id = p_package_id
    and package.company_id = v_company_id
    and package.status = 'draft'
    and job.active is true
  for update of package, job;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Upload a new job-jacket revision; only a draft package can be imported.';
  end if;

  delete from public.job_package_authorized_units authorized
  where authorized.company_id = v_company_id
    and authorized.job_package_id = p_package_id;

  delete from public.job_package_work_points point
  where point.company_id = v_company_id
    and point.job_package_id = p_package_id;

  v_result := public.import_job_package_units(
    p_package_id,
    p_rows,
    p_source_filename
  );

  select package.status
  into v_package_status
  from public.job_packages package
  where package.id = p_package_id
    and package.company_id = v_company_id;

  if v_package_status is distinct from 'active' then
    raise exception using
      errcode = '23514',
      message = 'The spreadsheet imported but the utility package did not activate.';
  end if;

  return coalesce(v_result, '{}'::jsonb) || jsonb_build_object(
    'package_status', 'active',
    'status', 'active'
  );
end;
$$;

revoke all on function public.finalize_job_package_spreadsheet_import(
  uuid, jsonb, text
) from public, anon;
grant execute on function public.finalize_job_package_spreadsheet_import(
  uuid, jsonb, text
) to authenticated;

-- Only the atomic draft finalizer may call the lower-level importer. This
-- closes stale-client and direct-RPC paths that could mutate an active baseline.
revoke all on function public.import_job_package_units(uuid, jsonb, text)
  from public, anon, authenticated;

-- Enforce draft-only edits below the RPC layer as well. This protects active
-- revision history from stale browser tabs and direct REST calls.
create or replace function public.enforce_draft_job_package_unit_mutation()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old_package_id uuid;
  v_new_package_id uuid;
  v_status text;
begin
  if auth.uid() is null then
    if tg_op = 'DELETE' then
      return old;
    end if;
    return new;
  end if;

  if tg_op in ('UPDATE', 'DELETE') then
    v_old_package_id := old.job_package_id;
    select package.status
    into v_status
    from public.job_packages package
    where package.id = v_old_package_id;

    -- A missing parent during DELETE is the FK cascade from an already
    -- approved draft-package delete.
    if found and v_status is distinct from 'draft' then
      raise exception using
        errcode = '23514',
        message = 'Active job-jacket revisions are read-only. Upload a new revision.';
    elsif not found and tg_op <> 'DELETE' then
      raise exception using
        errcode = 'P0002',
        message = 'The job-jacket package was not found.';
    end if;
  end if;

  if tg_op in ('INSERT', 'UPDATE') then
    v_new_package_id := new.job_package_id;
    v_status := null;
    select package.status
    into v_status
    from public.job_packages package
    where package.id = v_new_package_id;

    if not found then
      raise exception using
        errcode = 'P0002',
        message = 'The job-jacket package was not found.';
    elsif v_status is distinct from 'draft' then
      raise exception using
        errcode = '23514',
        message = 'Active job-jacket revisions are read-only. Upload a new revision.';
    end if;
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

revoke all on function public.enforce_draft_job_package_unit_mutation()
  from public, anon, authenticated;

drop trigger if exists enforce_draft_job_package_work_point_mutation
  on public.job_package_work_points;
create trigger enforce_draft_job_package_work_point_mutation
before insert or update or delete on public.job_package_work_points
for each row execute function public.enforce_draft_job_package_unit_mutation();

drop trigger if exists enforce_draft_job_package_authorized_unit_mutation
  on public.job_package_authorized_units;
create trigger enforce_draft_job_package_authorized_unit_mutation
before insert or update or delete on public.job_package_authorized_units
for each row execute function public.enforce_draft_job_package_unit_mutation();

create or replace function public.prevent_non_draft_job_package_delete()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if auth.uid() is null then
    return old;
  end if;

  if old.status is distinct from 'draft' then
    raise exception using
      errcode = '23514',
      message = 'Active and closed job-jacket revisions cannot be deleted.';
  end if;
  return old;
end;
$$;

revoke all on function public.prevent_non_draft_job_package_delete()
  from public, anon, authenticated;

drop trigger if exists prevent_non_draft_job_package_delete
  on public.job_packages;
create trigger prevent_non_draft_job_package_delete
before delete on public.job_packages
for each row execute function public.prevent_non_draft_job_package_delete();

-- Revision comparison uses the same canonical work-point identity as field
-- authorization/progress and includes transfer quantities explicitly.
create or replace function public.get_job_package_revision_delta_v2(
  p_package_id uuid
)
returns table(
  work_point text,
  unit_code text,
  prior_install numeric,
  new_install numeric,
  install_change numeric,
  prior_transfer numeric,
  new_transfer numeric,
  transfer_change numeric,
  prior_remove numeric,
  new_remove numeric,
  remove_change numeric
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_prior_package_id uuid;
begin
  select profile.company_id
  into v_company_id
  from public.profiles profile
  join public.companies company
    on company.id = profile.company_id
   and company.active is true
  where profile.id = auth.uid()
    and profile.active is true;

  if v_company_id is null then
    raise exception using
      errcode = '42501',
      message = 'Company access is required.';
  end if;

  select package.supersedes_package_id
  into v_prior_package_id
  from public.job_packages package
  where package.id = p_package_id
    and package.company_id = v_company_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Job package was not found.';
  end if;

  return query
  with old_units as (
    select
      public.normalize_work_point_key(point.work_point_code) as point_key,
      min(point.work_point_code) as display_point,
      lower(btrim(authorized.unit_code)) as unit_key,
      min(authorized.unit_code) as display_unit_code,
      coalesce(sum(authorized.authorized_install_quantity), 0)::numeric as install,
      coalesce(sum(authorized.authorized_transfer_quantity), 0)::numeric as transfer,
      coalesce(sum(authorized.authorized_retirement_quantity), 0)::numeric as remove_qty
    from public.job_package_authorized_units authorized
    join public.job_package_work_points point
      on point.id = authorized.work_point_id
     and point.company_id = authorized.company_id
     and point.job_package_id = authorized.job_package_id
    where authorized.job_package_id = v_prior_package_id
      and authorized.company_id = v_company_id
    group by
      public.normalize_work_point_key(point.work_point_code),
      lower(btrim(authorized.unit_code))
  ), new_units as (
    select
      public.normalize_work_point_key(point.work_point_code) as point_key,
      min(point.work_point_code) as display_point,
      lower(btrim(authorized.unit_code)) as unit_key,
      min(authorized.unit_code) as display_unit_code,
      coalesce(sum(authorized.authorized_install_quantity), 0)::numeric as install,
      coalesce(sum(authorized.authorized_transfer_quantity), 0)::numeric as transfer,
      coalesce(sum(authorized.authorized_retirement_quantity), 0)::numeric as remove_qty
    from public.job_package_authorized_units authorized
    join public.job_package_work_points point
      on point.id = authorized.work_point_id
     and point.company_id = authorized.company_id
     and point.job_package_id = authorized.job_package_id
    where authorized.job_package_id = p_package_id
      and authorized.company_id = v_company_id
    group by
      public.normalize_work_point_key(point.work_point_code),
      lower(btrim(authorized.unit_code))
  )
  select
    coalesce(new_unit.display_point, old_unit.display_point),
    coalesce(new_unit.display_unit_code, old_unit.display_unit_code),
    coalesce(old_unit.install, 0),
    coalesce(new_unit.install, 0),
    coalesce(new_unit.install, 0) - coalesce(old_unit.install, 0),
    coalesce(old_unit.transfer, 0),
    coalesce(new_unit.transfer, 0),
    coalesce(new_unit.transfer, 0) - coalesce(old_unit.transfer, 0),
    coalesce(old_unit.remove_qty, 0),
    coalesce(new_unit.remove_qty, 0),
    coalesce(new_unit.remove_qty, 0) - coalesce(old_unit.remove_qty, 0)
  from old_units old_unit
  full join new_units new_unit
    on new_unit.point_key = old_unit.point_key
   and new_unit.unit_key = old_unit.unit_key
  where coalesce(new_unit.install, 0) <> coalesce(old_unit.install, 0)
     or coalesce(new_unit.transfer, 0) <> coalesce(old_unit.transfer, 0)
     or coalesce(new_unit.remove_qty, 0) <> coalesce(old_unit.remove_qty, 0)
  order by
    coalesce(new_unit.point_key, old_unit.point_key),
    coalesce(new_unit.display_unit_code, old_unit.display_unit_code);
end;
$$;

revoke all on function public.get_job_package_revision_delta_v2(uuid)
  from public, anon;
grant execute on function public.get_job_package_revision_delta_v2(uuid)
  to authenticated;

commit;
