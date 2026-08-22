import fs from 'node:fs';

const migrations = 'supabase/migrations';
const outputPath = `${migrations}/20260822220000_production_role_compatibility_drift_repair.sql`;

const superintendentPath = `${migrations}/202608190200_superintendent_legacy_compatibility.sql`;
const authorizationPath = `${migrations}/20260816_daily_unit_authorization_status.sql`;

const superintendent = fs.readFileSync(superintendentPath, 'utf8')
  .replace(/^([\s\S]*?\n)?begin;\s*/i, '')
  .replace(/\s*commit;\s*$/i, '')
  .trim();

const authorization = fs.readFileSync(authorizationPath, 'utf8');
const locationMatch = authorization.match(
  /create function public\.get_daily_report_unit_locations\(p_report_id uuid\)[\s\S]*?\n\$\$;/i,
);

if (!locationMatch) throw new Error('Unable to find the canonical unit-location function.');

const locationFunction = locationMatch[0]
  .replace(/^create function/i, 'create or replace function')
  .replace(
    "v_role not in ('foreman', 'gf', 'admin')",
    "v_role not in ('foreman', 'gf', 'superintendent', 'admin', 'owner')",
  )
  .replace(
    "v_can_see_actual := v_role in ('admin', 'gf');",
    "v_can_see_actual := v_role in ('admin', 'gf', 'owner') or\n    (v_role = 'superintendent' and public.linecrew_has_capability('actual_pricing'));",
  );

if (!locationFunction.includes('authorization_status text') ||
    !locationFunction.includes("linecrew_has_capability('actual_pricing')")) {
  throw new Error('Canonical unit-location repair is missing required fields or capability enforcement.');
}

const policySql = `
-- Direct profile writes previously allowed an Admin to change protected role
-- columns without the hierarchy RPC. All profile mutations now go through the
-- secured role-management or self-service functions.
drop policy if exists profiles_admin_update on public.profiles;

-- Owner is an Admin-equivalent for company operations. These narrowly mirror
-- the existing Admin/GF policy commands while retaining company scoping.
drop policy if exists linecrew_owner_audit_select on public.audit_log;
create policy linecrew_owner_audit_select on public.audit_log for select to authenticated
using (company_id = public.my_company_id() and public.my_role() = 'owner');

drop policy if exists linecrew_owner_company_update on public.companies;
create policy linecrew_owner_company_update on public.companies for update to authenticated
using (id = public.my_company_id() and public.my_role() = 'owner')
with check (id = public.my_company_id() and public.my_role() = 'owner');

drop policy if exists linecrew_owner_settings_update on public.company_settings;
create policy linecrew_owner_settings_update on public.company_settings for update to authenticated
using (company_id = public.my_company_id() and public.my_role() = 'owner')
with check (company_id = public.my_company_id() and public.my_role() = 'owner');

drop policy if exists linecrew_owner_contracts_manage on public.contracts;
create policy linecrew_owner_contracts_manage on public.contracts for all to authenticated
using (company_id = public.my_company_id() and public.my_role() = 'owner')
with check (company_id = public.my_company_id() and public.my_role() = 'owner');

drop policy if exists linecrew_owner_crews_manage on public.crews;
create policy linecrew_owner_crews_manage on public.crews for all to authenticated
using (company_id = public.my_company_id() and public.my_role() = 'owner')
with check (company_id = public.my_company_id() and public.my_role() = 'owner');

drop policy if exists linecrew_owner_customers_manage on public.customers;
create policy linecrew_owner_customers_manage on public.customers for all to authenticated
using (company_id = public.my_company_id() and public.my_role() = 'owner')
with check (company_id = public.my_company_id() and public.my_role() = 'owner');

drop policy if exists linecrew_owner_production_items_delete on public.daily_production_items;
create policy linecrew_owner_production_items_delete on public.daily_production_items for delete to authenticated
using (company_id = public.my_company_id() and public.my_role() = 'owner');

drop policy if exists linecrew_owner_daily_reports_select on public.daily_reports;
create policy linecrew_owner_daily_reports_select on public.daily_reports for select to authenticated
using (company_id = public.my_company_id() and public.my_role() = 'owner');

drop policy if exists linecrew_owner_daily_reports_update on public.daily_reports;
create policy linecrew_owner_daily_reports_update on public.daily_reports for update to authenticated
using (company_id = public.my_company_id() and public.my_role() = 'owner')
with check (company_id = public.my_company_id() and public.my_role() = 'owner');

drop policy if exists linecrew_owner_daily_reports_delete on public.daily_reports;
create policy linecrew_owner_daily_reports_delete on public.daily_reports for delete to authenticated
using (company_id = public.my_company_id() and public.my_role() = 'owner');

drop policy if exists linecrew_owner_employees_manage on public.employees;
create policy linecrew_owner_employees_manage on public.employees for all to authenticated
using (company_id = public.my_company_id() and public.my_role() = 'owner')
with check (company_id = public.my_company_id() and public.my_role() = 'owner');

drop policy if exists linecrew_owner_jobs_manage on public.jobs;
create policy linecrew_owner_jobs_manage on public.jobs for all to authenticated
using (company_id = public.my_company_id() and public.my_role() = 'owner')
with check (company_id = public.my_company_id() and public.my_role() = 'owner');

drop policy if exists linecrew_owner_price_book_items_manage on public.price_book_items;
create policy linecrew_owner_price_book_items_manage on public.price_book_items for all to authenticated
using (company_id = public.my_company_id() and public.my_role() = 'owner')
with check (company_id = public.my_company_id() and public.my_role() = 'owner');

drop policy if exists linecrew_owner_price_books_manage on public.price_books;
create policy linecrew_owner_price_books_manage on public.price_books for all to authenticated
using (company_id = public.my_company_id() and public.my_role() = 'owner')
with check (company_id = public.my_company_id() and public.my_role() = 'owner');

drop policy if exists linecrew_owner_report_units_update on public.report_units;
create policy linecrew_owner_report_units_update on public.report_units for update to authenticated
using (company_id = public.my_company_id() and public.my_role() = 'owner')
with check (company_id = public.my_company_id() and public.my_role() = 'owner');

drop policy if exists linecrew_owner_report_units_delete on public.report_units;
create policy linecrew_owner_report_units_delete on public.report_units for delete to authenticated
using (company_id = public.my_company_id() and public.my_role() = 'owner');

drop policy if exists linecrew_owner_unit_prices_manage on public.unit_prices;
create policy linecrew_owner_unit_prices_manage on public.unit_prices for all to authenticated
using (company_id = public.my_company_id() and public.my_role() = 'owner')
with check (company_id = public.my_company_id() and public.my_role() = 'owner');
`;

