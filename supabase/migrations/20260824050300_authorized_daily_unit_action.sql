begin;

create or replace function public.get_daily_report_unit_authorized_action(
  p_report_id uuid,
  p_price_book_item_id uuid,
  p_pole_location text
)
returns table(
  preferred_work_type text,
  authorized_install_quantity numeric,
  authorized_transfer_quantity numeric,
  authorized_retirement_quantity numeric
)
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_report_company_id uuid;
  v_report_creator uuid;
  v_job_id uuid;
begin
  select p.company_id,lower(coalesce(p.role,'')),p.active
  into v_company_id,v_role,v_active
  from public.profiles p where p.id=auth.uid();

  if v_company_id is null or not v_active or
     v_role not in ('foreman','gf','superintendent','admin','owner') then
    raise exception using errcode='42501',message='An active production profile is required.';
  end if;

  select r.company_id,r.created_by,r.job_id
  into v_report_company_id,v_report_creator,v_job_id
  from public.daily_reports r where r.id=p_report_id;

  if v_report_company_id is null or v_report_company_id<>v_company_id then
    raise exception using errcode='P0002',message='Daily report was not found in your company.';
  end if;
  if v_role='foreman' and v_report_creator is distinct from auth.uid() then
    raise exception using errcode='42501',message='Foremen can view unit authorization only on their own reports.';
  end if;

  return query
  with quantities as (
    select
      coalesce(sum(a.authorized_install_quantity),0)::numeric install_qty,
      coalesce(sum(a.authorized_transfer_quantity),0)::numeric transfer_qty,
      coalesce(sum(a.authorized_retirement_quantity),0)::numeric retirement_qty
    from public.job_packages p
    join public.job_package_work_points w
      on w.job_package_id=p.id and w.company_id=p.company_id
    join public.job_package_authorized_units a
      on a.work_point_id=w.id and a.company_id=w.company_id
    where p.company_id=v_company_id and p.job_id=v_job_id and p.status='active'
      and public.normalize_work_point_key(w.work_point_code)=
          public.normalize_work_point_key(p_pole_location)
      and a.price_book_item_id=p_price_book_item_id
  )
  select case
      when q.transfer_qty>0 and q.install_qty=0 and q.retirement_qty=0 then 'transfer'
      when q.retirement_qty>0 and q.install_qty=0 and q.transfer_qty=0 then 'retirement'
      when q.install_qty>0 and q.transfer_qty=0 and q.retirement_qty=0 then 'install'
      else null
    end,
    q.install_qty,q.transfer_qty,q.retirement_qty
  from quantities q;
end;
$$;

revoke all on function public.get_daily_report_unit_authorized_action(uuid,uuid,text)
  from public,anon;
grant execute on function public.get_daily_report_unit_authorized_action(uuid,uuid,text)
  to authenticated;

commit;
