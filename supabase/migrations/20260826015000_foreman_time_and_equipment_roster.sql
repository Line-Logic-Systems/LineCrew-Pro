begin;

alter table public.timekeeping_employees
  add column if not exists linked_profile_id uuid references public.profiles(id) on delete set null;

create unique index if not exists timekeeping_employees_linked_profile_uidx
  on public.timekeeping_employees(linked_profile_id)
  where linked_profile_id is not null;

create table if not exists public.timekeeping_equipment (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  unit_number text not null,
  description text,
  active boolean not null default true,
  created_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(company_id, unit_number)
);

create index if not exists timekeeping_equipment_company_active_idx
  on public.timekeeping_equipment(company_id, active, unit_number);

alter table public.timekeeping_equipment enable row level security;

drop policy if exists timekeeping_equipment_company_select on public.timekeeping_equipment;
create policy timekeeping_equipment_company_select
on public.timekeeping_equipment for select to authenticated
using (
  company_id = (select public.my_company_id())
  and (select public.current_user_has_active_profile())
);

drop policy if exists timekeeping_equipment_admin_manage on public.timekeeping_equipment;
create policy timekeeping_equipment_admin_manage
on public.timekeeping_equipment for all to authenticated
using (
  company_id = (select public.my_company_id())
  and lower(coalesce((select public.my_role()),'')) in ('owner','admin')
)
with check (
  company_id = (select public.my_company_id())
  and lower(coalesce((select public.my_role()),'')) in ('owner','admin')
);

grant select on public.timekeeping_equipment to authenticated;
grant insert, update, delete on public.timekeeping_equipment to authenticated;

create or replace function public.sync_foreman_timekeeping_employee()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if lower(coalesce(new.role,'')) = 'foreman' and coalesce(new.active,true) is true and new.company_id is not null then
    insert into public.timekeeping_employees(
      company_id, full_name, classification, active, assigned_foreman_id, linked_profile_id, created_by, updated_at
    ) values (
      new.company_id,
      coalesce(nullif(btrim(new.full_name),''),'Foreman'),
      'Foreman',
      true,
      new.id,
      new.id,
      new.id,
      now()
    )
    on conflict (linked_profile_id) where linked_profile_id is not null
    do update set
      company_id = excluded.company_id,
      full_name = excluded.full_name,
      classification = 'Foreman',
      active = true,
      assigned_foreman_id = excluded.assigned_foreman_id,
      updated_at = now();
  elsif new.id is not null then
    update public.timekeeping_employees
      set active = false, updated_at = now()
      where linked_profile_id = new.id;
  end if;
  return new;
end;
$$;

revoke all on function public.sync_foreman_timekeeping_employee() from public, anon, authenticated;

drop trigger if exists sync_foreman_timekeeping_employee_trigger on public.profiles;
create trigger sync_foreman_timekeeping_employee_trigger
after insert or update of role,active,company_id,full_name on public.profiles
for each row execute function public.sync_foreman_timekeeping_employee();

insert into public.timekeeping_employees(
  company_id, full_name, classification, active, assigned_foreman_id, linked_profile_id, created_by, updated_at
)
select p.company_id, coalesce(nullif(btrim(p.full_name),''),'Foreman'), 'Foreman', true, p.id, p.id, p.id, now()
from public.profiles p
where lower(coalesce(p.role,''))='foreman'
  and coalesce(p.active,true) is true
  and p.company_id is not null
on conflict (linked_profile_id) where linked_profile_id is not null
do update set
  company_id=excluded.company_id,
  full_name=excluded.full_name,
  classification='Foreman',
  active=true,
  assigned_foreman_id=excluded.assigned_foreman_id,
  updated_at=now();

commit;