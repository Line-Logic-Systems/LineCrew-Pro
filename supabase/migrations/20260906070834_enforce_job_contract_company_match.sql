-- Contract-level utility access makes this relationship a security boundary.
-- Null contract_id remains valid and deliberately invisible to utilities.
create or replace function public.linecrew_enforce_job_contract_company_match()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if new.contract_id is not null and not exists (
    select 1
    from public.contracts contract
    where contract.id = new.contract_id
      and contract.company_id = new.company_id
  ) then
    raise exception using
      errcode = '23514',
      message = 'Job contract does not belong to the job company.';
  end if;

  return new;
end;
$function$;

revoke all on function public.linecrew_enforce_job_contract_company_match()
  from public, anon, authenticated, service_role;

create trigger linecrew_job_contract_company_match
before insert or update of company_id, contract_id on public.jobs
for each row
execute function public.linecrew_enforce_job_contract_company_match();

-- Changing a referenced contract's company would invalidate both job ownership
-- and utility grants. Allow unreferenced cleanup, but reject referenced moves.
create or replace function public.linecrew_block_referenced_contract_company_move()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
begin
  if new.company_id is distinct from old.company_id and (
    exists (select 1 from public.jobs job where job.contract_id = old.id)
    or exists (
      select 1
      from public.utility_contract_access access
      where access.contract_id = old.id
    )
  ) then
    raise exception using
      errcode = '23514',
      message = 'A referenced contract cannot move between companies.';
  end if;
  return new;
end;
$function$;

revoke all on function public.linecrew_block_referenced_contract_company_move()
  from public, anon, authenticated, service_role;

create trigger linecrew_referenced_contract_company_move_block
before update of company_id on public.contracts
for each row
when (old.company_id is distinct from new.company_id)
execute function public.linecrew_block_referenced_contract_company_move();
