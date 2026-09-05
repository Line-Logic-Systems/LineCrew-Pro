begin;

create or replace function public.get_job_package_revision_delta(p_package_id uuid)
returns table(work_point text,unit_code text,prior_install numeric,new_install numeric,install_change numeric,
  prior_remove numeric,new_remove numeric,remove_change numeric)
language plpgsql stable security definer set search_path='' as $$
declare v_company uuid; v_prior uuid;
begin
  select p.company_id into v_company
  from public.profiles p
  where p.id=auth.uid() and p.active;

  if v_company is null then
    raise exception using errcode='42501',message='Company access is required.';
  end if;

  select package.supersedes_package_id into v_prior
  from public.job_packages package
  where package.id=p_package_id and package.company_id=v_company;

  if not found then
    raise exception using errcode='P0002',message='Job package was not found.';
  end if;

  return query with old_units as (
    select wp.work_point_code wp,u.unit_code,sum(u.authorized_install_quantity) install,
      sum(u.authorized_retirement_quantity) remove_qty
    from public.job_package_authorized_units u
    join public.job_package_work_points wp on wp.id=u.work_point_id
    where u.job_package_id=v_prior
      and u.company_id=v_company
      and wp.company_id=v_company
    group by wp.work_point_code,u.unit_code
  ), new_units as (
    select wp.work_point_code wp,u.unit_code,sum(u.authorized_install_quantity) install,
      sum(u.authorized_retirement_quantity) remove_qty
    from public.job_package_authorized_units u
    join public.job_package_work_points wp on wp.id=u.work_point_id
    where u.job_package_id=p_package_id
      and u.company_id=v_company
      and wp.company_id=v_company
    group by wp.work_point_code,u.unit_code
  ) select coalesce(n.wp,o.wp),coalesce(n.unit_code,o.unit_code),coalesce(o.install,0),
    coalesce(n.install,0),coalesce(n.install,0)-coalesce(o.install,0),coalesce(o.remove_qty,0),
    coalesce(n.remove_qty,0),coalesce(n.remove_qty,0)-coalesce(o.remove_qty,0)
  from old_units o full join new_units n on n.wp=o.wp and n.unit_code=o.unit_code
  where coalesce(n.install,0)<>coalesce(o.install,0)
    or coalesce(n.remove_qty,0)<>coalesce(o.remove_qty,0)
  order by coalesce(n.wp,o.wp),coalesce(n.unit_code,o.unit_code);
end;
$$;

revoke all on function public.get_job_package_revision_delta(uuid) from public,anon;
grant execute on function public.get_job_package_revision_delta(uuid) to authenticated;

commit;
