-- M1-M3: bounded report history, active-job unit integrity, and duplicate-report prevention.

begin;

create or replace function public.enforce_active_job_for_daily_unit_mutation()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_report_id uuid;
begin
  v_report_id := case when tg_op = 'DELETE' then old.daily_report_id else new.daily_report_id end;

  if not exists (
    select 1
    from public.daily_reports r
    join public.jobs j on j.id = r.job_id and j.company_id = r.company_id
    where r.id = v_report_id
      and j.active is true
  ) then
    raise exception using errcode = '23514',
      message = 'Units cannot be changed after the parent job is closed.';
  end if;

  return case when tg_op = 'DELETE' then old else new end;
end;
$$;

revoke all on function public.enforce_active_job_for_daily_unit_mutation()
  from public, anon, authenticated;

drop trigger if exists enforce_active_job_daily_production_units
  on public.daily_production_units;
create trigger enforce_active_job_daily_production_units
before insert or update or delete on public.daily_production_units
for each row execute function public.enforce_active_job_for_daily_unit_mutation();

drop trigger if exists enforce_active_job_daily_unit_locations
  on public.daily_production_unit_locations;
create trigger enforce_active_job_daily_unit_locations
before insert or update or delete on public.daily_production_unit_locations
for each row execute function public.enforce_active_job_for_daily_unit_mutation();

create or replace function public.prevent_duplicate_daily_report()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if coalesce(new.archived, false) then
    return new;
  end if;

  perform pg_advisory_xact_lock(
    hashtextextended(
      concat_ws('|', new.company_id::text, new.job_id::text,
        new.work_date::text, new.foreman_id::text),
      0
    )
  );

  if exists (
    select 1
    from public.daily_reports existing
    where existing.company_id = new.company_id
      and existing.job_id = new.job_id
      and existing.work_date = new.work_date
      and existing.foreman_id = new.foreman_id
      and coalesce(existing.archived, false) is false
      and existing.id is distinct from new.id
  ) then
    raise exception using errcode = '23505',
      message = 'A Daily Report already exists for this Foreman, job, and work date.';
  end if;

  return new;
end;
$$;

revoke all on function public.prevent_duplicate_daily_report()
  from public, anon, authenticated;

drop trigger if exists prevent_duplicate_daily_report
  on public.daily_reports;
create trigger prevent_duplicate_daily_report
before insert or update of company_id, job_id, work_date, foreman_id, archived
on public.daily_reports
for each row execute function public.prevent_duplicate_daily_report();

commit;
