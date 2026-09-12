alter table public.daily_reports
  add column if not exists storm_context_set_at timestamptz;

update public.daily_reports
set storm_context_set_at = coalesce(updated_at, created_at, now())
where storm_context_set_at is null;

create or replace function public.set_daily_report_storm_context(p_report_id uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_report_created_by uuid;
  v_context_set_at timestamptz;
  v_enabled boolean;
  v_event_name text;
  v_assigned boolean;
begin
  select p.company_id, lower(coalesce(p.role,''))
    into v_company_id, v_role
  from public.profiles p
  where p.id = auth.uid()
    and coalesce(p.active,true);

  if v_company_id is null or v_role not in ('foreman','gf','admin','owner','superintendent','manager') then
    raise exception using errcode='42501',
      message='You are not allowed to update this daily report.';
  end if;

  if v_role = 'superintendent' and not public.linecrew_has_capability('storm_mode') then
    raise exception using errcode='42501',
      message='This Superintendent does not have storm mode permission.';
  end if;

  select dr.created_by, dr.storm_context_set_at
    into v_report_created_by, v_context_set_at
  from public.daily_reports dr
  where dr.id = p_report_id
    and dr.company_id = v_company_id
  for update;

  if v_report_created_by is null then
    raise exception using errcode='P0002',
      message='Daily report was not found for your company.';
  end if;

  if v_role = 'foreman' and v_report_created_by <> auth.uid() then
    raise exception using errcode='42501',
      message='Foremen may only update their own daily reports.';
  end if;

  if v_context_set_at is not null then
    return;
  end if;

  select c.storm_mode_enabled, c.storm_event_name,
         exists (
           select 1
           from public.storm_mode_assignments a
           where a.company_id = v_company_id
             and a.user_id = v_report_created_by
         )
    into v_enabled, v_event_name, v_assigned
  from public.companies c
  where c.id = v_company_id;

  update public.daily_reports
  set storm_mode = coalesce(v_enabled,false) and coalesce(v_assigned,false),
      storm_event_name = case
        when coalesce(v_enabled,false) and coalesce(v_assigned,false)
          then v_event_name
        else null
      end,
      storm_context_set_at = now()
  where id = p_report_id
    and company_id = v_company_id
    and storm_context_set_at is null;
end;
$$;

revoke all on function public.set_daily_report_storm_context(uuid) from public, anon;
grant execute on function public.set_daily_report_storm_context(uuid) to authenticated, service_role;

create or replace function public.linecrew_sync_timekeeping_storm_context()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_report_storm boolean;
begin
  if new.daily_report_id is null then
    return new;
  end if;

  select dr.storm_mode
    into v_report_storm
  from public.daily_reports dr
  where dr.id = new.daily_report_id
    and dr.company_id = new.company_id;

  if found then
    new.storm_work := coalesce(v_report_storm,false);
  end if;
  return new;
end;
$$;

revoke all on function public.linecrew_sync_timekeeping_storm_context() from public, anon, authenticated;
grant execute on function public.linecrew_sync_timekeeping_storm_context() to service_role;

drop trigger if exists linecrew_timekeeping_storm_context on public.timekeeping_entries;
create trigger linecrew_timekeeping_storm_context
before insert or update of daily_report_id, storm_work
on public.timekeeping_entries
for each row
execute function public.linecrew_sync_timekeeping_storm_context();
