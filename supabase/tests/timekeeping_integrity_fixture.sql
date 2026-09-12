-- Minimal fixture reproducing the production shape of the objects the
-- migration touches. Not a schema clone: just enough to execute the real
-- function bodies and assert their behaviour.
create schema if not exists auth;
create schema if not exists private;

create table public.companies (
  id uuid primary key,
  week_start_day smallint not null default 1 check (week_start_day between 0 and 6)
);

create table public.profiles (
  id uuid primary key,
  company_id uuid not null references public.companies(id),
  role text not null,
  active boolean not null default true
);

create table public.daily_reports (
  id uuid primary key,
  company_id uuid not null references public.companies(id),
  job_id uuid,
  foreman_id uuid,
  created_by uuid,
  work_date date not null,
  status text not null default 'draft',
  archived boolean not null default false,
  reviewed_at timestamptz,
  review_notes text,
  regular_hours numeric not null default 0,
  overtime_hours numeric not null default 0,
  hours numeric not null default 0,
  updated_at timestamptz not null default now()
);

create table public.timekeeping_employees (
  id uuid primary key,
  company_id uuid not null references public.companies(id),
  active boolean not null default true,
  linked_profile_id uuid
);

create table public.timekeeping_entries (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  employee_id uuid not null references public.timekeeping_employees(id),
  daily_report_id uuid references public.daily_reports(id) on delete set null,
  job_id uuid,
  work_date date not null,
  regular_hours numeric not null default 0,
  overtime_hours numeric not null default 0,
  start_time time,
  stop_time time,
  lunch_minutes integer not null default 0,
  per_diem boolean not null default false,
  equipment_used text,
  equipment_not_used boolean not null default false,
  crew_name text,
  labor_code text,
  entry_kind text not null default 'crew',
  storm_work boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  created_by uuid,
  updated_by uuid
);

-- ---- stubs for platform functions the bodies call -----------------------
create table public._session (uid uuid);
insert into public._session values (null);

create or replace function auth.uid() returns uuid
language sql stable as $$ select uid from public._session limit 1 $$;

create or replace function public.set_uid(p uuid) returns void
language sql as $$ update public._session set uid = p $$;

create or replace function public.linecrew_has_capability(p text) returns boolean
language sql stable as $$ select true $$;
