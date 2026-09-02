-- Preserve prior crew-time segments when the same employee/job/day is later saved from another Daily Report.
create table if not exists public.timekeeping_entry_history (
  id uuid primary key default gen_random_uuid(),
  source_entry_id uuid not null,
  company_id uuid not null references public.companies(id) on delete cascade,
  employee_id uuid not null references public.timekeeping_employees(id) on delete cascade,
  daily_report_id uuid references public.daily_reports(id) on delete set null,
  job_id uuid not null references public.jobs(id) on delete cascade,
  work_date date not null,
  crew_name text,
  regular_hours numeric not null default 0,
  overtime_hours numeric not null default 0,
  storm_work boolean not null default false,
  notes text,
  created_by uuid,
  updated_by uuid,
  created_at timestamptz,
  updated_at timestamptz,
  archived_at timestamptz not null default now(),
  check (regular_hours >= 0 and regular_hours <= 24),
  check (overtime_hours >= 0 and overtime_hours <= 24),
  check (regular_hours + overtime_hours <= 24)
);

create index if not exists timekeeping_entry_history_company_date_idx
  on public.timekeeping_entry_history(company_id, work_date desc);
create index if not exists timekeeping_entry_history_employee_idx
  on public.timekeeping_entry_history(company_id, employee_id, work_date desc);
create unique index if not exists timekeeping_entry_history_segment_uidx
  on public.timekeeping_entry_history(source_entry_id, daily_report_id, archived_at);

alter table public.timekeeping_entry_history enable row level security;

drop policy if exists timekeeping_entry_history_select_company on public.timekeeping_entry_history;
create policy timekeeping_entry_history_select_company on public.timekeeping_entry_history
for select to authenticated using (
  company_id = (select p.company_id from public.profiles p where p.id = auth.uid())
);

create or replace function public.archive_timekeeping_segment_on_report_change()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if old.daily_report_id is distinct from new.daily_report_id
     and old.company_id = new.company_id
     and old.employee_id = new.employee_id
     and old.work_date = new.work_date
     and old.job_id = new.job_id then
    insert into public.timekeeping_entry_history(
      source_entry_id,company_id,employee_id,daily_report_id,job_id,work_date,crew_name,
      regular_hours,overtime_hours,storm_work,notes,created_by,updated_by,created_at,updated_at
    ) values (
      old.id,old.company_id,old.employee_id,old.daily_report_id,old.job_id,old.work_date,old.crew_name,
      old.regular_hours,old.overtime_hours,old.storm_work,old.notes,old.created_by,old.updated_by,old.created_at,old.updated_at
    );
  end if;
  return new;
end;
$$;

drop trigger if exists archive_timekeeping_segment_on_report_change on public.timekeeping_entries;
create trigger archive_timekeeping_segment_on_report_change
before update on public.timekeeping_entries
for each row execute function public.archive_timekeeping_segment_on_report_change();

create or replace function public.timekeeping_report_rows(
  p_from date,
  p_through date,
  p_employee uuid default null,
  p_job uuid default null
)
returns table(
  employee_id uuid,
  daily_report_id uuid,
  job_id uuid,
  work_date date,
  crew_name text,
  regular_hours numeric,
  overtime_hours numeric,
  storm_work boolean,
  notes text,
  segment_source text
)
language sql
security definer
set search_path = public
as $$
  with me as (
    select company_id from public.profiles where id = auth.uid()
  ), all_rows as (
    select e.employee_id,e.daily_report_id,e.job_id,e.work_date,e.crew_name,e.regular_hours,e.overtime_hours,e.storm_work,e.notes,'current'::text segment_source,e.company_id
    from public.timekeeping_entries e
    union all
    select h.employee_id,h.daily_report_id,h.job_id,h.work_date,h.crew_name,h.regular_hours,h.overtime_hours,h.storm_work,h.notes,'history'::text,h.company_id
    from public.timekeeping_entry_history h
  )
  select r.employee_id,r.daily_report_id,r.job_id,r.work_date,r.crew_name,r.regular_hours,r.overtime_hours,r.storm_work,r.notes,r.segment_source
  from all_rows r, me
  where r.company_id = me.company_id
    and r.work_date between p_from and p_through
    and (p_employee is null or r.employee_id = p_employee)
    and (p_job is null or r.job_id = p_job)
  order by r.work_date desc, r.employee_id;
$$;

grant execute on function public.timekeeping_report_rows(date,date,uuid,uuid) to authenticated;
