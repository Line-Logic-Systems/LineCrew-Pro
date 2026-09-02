begin;

create or replace function public.set_job_package_status(
  p_package_id uuid,
  p_status text
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_next_status text;
  v_job_active boolean;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role <> 'admin' then
    raise exception using
      errcode = '42501',
      message = 'Only an active company Admin can change a utility package status.';
  end if;

  v_next_status := lower(trim(coalesce(p_status, '')));
  if v_next_status not in ('active', 'closed') then
    raise exception using
      errcode = '22023',
      message = 'A utility package can only be activated or closed.';
  end if;

  select job.active
  into v_job_active
  from public.job_packages package
  join public.jobs job
    on job.id = package.job_id
   and job.company_id = package.company_id
  where package.id = p_package_id
    and package.company_id = v_company_id;

  if v_job_active is null then
    raise exception using
      errcode = 'P0002',
      message = 'Utility job package was not found in your company.';
  end if;

  if v_next_status = 'active' and v_job_active is not true then
    raise exception using
      errcode = '22023',
      message = 'Reopen the job before activating this utility package.';
  end if;

  if v_next_status = 'active' and not exists (
    select 1
    from public.job_package_authorized_units unit
    where unit.company_id = v_company_id
      and unit.job_package_id = p_package_id
  ) then
    raise exception using
      errcode = '22023',
      message = 'Add at least one authorized unit before activating this utility package.';
  end if;

  update public.job_packages package
  set status = v_next_status,
      updated_at = now()
  where package.id = p_package_id
    and package.company_id = v_company_id;

  return v_next_status;
end;
$$;

revoke all on function public.set_job_package_status(uuid, text) from public;
revoke all on function public.set_job_package_status(uuid, text) from anon;
grant execute on function public.set_job_package_status(uuid, text) to authenticated;

commit;
