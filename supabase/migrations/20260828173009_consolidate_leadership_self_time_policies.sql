begin;

-- Consolidate the additive My Time policies into the existing role-scoped
-- policies so Postgres evaluates one permissive policy per action.
drop policy if exists timekeeping_employees_select_own_profile on public.timekeeping_employees;
drop policy if exists timekeeping_employees_role_scoped_select on public.timekeeping_employees;
create policy timekeeping_employees_role_scoped_select
on public.timekeeping_employees for select to authenticated
using (
  company_id = (select public.my_company_id())
  and (select public.current_user_has_active_profile())
  and (
    lower(coalesce((select public.my_role()),'')) in ('owner','admin','gf')
    or (lower(coalesce((select public.my_role()),'')) = 'superintendent'
      and (select public.linecrew_has_capability('reporting')))
    or (lower(coalesce((select public.my_role()),'')) = 'foreman' and active is true)
    or linked_profile_id = (select auth.uid())
  )
);

drop policy if exists timekeeping_entries_select_own_leadership on public.timekeeping_entries;
drop policy if exists timekeeping_entries_select_company on public.timekeeping_entries;
create policy timekeeping_entries_select_company
on public.timekeeping_entries for select to authenticated
using (
  company_id = (select public.my_company_id())
  and (
    lower(coalesce((select public.my_role()),'')) in ('gf','admin','owner')
    or (lower(coalesce((select public.my_role()),'')) = 'superintendent'
      and (select public.linecrew_has_capability('reporting')))
    or (entry_kind = 'leadership_self' and exists (
      select 1 from public.timekeeping_employees employee
      where employee.id = timekeeping_entries.employee_id
        and employee.company_id = timekeeping_entries.company_id
        and employee.linked_profile_id = (select auth.uid())
    ))
    or (lower(coalesce((select public.my_role()),'')) = 'foreman' and (
      created_by = (select auth.uid())
      or exists (
        select 1 from public.timekeeping_employees employee
        where employee.id = timekeeping_entries.employee_id
          and employee.company_id = timekeeping_entries.company_id
          and employee.assigned_foreman_id = (select auth.uid())
      )
    ))
  )
);

drop policy if exists timekeeping_entries_insert_own_leadership on public.timekeeping_entries;
drop policy if exists timekeeping_entries_role_scoped_insert on public.timekeeping_entries;
create policy timekeeping_entries_role_scoped_insert
on public.timekeeping_entries for insert to authenticated
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
        lower(coalesce((select public.my_role()),'')) in ('owner','admin','gf')
        or (
          lower(coalesce((select public.my_role()),'')) = 'foreman'
          and (select public.linecrew_foreman_has_job_assignment(timekeeping_entries.job_id))
        )
        or (
          lower(coalesce((select public.my_role()),'')) in ('gf','superintendent','admin','owner')
          and entry_kind = 'leadership_self'
          and daily_report_id is null
          and employee.linked_profile_id = (select auth.uid())
        )
      )
  )
);

drop policy if exists timekeeping_entries_update_own_leadership on public.timekeeping_entries;
drop policy if exists timekeeping_entries_role_scoped_update on public.timekeeping_entries;
create policy timekeeping_entries_role_scoped_update
on public.timekeeping_entries for update to authenticated
using (
  company_id = (select public.my_company_id())
  and (select public.current_user_has_active_profile())
  and (
    lower(coalesce((select public.my_role()),'')) in ('owner','admin','gf')
    or created_by = (select auth.uid())
    or (entry_kind = 'leadership_self' and exists (
      select 1 from public.timekeeping_employees employee
      where employee.id = timekeeping_entries.employee_id
        and employee.company_id = timekeeping_entries.company_id
        and employee.linked_profile_id = (select auth.uid())
    ))
  )
)
with check (
  company_id = (select public.my_company_id())
  and (select public.current_user_has_active_profile())
  and updated_by = (select auth.uid())
  and exists (
    select 1 from public.timekeeping_employees employee
    where employee.id = timekeeping_entries.employee_id
      and employee.company_id = timekeeping_entries.company_id
      and employee.active is true
      and (
        lower(coalesce((select public.my_role()),'')) in ('owner','admin','gf')
        or (
          lower(coalesce((select public.my_role()),'')) = 'foreman'
          and (select public.linecrew_foreman_has_job_assignment(timekeeping_entries.job_id))
        )
        or (
          lower(coalesce((select public.my_role()),'')) in ('gf','superintendent','admin','owner')
          and entry_kind = 'leadership_self'
          and daily_report_id is null
          and employee.linked_profile_id = (select auth.uid())
        )
      )
  )
);

drop policy if exists timekeeping_entries_delete_own_leadership on public.timekeeping_entries;
drop policy if exists timekeeping_entries_delete_company on public.timekeeping_entries;
create policy timekeeping_entries_delete_company
on public.timekeeping_entries for delete to authenticated
using (
  company_id = (select public.my_company_id())
  and (select public.current_user_has_active_profile())
  and (
    created_by = (select auth.uid())
    or lower(coalesce((select public.my_role()),'')) in ('gf','admin','owner')
    or (entry_kind = 'leadership_self' and exists (
      select 1 from public.timekeeping_employees employee
      where employee.id = timekeeping_entries.employee_id
        and employee.company_id = timekeeping_entries.company_id
        and employee.linked_profile_id = (select auth.uid())
    ))
  )
);

commit;
