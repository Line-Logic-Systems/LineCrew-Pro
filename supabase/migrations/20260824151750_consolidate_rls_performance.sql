-- Consolidate equivalent permissive policies and cache auth.uid() once per statement.
-- Access remains role-, capability-, and company-scoped exactly as before.

-- Audit and company administration.
drop policy if exists audit_admin_select on public.audit_log;
drop policy if exists linecrew_owner_audit_select on public.audit_log;
create policy audit_leadership_select on public.audit_log for select to authenticated
using (company_id = (select public.my_company_id()) and lower(coalesce((select public.my_role()), '')) = any (array['owner','admin']));

drop policy if exists company_admin_update on public.companies;
drop policy if exists linecrew_owner_company_update on public.companies;
create policy company_leadership_update on public.companies for update to authenticated
using (id = (select public.my_company_id()) and lower(coalesce((select public.my_role()), '')) = any (array['owner','admin']))
with check (id = (select public.my_company_id()) and lower(coalesce((select public.my_role()), '')) = any (array['owner','admin']));

drop policy if exists linecrew_owner_settings_update on public.company_settings;
drop policy if exists settings_admin_update on public.company_settings;
create policy settings_leadership_update on public.company_settings for update to authenticated
using (company_id = (select public.my_company_id()) and lower(coalesce((select public.my_role()), '')) = any (array['owner','admin']))
with check (company_id = (select public.my_company_id()) and lower(coalesce((select public.my_role()), '')) = any (array['owner','admin']));

-- Customers and contracts: all company members read; Owner/Admin and capable Superintendent manage.
drop policy if exists "Admins can delete contracts" on public.contracts;
drop policy if exists "Admins can insert contracts" on public.contracts;
drop policy if exists "Admins can update contracts" on public.contracts;
drop policy if exists "Company members can view contracts" on public.contracts;
drop policy if exists linecrew_owner_contracts_manage on public.contracts;
drop policy if exists linecrew_superintendent_contracts_manage on public.contracts;
create policy contracts_company_select on public.contracts for select to authenticated
using (company_id = (select public.my_company_id()));
create policy contracts_leadership_insert on public.contracts for insert to authenticated
with check (company_id = (select public.my_company_id()) and (lower(coalesce((select public.my_role()), '')) = any (array['owner','admin']) or (lower(coalesce((select public.my_role()), '')) = 'superintendent' and (select public.linecrew_has_capability('customers_contracts')))));
create policy contracts_leadership_update on public.contracts for update to authenticated
using (company_id = (select public.my_company_id()) and (lower(coalesce((select public.my_role()), '')) = any (array['owner','admin']) or (lower(coalesce((select public.my_role()), '')) = 'superintendent' and (select public.linecrew_has_capability('customers_contracts')))))
with check (company_id = (select public.my_company_id()) and (lower(coalesce((select public.my_role()), '')) = any (array['owner','admin']) or (lower(coalesce((select public.my_role()), '')) = 'superintendent' and (select public.linecrew_has_capability('customers_contracts')))));
create policy contracts_leadership_delete on public.contracts for delete to authenticated
using (company_id = (select public.my_company_id()) and (lower(coalesce((select public.my_role()), '')) = any (array['owner','admin']) or (lower(coalesce((select public.my_role()), '')) = 'superintendent' and (select public.linecrew_has_capability('customers_contracts')))));

