-- Repair Utility Portal activity rows that were logged without contractor company_id.
-- Existing rows are backfilled only when the event timestamp maps to exactly one
-- contractor company. Future org-level events are fanned out to every company
-- whose contract grant was active at the event timestamp.

create or replace function public.linecrew_expand_utility_activity_company()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_inserted integer := 0;
begin
  if new.company_id is not null or new.utility_organization_id is null then
    return new;
  end if;

  insert into public.utility_activity_log (
    utility_organization_id,
    utility_user_id,
    actor_user_id,
    company_id,
    contract_id,
    job_id,
    action,
    detail,
    created_at
  )
  select
    new.utility_organization_id,
    new.utility_user_id,
    new.actor_user_id,
    company.company_id,
    new.contract_id,
    new.job_id,
    new.action,
    new.detail,
    new.created_at
  from (
    select distinct access.company_id
    from public.utility_contract_access access
    where access.utility_organization_id = new.utility_organization_id
      and access.granted_at <= new.created_at
      and (access.revoked_at is null or access.revoked_at > new.created_at)
      and (access.expires_at is null or access.expires_at > new.created_at)
  ) company;

  get diagnostics v_inserted = row_count;

  if v_inserted > 0 then
    delete from public.utility_activity_log activity
    where activity.id = new.id;
  end if;

  return new;
end;
$$;

revoke all on function public.linecrew_expand_utility_activity_company() from public, anon, authenticated;
grant execute on function public.linecrew_expand_utility_activity_company() to service_role;

drop trigger if exists utility_activity_log_expand_company on public.utility_activity_log;
create trigger utility_activity_log_expand_company
after insert on public.utility_activity_log
for each row
when (new.company_id is null and new.utility_organization_id is not null)
execute function public.linecrew_expand_utility_activity_company();

-- The currently affected rows each map to one and only one contractor company
-- at their event timestamp. Preserve their original ids/timestamps and fill only
-- that unambiguous company attribution.
with historical_match as (
  select
    activity.id,
    min(access.company_id::text)::uuid as company_id,
    count(distinct access.company_id) as company_count
  from public.utility_activity_log activity
  join public.utility_contract_access access
    on access.utility_organization_id = activity.utility_organization_id
   and access.granted_at <= activity.created_at
   and (access.revoked_at is null or access.revoked_at > activity.created_at)
   and (access.expires_at is null or access.expires_at > activity.created_at)
  where activity.company_id is null
  group by activity.id
)
update public.utility_activity_log activity
set company_id = historical_match.company_id
from historical_match
where activity.id = historical_match.id
  and historical_match.company_count = 1;