const selfServiceSql = `
create or replace function public.update_my_profile_name(p_full_name text)
returns table(id uuid, full_name text, role text, company_id uuid)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text := btrim(coalesce(p_full_name, ''));
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Authentication required.';
  end if;
  if length(v_name) < 2 or length(v_name) > 120 then
    raise exception using errcode = '22023', message = 'Display name must be between 2 and 120 characters.';
  end if;
  return query
  update public.profiles profile
  set full_name = v_name
  where profile.id = auth.uid() and profile.active is true
  returning profile.id, profile.full_name, profile.role, profile.company_id;
end;
$$;
revoke all on function public.update_my_profile_name(text) from public, anon;
grant execute on function public.update_my_profile_name(text) to authenticated;
`;

const verificationSql = `
do $$
declare
  v_definition text;
begin
  if to_regprocedure('public.update_my_profile_name(text)') is null then
    raise exception 'update_my_profile_name(text) was not created';
  end if;
  select pg_get_functiondef('public.get_daily_report_unit_locations(uuid)'::regprocedure)
  into v_definition;
  if v_definition not like '%authorization_status text%'
     or v_definition not like '%linecrew_has_capability(''actual_pricing'')%' then
    raise exception 'get_daily_report_unit_locations is not on the current secured definition';
  end if;
  if has_function_privilege('anon', 'public.get_daily_report_unit_locations(uuid)', 'execute') then
    raise exception 'anon must not execute get_daily_report_unit_locations';
  end if;
end;
$$;
`;

const output = `-- Forward-only repair for production role/RPC drift.
-- Generated from the current compatibility layer; do not hand-edit.
begin;

${superintendent}

-- Preserve the current 22-column authorization-aware return contract while
-- correcting Owner/Superintendent authorization and capability enforcement.
drop function if exists public.get_daily_report_unit_locations(uuid);
${locationFunction}
revoke all on function public.get_daily_report_unit_locations(uuid) from public, anon;
grant execute on function public.get_daily_report_unit_locations(uuid) to authenticated;

${selfServiceSql}

-- Disable unused legacy mutation paths that bypass current hierarchy and
-- Daily Report approval/audit controls.
revoke all on function public.admin_update_user(uuid,text,boolean) from public, anon, authenticated;
revoke all on function public.review_daily_report(uuid,boolean,text) from public, anon, authenticated;

${policySql}

${verificationSql}

notify pgrst, 'reload schema';
commit;
`;

fs.writeFileSync(outputPath, output);
console.log(`Generated ${outputPath}`);
