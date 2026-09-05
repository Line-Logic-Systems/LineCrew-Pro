begin;

-- Contract pricing is visible through role-aware RPCs for field users. Direct table
-- reads are reserved for leadership that is allowed to see actual pricing.
drop policy if exists "Company members can view price book items" on public.price_book_items;
create policy price_book_items_actual_pricing_select
on public.price_book_items for select to authenticated
using (
  company_id = (select public.my_company_id())
  and (select public.current_user_has_active_profile())
  and (
    lower(coalesce((select public.my_role()), '')) in ('owner', 'admin', 'gf')
    or (
      lower(coalesce((select public.my_role()), '')) = 'superintendent'
      and (select public.linecrew_has_capability('actual_pricing'))
    )
  )
);

drop policy if exists unit_prices_same_company_select on public.unit_prices;
create policy unit_prices_actual_pricing_select
on public.unit_prices for select to authenticated
using (
  company_id = (select public.my_company_id())
  and (select public.current_user_has_active_profile())
  and (
    lower(coalesce((select public.my_role()), '')) in ('owner', 'admin', 'gf')
    or (
      lower(coalesce((select public.my_role()), '')) = 'superintendent'
      and (select public.linecrew_has_capability('actual_pricing'))
    )
  )
);

drop policy if exists "company members read daily units" on public.daily_report_units;
create policy daily_report_units_actual_pricing_select
on public.daily_report_units for select to authenticated
using (
  company_id = (select public.my_company_id())
  and (select public.current_user_has_active_profile())
  and (
    lower(coalesce((select public.my_role()), '')) in ('owner', 'admin', 'gf')
    or (
      lower(coalesce((select public.my_role()), '')) = 'superintendent'
      and (select public.linecrew_has_capability('actual_pricing'))
    )
  )
);

-- Job mutations are already exposed through scoped SECURITY DEFINER RPCs. Remove
-- direct REST UPDATE/DELETE so closeout and deletion cannot bypass those controls.
revoke update, delete on public.jobs from authenticated;

-- Foremen may enumerate packages only for assigned jobs; leadership keeps the
-- same company-wide behavior as before.
create or replace function public.get_job_packages_v2(p_job_id uuid default null::uuid)
returns table(
  id uuid, job_id uuid, contract_id uuid, package_name text, package_number text,
  received_date date, source_filename text, notes text, status text,
  revision_number integer, supersedes_package_id uuid,
  created_at timestamp with time zone, updated_at timestamp with time zone
)
language plpgsql stable security definer set search_path to '' as $$
declare v_company uuid; v_role text;
begin
  select p.company_id, lower(coalesce(p.role, ''))
  into v_company, v_role
  from public.profiles p
  where p.id = auth.uid() and p.active;

  if v_company is null or
     v_role not in ('owner', 'admin', 'gf', 'superintendent', 'foreman') then
    raise exception using errcode = '42501', message = 'Company access is required.';
  end if;
  if v_role = 'superintendent' and not public.linecrew_has_capability('job_packages') then
    raise exception using errcode = '42501',
      message = 'This Superintendent does not have job package permission.';
  end if;
  if p_job_id is not null and not exists (
    select 1 from public.jobs j
    where j.id = p_job_id and j.company_id = v_company
      and (v_role <> 'foreman' or public.linecrew_foreman_has_job_assignment(j.id))
  ) then
    raise exception using errcode = 'P0002',
      message = 'Job was not found or is not assigned to this Foreman.';
  end if;

  return query
  select package.id, package.job_id, package.contract_id, package.package_name,
    package.package_number, package.received_date, package.source_filename,
    package.notes, package.status, package.revision_number,
    package.supersedes_package_id, package.created_at, package.updated_at
  from public.job_packages package
  where package.company_id = v_company
    and (p_job_id is null or package.job_id = p_job_id)
    and (v_role <> 'foreman' or public.linecrew_foreman_has_job_assignment(package.job_id))
  order by package.job_id, package.revision_number desc;
end;
$$;

revoke all on function public.get_job_packages_v2(uuid) from public, anon;
grant execute on function public.get_job_packages_v2(uuid) to authenticated;

commit;