drop policy if exists "Admins can delete customers" on public.customers;
drop policy if exists "Admins can insert customers" on public.customers;
drop policy if exists "Admins can update customers" on public.customers;
drop policy if exists "Company members can view customers" on public.customers;
drop policy if exists linecrew_owner_customers_manage on public.customers;
drop policy if exists linecrew_superintendent_customers_manage on public.customers;
create policy customers_company_select on public.customers for select to authenticated
using (company_id = (select public.my_company_id()));
create policy customers_leadership_insert on public.customers for insert to authenticated
with check (company_id = (select public.my_company_id()) and (lower(coalesce((select public.my_role()), '')) = any (array['owner','admin']) or (lower(coalesce((select public.my_role()), '')) = 'superintendent' and (select public.linecrew_has_capability('customers_contracts')))));
create policy customers_leadership_update on public.customers for update to authenticated
using (company_id = (select public.my_company_id()) and (lower(coalesce((select public.my_role()), '')) = any (array['owner','admin']) or (lower(coalesce((select public.my_role()), '')) = 'superintendent' and (select public.linecrew_has_capability('customers_contracts')))))
with check (company_id = (select public.my_company_id()) and (lower(coalesce((select public.my_role()), '')) = any (array['owner','admin']) or (lower(coalesce((select public.my_role()), '')) = 'superintendent' and (select public.linecrew_has_capability('customers_contracts')))));
create policy customers_leadership_delete on public.customers for delete to authenticated
using (company_id = (select public.my_company_id()) and (lower(coalesce((select public.my_role()), '')) = any (array['owner','admin']) or (lower(coalesce((select public.my_role()), '')) = 'superintendent' and (select public.linecrew_has_capability('customers_contracts')))));

-- Crew and employee administration.
drop policy if exists linecrew_owner_crews_manage on public.crews;
drop policy if exists crews_admin_gf_insert on public.crews;
drop policy if exists crews_admin_gf_update on public.crews;
create policy crews_leadership_insert on public.crews for insert to authenticated
with check (company_id = (select public.my_company_id()) and lower(coalesce((select public.my_role()), '')) = any (array['owner','admin','gf']));
create policy crews_leadership_update on public.crews for update to authenticated
using (company_id = (select public.my_company_id()) and lower(coalesce((select public.my_role()), '')) = any (array['owner','admin','gf']))
with check (company_id = (select public.my_company_id()) and lower(coalesce((select public.my_role()), '')) = any (array['owner','admin','gf']));
create policy crews_owner_delete on public.crews for delete to authenticated
using (company_id = (select public.my_company_id()) and lower(coalesce((select public.my_role()), '')) = 'owner');

drop policy if exists employees_admin_gf_manage on public.employees;
drop policy if exists linecrew_owner_employees_manage on public.employees;
create policy employees_leadership_insert on public.employees for insert to authenticated
with check (company_id = (select public.my_company_id()) and lower(coalesce((select public.my_role()), '')) = any (array['owner','admin','gf']));
create policy employees_leadership_update on public.employees for update to authenticated
using (company_id = (select public.my_company_id()) and lower(coalesce((select public.my_role()), '')) = any (array['owner','admin','gf']))
with check (company_id = (select public.my_company_id()) and lower(coalesce((select public.my_role()), '')) = any (array['owner','admin','gf']));
create policy employees_leadership_delete on public.employees for delete to authenticated
using (company_id = (select public.my_company_id()) and lower(coalesce((select public.my_role()), '')) = any (array['owner','admin','gf']));

-- Job management. The existing jobs_role_scoped_select remains the only SELECT policy.
drop policy if exists jobs_admin_gf_manage on public.jobs;
drop policy if exists linecrew_owner_jobs_manage on public.jobs;
drop policy if exists linecrew_superintendent_jobs_manage on public.jobs;
create policy jobs_leadership_insert on public.jobs for insert to authenticated
with check (company_id = (select public.my_company_id()) and (lower(coalesce((select public.my_role()), '')) = any (array['owner','admin','gf']) or (lower(coalesce((select public.my_role()), '')) = 'superintendent' and (select public.linecrew_has_capability('jobs')))));
create policy jobs_leadership_update on public.jobs for update to authenticated
using (company_id = (select public.my_company_id()) and (lower(coalesce((select public.my_role()), '')) = any (array['owner','admin','gf']) or (lower(coalesce((select public.my_role()), '')) = 'superintendent' and (select public.linecrew_has_capability('jobs')))))
with check (company_id = (select public.my_company_id()) and (lower(coalesce((select public.my_role()), '')) = any (array['owner','admin','gf']) or (lower(coalesce((select public.my_role()), '')) = 'superintendent' and (select public.linecrew_has_capability('jobs')))));
create policy jobs_leadership_delete on public.jobs for delete to authenticated
using (company_id = (select public.my_company_id()) and (lower(coalesce((select public.my_role()), '')) = any (array['owner','admin','gf']) or (lower(coalesce((select public.my_role()), '')) = 'superintendent' and (select public.linecrew_has_capability('jobs')))));

