-- Keep one company-wide SELECT policy while preserving Owner/Admin equipment writes.
-- This removes duplicate permissive SELECT evaluation as equipment rosters grow.
drop policy if exists timekeeping_equipment_admin_manage on public.timekeeping_equipment;

drop policy if exists timekeeping_equipment_admin_insert on public.timekeeping_equipment;
create policy timekeeping_equipment_admin_insert
on public.timekeeping_equipment
for insert
to authenticated
with check (
  company_id = (select public.my_company_id())
  and (select public.current_user_has_active_profile())
  and lower(coalesce((select public.my_role()),'')) in ('owner','admin')
);

drop policy if exists timekeeping_equipment_admin_update on public.timekeeping_equipment;
create policy timekeeping_equipment_admin_update
on public.timekeeping_equipment
for update
to authenticated
using (
  company_id = (select public.my_company_id())
  and (select public.current_user_has_active_profile())
  and lower(coalesce((select public.my_role()),'')) in ('owner','admin')
)
with check (
  company_id = (select public.my_company_id())
  and (select public.current_user_has_active_profile())
  and lower(coalesce((select public.my_role()),'')) in ('owner','admin')
);

drop policy if exists timekeeping_equipment_admin_delete on public.timekeeping_equipment;
create policy timekeeping_equipment_admin_delete
on public.timekeeping_equipment
for delete
to authenticated
using (
  company_id = (select public.my_company_id())
  and (select public.current_user_has_active_profile())
  and lower(coalesce((select public.my_role()),'')) in ('owner','admin')
);

-- Equipment is never a pre-auth resource.
revoke all on table public.timekeeping_equipment from anon;
