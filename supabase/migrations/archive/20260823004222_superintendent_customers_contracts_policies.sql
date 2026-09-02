begin;

-- Match the Customers & Contracts UI capability with the direct table writes
-- it performs. Access remains restricted to the caller's company, an active
-- Superintendent profile, and the explicit customers_contracts capability.
drop policy if exists linecrew_superintendent_customers_manage on public.customers;
create policy linecrew_superintendent_customers_manage
on public.customers
for all
to authenticated
using (
  company_id = public.my_company_id()
  and public.my_role() = 'superintendent'
  and public.linecrew_has_capability('customers_contracts')
)
with check (
  company_id = public.my_company_id()
  and public.my_role() = 'superintendent'
  and public.linecrew_has_capability('customers_contracts')
);

drop policy if exists linecrew_superintendent_contracts_manage on public.contracts;
create policy linecrew_superintendent_contracts_manage
on public.contracts
for all
to authenticated
using (
  company_id = public.my_company_id()
  and public.my_role() = 'superintendent'
  and public.linecrew_has_capability('customers_contracts')
)
with check (
  company_id = public.my_company_id()
  and public.my_role() = 'superintendent'
  and public.linecrew_has_capability('customers_contracts')
);

do $$
declare
  v_policy_count integer;
begin
  select count(*)
  into v_policy_count
  from pg_policies
  where schemaname = 'public'
    and tablename in ('customers', 'contracts')
    and policyname in (
      'linecrew_superintendent_customers_manage',
      'linecrew_superintendent_contracts_manage'
    )
    and cmd = 'ALL'
    and roles = array['authenticated']::name[]
    and qual like '%customers_contracts%'
    and qual like '%my_company_id%'
    and with_check like '%customers_contracts%'
    and with_check like '%my_company_id%';

  if v_policy_count <> 2 then
    raise exception 'Superintendent Customers & Contracts policies were not installed safely.';
  end if;
end;
$$;

notify pgrst, 'reload schema';

commit;
