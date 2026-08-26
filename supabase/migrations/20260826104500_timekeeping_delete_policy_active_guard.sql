-- Align timekeeping DELETE with the active-profile guard already used by
-- SELECT/INSERT/UPDATE and by the company helper functions.
drop policy if exists timekeeping_entries_delete_company on public.timekeeping_entries;
create policy timekeeping_entries_delete_company
on public.timekeeping_entries
for delete
to authenticated
using (
  company_id = (select public.my_company_id())
  and (select public.current_user_has_active_profile())
  and (
    created_by = (select auth.uid())
    or lower(coalesce((select public.my_role()),'')) in ('gf','admin','owner')
  )
);