-- Pricing tables.
drop policy if exists linecrew_owner_price_book_items_manage on public.price_book_items;
drop policy if exists "Admins can delete price book items" on public.price_book_items;
drop policy if exists "Admins can insert price book items" on public.price_book_items;
drop policy if exists "Admins can update price book items" on public.price_book_items;
create policy price_book_items_leadership_insert on public.price_book_items for insert to authenticated
with check (company_id = (select public.my_company_id()) and lower(coalesce((select public.my_role()), '')) = any (array['owner','admin']));
create policy price_book_items_leadership_update on public.price_book_items for update to authenticated
using (company_id = (select public.my_company_id()) and lower(coalesce((select public.my_role()), '')) = any (array['owner','admin']))
with check (company_id = (select public.my_company_id()) and lower(coalesce((select public.my_role()), '')) = any (array['owner','admin']));
create policy price_book_items_leadership_delete on public.price_book_items for delete to authenticated
using (company_id = (select public.my_company_id()) and lower(coalesce((select public.my_role()), '')) = any (array['owner','admin']));

drop policy if exists linecrew_owner_price_books_manage on public.price_books;
drop policy if exists price_books_admin_manage on public.price_books;
create policy price_books_leadership_insert on public.price_books for insert to authenticated
with check (company_id = (select public.my_company_id()) and lower(coalesce((select public.my_role()), '')) = any (array['owner','admin']));
create policy price_books_leadership_update on public.price_books for update to authenticated
using (company_id = (select public.my_company_id()) and lower(coalesce((select public.my_role()), '')) = any (array['owner','admin']))
with check (company_id = (select public.my_company_id()) and lower(coalesce((select public.my_role()), '')) = any (array['owner','admin']));
create policy price_books_leadership_delete on public.price_books for delete to authenticated
using (company_id = (select public.my_company_id()) and lower(coalesce((select public.my_role()), '')) = any (array['owner','admin']));

drop policy if exists linecrew_owner_unit_prices_manage on public.unit_prices;
drop policy if exists unit_prices_admin_manage on public.unit_prices;
create policy unit_prices_leadership_insert on public.unit_prices for insert to authenticated
with check (company_id = (select public.my_company_id()) and lower(coalesce((select public.my_role()), '')) = any (array['owner','admin']));
create policy unit_prices_leadership_update on public.unit_prices for update to authenticated
using (company_id = (select public.my_company_id()) and lower(coalesce((select public.my_role()), '')) = any (array['owner','admin']))
with check (company_id = (select public.my_company_id()) and lower(coalesce((select public.my_role()), '')) = any (array['owner','admin']));
create policy unit_prices_leadership_delete on public.unit_prices for delete to authenticated
using (company_id = (select public.my_company_id()) and lower(coalesce((select public.my_role()), '')) = any (array['owner','admin']));

-- Production policy groups.
drop policy if exists "Admins can delete production items" on public.daily_production_items;
drop policy if exists linecrew_owner_production_items_delete on public.daily_production_items;
create policy production_items_leadership_delete on public.daily_production_items for delete to authenticated
using (company_id = (select public.my_company_id()) and lower(coalesce((select public.my_role()), '')) = any (array['owner','admin']));

drop policy if exists linecrew_owner_daily_reports_delete on public.daily_reports;
drop policy if exists reports_admin_gf_delete on public.daily_reports;
create policy daily_reports_leadership_delete on public.daily_reports for delete to authenticated
using (company_id = (select public.my_company_id()) and lower(coalesce((select public.my_role()), '')) = any (array['owner','admin','gf']));
drop policy if exists linecrew_owner_daily_reports_update on public.daily_reports;
drop policy if exists reports_admin_gf_update on public.daily_reports;
create policy daily_reports_leadership_update on public.daily_reports for update to authenticated
using (company_id = (select public.my_company_id()) and lower(coalesce((select public.my_role()), '')) = any (array['owner','admin','gf']))
with check (company_id = (select public.my_company_id()) and lower(coalesce((select public.my_role()), '')) = any (array['owner','admin','gf']));

