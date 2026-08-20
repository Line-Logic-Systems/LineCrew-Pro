begin;

create table if not exists public.timekeeping_employees (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  employee_number text,
  full_name text not null,
  classification text,
  default_crew_name text,
  active boolean not null default true,
  created_by uuid default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists timekeeping_employees_company_employee_number_uidx
  on public.timekeeping_employees(company_id, lower(employee_number))
  where employee_number is not null and btrim(employee_number) <> '';

create index if not exists timekeeping_employees_company_active_idx
  on public.timekeeping_employees(company_id, active, full_name);

create table if not exists public.timekeeping_entries (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  employee_id uuid not null references public.timekeeping_employees(id) on delete restrict,
  daily_report_id uuid references public.daily_reports(id) on delete set null,
  job_id uuid references public.jobs(id) on delete set null,
  work_date date not null,
  crew_name text,
  regular_hours numeric(6,2) not null default 0 check (regular_hours >= 0 and regular_hours <= 24),
  overtime_hours numeric(6,2) not null default 0 check (overtime_hours >= 0 and overtime_hours <= 24),
  storm_work boolean not null default false,
  notes text,
  created_by uuid not null default auth.uid(),
  updated_by uuid not null default auth.uid(),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint timekeeping_entry_hours_check check (regular_hours + overtime_hours <= 24)
);

create unique index if not exists timekeeping_entries_employee_day_job_uidx
  on public.timekeeping_entries(company_id, employee_id, work_date, coalesce(job_id, '00000000-0000-0000-0000-000000000000'::uuid));

create index if not exists timekeeping_entries_company_date_idx
  on public.timekeeping_entries(company_id, work_date desc);
create index if not exists timekeeping_entries_company_employee_idx
  on public.timekeeping_entries(company_id, employee_id, work_date desc);
create index if not exists timekeeping_entries_daily_report_idx
  on public.timekeeping_entries(daily_report_id)
  where daily_report_id is not null;
create index if not exists timekeeping_entries_job_idx
  on public.timekeeping_entries(job_id)
  where job_id is not null;

alter table public.timekeeping_employees enable row level security;
alter table public.timekeeping_entries enable row level security;

-- Everyone in the contractor can see the active roster; only GF/Admin manage it.
drop policy if exists timekeeping_employees_select_company on public.timekeeping_employees;
create policy timekeeping_employees_select_company
on public.timekeeping_employees for select
to authenticated
using (
  company_id = (select p.company_id from public.profiles p where p.id = auth.uid())
);

drop policy if exists timekeeping_employees_manage_leaders on public.timekeeping_employees;
create policy timekeeping_employees_manage_leaders
on public.timekeeping_employees for all
to authenticated
using (
  company_id = (select p.company_id from public.profiles p where p.id = auth.uid())
  and lower(coalesce((select p.role from public.profiles p where p.id = auth.uid()), '')) in ('gf','admin')
)
with check (
  company_id = (select p.company_id from public.profiles p where p.id = auth.uid())
  and lower(coalesce((select p.role from public.profiles p where p.id = auth.uid()), '')) in ('gf','admin')
);

-- All company members can read time. Foremen can maintain entries they created;
-- GF/Admin can maintain any entry in their company.
drop policy if exists timekeeping_entries_select_company on public.timekeeping_entries;
create policy timekeeping_entries_select_company
on public.timekeeping_entries for select
to authenticated
using (
  company_id = (select p.company_id from public.profiles p where p.id = auth.uid())
);

drop policy if exists timekeeping_entries_insert_company on public.timekeeping_entries;
create policy timekeeping_entries_insert_company
on public.timekeeping_entries for insert
to authenticated
with check (
  company_id = (select p.company_id from public.profiles p where p.id = auth.uid())
  and created_by = auth.uid()
  and updated_by = auth.uid()
  and exists (
    select 1 from public.timekeeping_employees e
    where e.id = employee_id and e.company_id = company_id
  )
);

drop policy if exists timekeeping_entries_update_company on public.timekeeping_entries;
create policy timekeeping_entries_update_company
on public.timekeeping_entries for update
to authenticated
using (
  company_id = (select p.company_id from public.profiles p where p.id = auth.uid())
  and (
    created_by = auth.uid()
    or lower(coalesce((select p.role from public.profiles p where p.id = auth.uid()), '')) in ('gf','admin')
  )
)
with check (
  company_id = (select p.company_id from public.profiles p where p.id = auth.uid())
  and exists (
    select 1 from public.timekeeping_employees e
    where e.id = employee_id and e.company_id = company_id
  )
);

drop policy if exists timekeeping_entries_delete_company on public.timekeeping_entries;
create policy timekeeping_entries_delete_company
on public.timekeeping_entries for delete
to authenticated
using (
  company_id = (select p.company_id from public.profiles p where p.id = auth.uid())
  and (
    created_by = auth.uid()
    or lower(coalesce((select p.role from public.profiles p where p.id = auth.uid()), '')) in ('gf','admin')
  )
);

grant select on public.timekeeping_employees to authenticated;
grant insert, update, delete on public.timekeeping_employees to authenticated;
grant select, insert, update, delete on public.timekeeping_entries to authenticated;

commit;
