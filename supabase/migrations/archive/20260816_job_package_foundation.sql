begin;

create table if not exists public.job_packages (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null
    references public.companies(id) on delete cascade,
  job_id uuid not null
    references public.jobs(id) on delete cascade,
  contract_id uuid not null
    references public.contracts(id) on delete restrict,
  package_name text not null,
  package_number text null,
  received_date date null,
  source_filename text null,
  notes text null,
  status text not null default 'draft',
  created_by uuid not null default auth.uid()
    references auth.users(id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint job_packages_name_not_blank
    check (length(trim(package_name)) > 0),
  constraint job_packages_status_supported
    check (status in ('draft', 'active', 'closed'))
);

create index if not exists job_packages_company_job_idx
  on public.job_packages(company_id, job_id, created_at desc);

create index if not exists job_packages_company_contract_idx
  on public.job_packages(company_id, contract_id);

create unique index if not exists job_packages_reference_unique
  on public.job_packages(company_id, job_id, lower(trim(package_number)))
  where package_number is not null and length(trim(package_number)) > 0;

alter table public.job_packages enable row level security;

revoke all on public.job_packages from public;
revoke all on public.job_packages from anon;
revoke all on public.job_packages from authenticated;

create or replace function public.get_job_packages(
  p_job_id uuid default null
)
returns table (
  id uuid,
  job_id uuid,
  contract_id uuid,
  package_name text,
  package_number text,
  received_date date,
  source_filename text,
  notes text,
  status text,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin', 'gf') then
    raise exception using
      errcode = '42501',
      message = 'Only an active Admin or General Foreman can view utility job packages.';
  end if;

  if p_job_id is not null and not exists (
    select 1
    from public.jobs job
    where job.id = p_job_id
      and job.company_id = v_company_id
  ) then
    raise exception using
      errcode = 'P0002',
      message = 'Job was not found in your company.';
  end if;

  return query
  select
    package.id,
    package.job_id,
    package.contract_id,
    package.package_name,
    package.package_number,
    package.received_date,
    package.source_filename,
    package.notes,
    package.status,
    package.created_at,
    package.updated_at
  from public.job_packages package
  where package.company_id = v_company_id
    and (p_job_id is null or package.job_id = p_job_id)
  order by package.created_at desc;
end;
$$;

revoke all on function public.get_job_packages(uuid) from public;
revoke all on function public.get_job_packages(uuid) from anon;
grant execute on function public.get_job_packages(uuid) to authenticated;

create or replace function public.create_job_package(
  p_job_id uuid,
  p_package_name text,
  p_package_number text default null,
  p_received_date date default null,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_contract_id uuid;
  v_package_id uuid;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or v_role <> 'admin' then
    raise exception using
      errcode = '42501',
      message = 'Only an active company Admin can add utility job packages.';
  end if;

  if length(trim(coalesce(p_package_name, ''))) = 0 then
    raise exception using
      errcode = '22023',
      message = 'Package name is required.';
  end if;

  select job.contract_id
  into v_contract_id
  from public.jobs job
  join public.contracts contract
    on contract.id = job.contract_id
   and contract.company_id = job.company_id
  where job.id = p_job_id
    and job.company_id = v_company_id
    and job.active is true;

  if v_contract_id is null then
    raise exception using
      errcode = 'P0002',
      message = 'An active job tied to your company contract is required.';
  end if;

  insert into public.job_packages (
    company_id,
    job_id,
    contract_id,
    package_name,
    package_number,
    received_date,
    notes,
    created_by
  ) values (
    v_company_id,
    p_job_id,
    v_contract_id,
    trim(p_package_name),
    nullif(trim(coalesce(p_package_number, '')), ''),
    p_received_date,
    nullif(trim(coalesce(p_notes, '')), ''),
    auth.uid()
  )
  returning id into v_package_id;

  return v_package_id;
exception
  when unique_violation then
    raise exception using
      errcode = '23505',
      message = 'That utility package reference already exists on this job.';
end;
$$;

revoke all on function public.create_job_package(uuid, text, text, date, text)
from public;
revoke all on function public.create_job_package(uuid, text, text, date, text)
from anon;
grant execute on function public.create_job_package(uuid, text, text, date, text)
to authenticated;

commit;