drop policy if exists linecrew_owner_report_units_delete on public.report_units;
drop policy if exists report_units_admin_gf_delete on public.report_units;
create policy report_units_leadership_delete on public.report_units for delete to authenticated
using (company_id = (select public.my_company_id()) and lower(coalesce((select public.my_role()), '')) = any (array['owner','admin','gf']));
drop policy if exists linecrew_owner_report_units_update on public.report_units;
drop policy if exists report_units_admin_gf_update on public.report_units;
create policy report_units_leadership_update on public.report_units for update to authenticated
using (company_id = (select public.my_company_id()) and lower(coalesce((select public.my_role()), '')) = any (array['owner','admin','gf']))
with check (company_id = (select public.my_company_id()) and lower(coalesce((select public.my_role()), '')) = any (array['owner','admin','gf']));

-- The role-scoped SELECT already includes leaders; split ALL into mutation-only policies.
drop policy if exists timekeeping_employees_manage_leaders on public.timekeeping_employees;
create policy timekeeping_employees_leadership_insert on public.timekeeping_employees for insert to authenticated
with check (company_id = (select public.my_company_id()) and (select public.current_user_has_active_profile()) and lower(coalesce((select public.my_role()), '')) = any (array['owner','admin','gf']));
create policy timekeeping_employees_leadership_update on public.timekeeping_employees for update to authenticated
using (company_id = (select public.my_company_id()) and (select public.current_user_has_active_profile()) and lower(coalesce((select public.my_role()), '')) = any (array['owner','admin','gf']))
with check (company_id = (select public.my_company_id()) and (select public.current_user_has_active_profile()) and lower(coalesce((select public.my_role()), '')) = any (array['owner','admin','gf']));
create policy timekeeping_employees_leadership_delete on public.timekeeping_employees for delete to authenticated
using (company_id = (select public.my_company_id()) and (select public.current_user_has_active_profile()) and lower(coalesce((select public.my_role()), '')) = any (array['owner','admin','gf']));

-- Cache auth.uid() once per statement in the remaining affected policies.
alter policy company_same_company_select on public.companies using ((id = (select public.my_company_id())) or (created_by = (select auth.uid())));
alter policy profiles_same_company_select on public.profiles using ((company_id = (select public.my_company_id())) or (id = (select auth.uid())));
alter policy reports_foreman_insert on public.daily_reports with check (company_id = (select public.my_company_id()) and foreman_id = (select auth.uid()));
alter policy daily_report_jsas_role_scoped_select on public.daily_report_jsas using (company_id = (select public.my_company_id()) and (created_by = (select auth.uid()) or lower(coalesce((select public.my_role()), '')) = any (array['owner','admin','gf']) or (lower(coalesce((select public.my_role()), '')) = 'superintendent' and (select public.linecrew_has_capability('safety_records')))));
alter policy job_leader_assignments_role_scoped_select on public.job_leader_assignments using (company_id = (select public.my_company_id()) and (select public.current_user_has_active_profile()) and (member_id = (select auth.uid()) or lower(coalesce((select public.my_role()), '')) = any (array['owner','admin','gf']) or (lower(coalesce((select public.my_role()), '')) = 'superintendent' and (select public.linecrew_has_capability('jobs')))));
alter policy "jsa attachment role scoped read" on public.jsa_upload_attachments
using (
  company_id = (select public.my_company_id())
  and exists (
    select 1
    from public.daily_report_jsas j
    where j.id = jsa_upload_attachments.jsa_id
      and j.company_id = jsa_upload_attachments.company_id
  )
);

alter policy training_progress_read_own_company on public.training_progress using (user_id = (select auth.uid()) or exists (select 1 from public.profiles p where p.id = (select auth.uid()) and p.company_id = training_progress.company_id and lower(coalesce(p.role, '')) = any (array['owner','admin']) and coalesce(p.active, true)));
alter policy training_progress_update_own on public.training_progress using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));
alter policy training_progress_write_own on public.training_progress with check (user_id = (select auth.uid()) and exists (select 1 from public.current_training_access() a where a.company_id = training_progress.company_id and a.can_train));

