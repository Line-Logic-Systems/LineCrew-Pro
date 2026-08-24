begin;

create or replace function public.get_job_package_work_points(p_package_id uuid)
returns table(
  work_point_id uuid,work_point_code text,work_point_description text,
  authorized_unit_id uuid,unit_code text,unit_name text,unit_description text,
  authorized_install_quantity numeric,authorized_retirement_quantity numeric,
  reported_install_quantity numeric,reported_retirement_quantity numeric,
  approved_install_quantity numeric,approved_retirement_quantity numeric,
  authorized_value numeric,reported_value numeric,approved_value numeric
) language plpgsql security definer set search_path='' as $$
declare v_company_id uuid; v_role text; v_active boolean; v_job_id uuid;
begin
  select p.company_id,lower(coalesce(p.role,'')),p.active into v_company_id,v_role,v_active
  from public.profiles p where p.id=auth.uid();
  if v_company_id is null or not v_active or v_role not in ('admin','gf','owner','superintendent') then
    raise exception using errcode='42501',message='Only an active Admin or General Foreman can view package progress.';
  end if;
  if v_role='superintendent' and not public.linecrew_has_capability('job_packages') then
    raise exception using errcode='42501',message='This Superintendent does not have job packages permission.';
  end if;
  select p.job_id into v_job_id from public.job_packages p
  where p.id=p_package_id and p.company_id=v_company_id;
  if v_job_id is null then
    raise exception using errcode='P0002',message='Utility job package was not found in your company.';
  end if;

  return query select w.id,w.work_point_code,w.description,a.id,a.unit_code,i.item_name,i.description,
    coalesce(a.authorized_install_quantity+a.authorized_transfer_quantity,0),
    coalesce(a.authorized_retirement_quantity,0),
    coalesce(prod.reported_install_transfer,0),coalesce(prod.reported_retirement,0),
    coalesce(prod.approved_install_transfer,0),coalesce(prod.approved_retirement,0),
    coalesce((a.authorized_install_quantity+a.authorized_transfer_quantity)*i.install_price+
      a.authorized_retirement_quantity*i.retirement_price,0),
    coalesce(least(prod.reported_install_transfer,
      a.authorized_install_quantity+a.authorized_transfer_quantity)*i.install_price+
      least(prod.reported_retirement,a.authorized_retirement_quantity)*i.retirement_price,0),
    coalesce(least(prod.approved_install_transfer,
      a.authorized_install_quantity+a.authorized_transfer_quantity)*i.install_price+
      least(prod.approved_retirement,a.authorized_retirement_quantity)*i.retirement_price,0)
  from public.job_package_work_points w
  left join public.job_package_authorized_units a on a.work_point_id=w.id and a.company_id=w.company_id
  left join public.price_book_items i on i.id=a.price_book_item_id and i.company_id=a.company_id
  left join lateral (
    select coalesce(sum(l.install_quantity+l.transfer_quantity),0) reported_install_transfer,
      coalesce(sum(l.retirement_quantity),0) reported_retirement,
      coalesce(sum(l.install_quantity+l.transfer_quantity) filter(where lower(coalesce(r.status,''))='approved'),0) approved_install_transfer,
      coalesce(sum(l.retirement_quantity) filter(where lower(coalesce(r.status,''))='approved'),0) approved_retirement
    from public.daily_production_unit_locations l
    join public.daily_reports r on r.id=l.daily_report_id and r.company_id=l.company_id
    where l.company_id=v_company_id and r.job_id=v_job_id
      and public.normalize_work_point_key(l.pole_location)=public.normalize_work_point_key(w.work_point_code)
      and l.price_book_item_id=a.price_book_item_id
  ) prod on a.id is not null
  where w.job_package_id=p_package_id and w.company_id=v_company_id
  order by w.work_point_key,a.unit_code;
end; $$;

revoke all on function public.get_job_package_work_points(uuid) from public,anon;
grant execute on function public.get_job_package_work_points(uuid) to authenticated;

commit;
