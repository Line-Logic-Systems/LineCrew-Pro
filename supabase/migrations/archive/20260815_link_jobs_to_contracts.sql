begin;

alter table public.jobs
  add column if not exists contract_id uuid null
    references public.contracts(id) on delete restrict;

create index if not exists jobs_company_contract_idx
  on public.jobs(company_id, contract_id);

create or replace function public.create_contract_job(
  p_contract_id uuid,
  p_job_number text,
  p_job_name text
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
  v_customer_name text;
  v_job_id uuid;
begin
  select p.company_id, lower(coalesce(p.role, '')), p.active
  into v_company_id, v_role, v_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin', 'gf') then
    raise exception using
      errcode = '42501',
      message = 'Only an active Admin or General Foreman can create jobs.';
  end if;

  if length(trim(coalesce(p_job_number, ''))) = 0 or
     length(trim(coalesce(p_job_name, ''))) = 0 then
    raise exception using
      errcode = '22023',
      message = 'Job number and job name are required.';
  end if;

  select customer.name
  into v_customer_name
  from public.contracts contract
  join public.customers customer
    on customer.id = contract.customer_id
   and customer.company_id = contract.company_id
  where contract.id = p_contract_id
    and contract.company_id = v_company_id
    and contract.active is true;

  if v_customer_name is null then
    raise exception using
      errcode = 'P0002',
      message = 'Active contract was not found in your company.';
  end if;

  insert into public.jobs (
    company_id,
    contract_id,
    job_number,
    job_name,
    customer_name,
    utility_name,
    active
  ) values (
    v_company_id,
    p_contract_id,
    trim(p_job_number),
    trim(p_job_name),
    v_customer_name,
    v_customer_name,
    true
  )
  returning id into v_job_id;

  return v_job_id;
end;
$$;

revoke all on function public.create_contract_job(uuid, text, text)
from public;
revoke all on function public.create_contract_job(uuid, text, text)
from anon;
grant execute on function public.create_contract_job(uuid, text, text)
to authenticated;

create or replace function public.update_contract_job(
  p_job_id uuid,
  p_contract_id uuid,
  p_job_number text,
  p_job_name text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_customer_name text;
begin
  select p.company_id, lower(coalesce(p.role, '')), p.active
  into v_company_id, v_role, v_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin', 'gf') then
    raise exception using
      errcode = '42501',
      message = 'Only an active Admin or General Foreman can update jobs.';
  end if;

  if length(trim(coalesce(p_job_number, ''))) = 0 or
     length(trim(coalesce(p_job_name, ''))) = 0 then
    raise exception using
      errcode = '22023',
      message = 'Job number and job name are required.';
  end if;

  select customer.name
  into v_customer_name
  from public.contracts contract
  join public.customers customer
    on customer.id = contract.customer_id
   and customer.company_id = contract.company_id
  where contract.id = p_contract_id
    and contract.company_id = v_company_id
    and contract.active is true;

  if v_customer_name is null then
    raise exception using
      errcode = 'P0002',
      message = 'Active contract was not found in your company.';
  end if;

  update public.jobs
  set
    contract_id = p_contract_id,
    job_number = trim(p_job_number),
    job_name = trim(p_job_name),
    customer_name = v_customer_name,
    utility_name = v_customer_name
  where id = p_job_id
    and company_id = v_company_id;

  if not found then
    raise exception using
      errcode = 'P0002',
      message = 'Job was not found in your company.';
  end if;
end;
$$;

revoke all on function public.update_contract_job(uuid, uuid, text, text)
from public;
revoke all on function public.update_contract_job(uuid, uuid, text, text)
from anon;
grant execute on function public.update_contract_job(uuid, uuid, text, text)
to authenticated;

commit;