alter policy timekeeping_entries_delete_company on public.timekeeping_entries using (company_id = (select p.company_id from public.profiles p where p.id = (select auth.uid())) and (created_by = (select auth.uid()) or lower(coalesce((select p.role from public.profiles p where p.id = (select auth.uid())), '')) = any (array['gf','admin','owner'])));
alter policy timekeeping_entries_select_company on public.timekeeping_entries
using (
  company_id = (select p.company_id from public.profiles p where p.id = (select auth.uid()))
  and (
    lower(coalesce((select p.role from public.profiles p where p.id = (select auth.uid())), '')) = any (array['gf','admin','owner'])
    or (
      lower(coalesce((select p.role from public.profiles p where p.id = (select auth.uid())), '')) = 'foreman'
      and (
        created_by = (select auth.uid())
        or exists (
          select 1 from public.timekeeping_employees te
          where te.id = timekeeping_entries.employee_id
            and te.company_id = timekeeping_entries.company_id
            and te.assigned_foreman_id = (select auth.uid())
        )
      )
    )
  )
);
alter policy timekeeping_entry_history_select_company on public.timekeeping_entry_history
using (
  company_id = (select p.company_id from public.profiles p where p.id = (select auth.uid()))
  and (
    lower(coalesce((select p.role from public.profiles p where p.id = (select auth.uid())), '')) = any (array['gf','admin','owner'])
    or (
      lower(coalesce((select p.role from public.profiles p where p.id = (select auth.uid())), '')) = 'foreman'
      and (
        created_by = (select auth.uid())
        or exists (
          select 1 from public.timekeeping_employees te
          where te.id = timekeeping_entry_history.employee_id
            and te.company_id = timekeeping_entry_history.company_id
            and te.assigned_foreman_id = (select auth.uid())
        )
      )
    )
  )
);
alter policy timekeeping_pay_periods_select_company on public.timekeeping_pay_periods using (company_id = (select p.company_id from public.profiles p where p.id = (select auth.uid())));
alter policy timekeeping_pay_period_audit_select_company on public.timekeeping_pay_period_audit using (company_id = (select p.company_id from public.profiles p where p.id = (select auth.uid())));

alter policy timekeeping_entries_role_scoped_insert on public.timekeeping_entries
with check (
  company_id = (select public.my_company_id())
  and (select public.current_user_has_active_profile())
  and created_by = (select auth.uid())
  and updated_by = (select auth.uid())
  and exists (
    select 1 from public.timekeeping_employees employee
    where employee.id = timekeeping_entries.employee_id
      and employee.company_id = timekeeping_entries.company_id
      and employee.active is true
      and (
        lower(coalesce((select public.my_role()), '')) = any (array['owner','admin','gf'])
        or (
          lower(coalesce((select public.my_role()), '')) = 'foreman'
          and (select public.linecrew_foreman_has_job_assignment(timekeeping_entries.job_id))
        )
      )
  )
);
alter policy timekeeping_entries_role_scoped_update on public.timekeeping_entries
using (
  company_id = (select public.my_company_id())
  and (select public.current_user_has_active_profile())
  and (
    lower(coalesce((select public.my_role()), '')) = any (array['owner','admin','gf'])
    or created_by = (select auth.uid())
  )
)
with check (
  company_id = (select public.my_company_id())
  and updated_by = (select auth.uid())
  and exists (
    select 1 from public.timekeeping_employees employee
    where employee.id = timekeeping_entries.employee_id
      and employee.company_id = timekeeping_entries.company_id
      and employee.active is true
      and (
        lower(coalesce((select public.my_role()), '')) = any (array['owner','admin','gf'])
        or (
          lower(coalesce((select public.my_role()), '')) = 'foreman'
          and (select public.linecrew_foreman_has_job_assignment(timekeeping_entries.job_id))
        )
      )
  )
);
