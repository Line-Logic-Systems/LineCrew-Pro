-- Close the timekeeping integrity gaps found in the post-#601 clean-room audit.
-- Additive and idempotent: no customer data is rewritten by this migration.
--
-- 1. Manager could never save leadership time (raw 42501 from a private-schema
--    gate that the public-schema parity sweep never matched).
-- 2. The approved-report guard inspected only the destination report, so crew
--    time could be moved OFF an approved Daily Report onto a draft one.
-- 3. Both weekly recalculators rewrote every non-approved Daily Report in the
--    company for the week, once per employee (lock amplification / deadlock).

---------------------------------------------------------------------------
-- 1. Approved Daily Report crew time is immutable in BOTH directions.
--
-- Previously: v_report_id := coalesce(new.daily_report_id, old.daily_report_id).
-- On UPDATE that is always the DESTINATION report, so moving an entry from an
-- approved report to a draft one evaluated the draft, returned early, and the
-- protected-column list (which includes daily_report_id itself) was never
-- reached. Now both the source and the destination are checked.
---------------------------------------------------------------------------
create or replace function public.guard_approved_daily_report_timekeeping()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_old_report_id uuid;
  v_new_report_id uuid;
  v_report_id uuid;
  v_status text;
  v_old_status text;
  v_new_status text;
begin
  -- OLD is unassigned on INSERT and NEW is unassigned on DELETE, so every
  -- reference to them must sit inside a TG_OP branch.
  if tg_op = 'INSERT' then
    v_report_id := new.daily_report_id;
  elsif tg_op = 'DELETE' then
    v_report_id := old.daily_report_id;
  else
    v_old_report_id := old.daily_report_id;
    v_new_report_id := new.daily_report_id;
  end if;

  if tg_op in ('INSERT','DELETE') then
    if v_report_id is null then return coalesce(new,old); end if;
    select lower(coalesce(report.status,'draft')) into v_status
    from public.daily_reports report where report.id = v_report_id;
    if coalesce(v_status,'') <> 'approved' then return coalesce(new,old); end if;
    raise exception using errcode='23514',
      message='Approved Daily Report crew time is read-only. Reopen or return the report before changing time.';
  end if;

  -- UPDATE: an approved report must be immutable whether it is the row's
  -- current owner or the row's intended destination.
  select lower(coalesce(report.status,'draft')) into v_old_status
  from public.daily_reports report where report.id = v_old_report_id;
  select lower(coalesce(report.status,'draft')) into v_new_status
  from public.daily_reports report where report.id = v_new_report_id;

  if coalesce(v_old_status,'') <> 'approved' and coalesce(v_new_status,'') <> 'approved' then
    return new;
  end if;

  -- Re-parenting an entry away from (or onto) an approved report is never
  -- allowed, regardless of which side is approved.
  if new.daily_report_id is distinct from old.daily_report_id then
    raise exception using errcode='23514',
      message='Approved Daily Report crew time is read-only. Reopen or return the report before changing time.';
  end if;

  if new.employee_id is distinct from old.employee_id or
     new.job_id is distinct from old.job_id or new.work_date is distinct from old.work_date or
     new.regular_hours is distinct from old.regular_hours or new.overtime_hours is distinct from old.overtime_hours or
     new.start_time is distinct from old.start_time or new.stop_time is distinct from old.stop_time or
     new.lunch_minutes is distinct from old.lunch_minutes or new.per_diem is distinct from old.per_diem or
     new.equipment_used is distinct from old.equipment_used or new.equipment_not_used is distinct from old.equipment_not_used or
     new.crew_name is distinct from old.crew_name or new.labor_code is distinct from old.labor_code or
     new.entry_kind is distinct from old.entry_kind or
     (new.storm_work is distinct from old.storm_work and
       coalesce(current_setting('linecrew.allow_storm_reclassification',true),'') <> 'on')
  then
    raise exception using errcode='23514',
      message='Approved Daily Report crew time is read-only. Reopen or return the report before changing time.';
  end if;

  return new;
end;
$function$;

---------------------------------------------------------------------------
-- 2. Report-header totals must follow the entry to BOTH reports.
--
-- Previously this refreshed only coalesce(new..., old...), i.e. the
-- destination, so a source report kept certified totals with no entries
-- behind them. Re-parenting off an approved report is now blocked outright
-- (above), but a draft-to-draft move must still refresh both headers.
---------------------------------------------------------------------------
create or replace function public.sync_daily_report_hours_from_timekeeping()
returns trigger
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_report_ids uuid[] := '{}';
  v_report_id uuid;
  v_reg numeric := 0;
  v_ot numeric := 0;
begin
  if tg_op in ('INSERT','UPDATE') and new.daily_report_id is not null then
    v_report_ids := array_append(v_report_ids, new.daily_report_id);
  end if;
  if tg_op in ('UPDATE','DELETE') and old.daily_report_id is not null
     and not (old.daily_report_id = any(v_report_ids)) then
    v_report_ids := array_append(v_report_ids, old.daily_report_id);
  end if;

  if array_length(v_report_ids,1) is null then
    return coalesce(new, old);
  end if;

  foreach v_report_id in array v_report_ids
  loop
    select coalesce(sum(t.regular_hours),0), coalesce(sum(t.overtime_hours),0)
      into v_reg, v_ot
    from public.timekeeping_entries t
    where t.daily_report_id = v_report_id;

    update public.daily_reports d
       set regular_hours = v_reg,
           overtime_hours = v_ot,
           hours = v_reg + v_ot,
           updated_at = now()
     where d.id = v_report_id;
  end loop;

  return coalesce(new, old);
end;
$function$;

---------------------------------------------------------------------------
-- 3. Scope the weekly header refresh to the reports this employee touched.
--
-- IMPORTANT: the aggregate itself must still sum EVERY employee on those
-- reports -- a Daily Report header is the whole crew's total, not one
-- person's. Only the SET OF REPORTS is narrowed. Narrowing the aggregate
-- instead would silently rewrite each header to a single employee's hours.
---------------------------------------------------------------------------
create or replace function public.recalculate_timekeeping_employee_week(p_report_id uuid, p_employee_id uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_report_company_id uuid;
  v_report_foreman_id uuid;
  v_work_date date;
  v_week_start_day int;
  v_week_start date;
  v_week_end date;
  v_running numeric := 0;
  v_total numeric;
  v_regular numeric;
  v_overtime numeric;
  rec record;
begin
  select p.company_id, lower(coalesce(p.role,'')), p.active
    into v_company_id, v_role, v_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_active is not true
     or v_role not in ('foreman','gf','admin','manager','owner','superintendent') then
    raise exception using errcode='42501', message='An active company timekeeping role is required.';
  end if;

  if v_role='superintendent' and not public.linecrew_has_capability('production_review') then
    raise exception using errcode='42501', message='This Superintendent does not have production review permission.';
  end if;

  select r.company_id, r.foreman_id, r.work_date
    into v_report_company_id, v_report_foreman_id, v_work_date
  from public.daily_reports r
  where r.id=p_report_id;

  if v_report_company_id is null or v_report_company_id<>v_company_id then
    raise exception using errcode='P0002', message='Daily report was not found in your company.';
  end if;

  if v_role='foreman' and v_report_foreman_id is distinct from auth.uid() then
    raise exception using errcode='42501', message='Foremen can recalculate time only on their own reports.';
  end if;

  if not exists (
    select 1 from public.timekeeping_employees e
    where e.id=p_employee_id and e.company_id=v_company_id and e.active is true
  ) then
    raise exception using errcode='P0002', message='Employee was not found in your company.';
  end if;

  select coalesce(c.week_start_day,1)
    into v_week_start_day
  from public.companies c
  where c.id=v_company_id;

  v_week_start := v_work_date - (((extract(dow from v_work_date)::int-v_week_start_day+7)%7));
  v_week_end := v_week_start+6;

  -- Certified entries are immutable. Reserve their existing regular-hour
  -- allocation, then distribute only the remaining weekly regular allowance
  -- across editable entries.
  select coalesce(sum(e.regular_hours),0)
    into v_running
  from public.timekeeping_entries e
  join public.daily_reports r on r.id=e.daily_report_id
  where e.company_id=v_company_id
    and e.employee_id=p_employee_id
    and e.work_date between v_week_start and v_week_end
    and lower(coalesce(r.status,'draft'))='approved';

  for rec in
    select e.id, e.daily_report_id, e.work_date,
           (coalesce(e.regular_hours,0)+coalesce(e.overtime_hours,0)) as total_hours
    from public.timekeeping_entries e
    left join public.daily_reports r on r.id=e.daily_report_id
    where e.company_id=v_company_id
      and e.employee_id=p_employee_id
      and e.work_date between v_week_start and v_week_end
      and lower(coalesce(r.status,'draft'))<>'approved'
    order by e.work_date,e.created_at,e.id
    for update of e
  loop
    v_total := greatest(0,least(24,coalesce(rec.total_hours,0)));
    v_regular := least(v_total,greatest(0,40-v_running));
    v_overtime := greatest(0,v_total-v_regular);

    update public.timekeeping_entries
       set regular_hours=v_regular,
           overtime_hours=v_overtime,
           updated_at=now()
     where id=rec.id;

    v_running := v_running+v_regular;
  end loop;

  update public.daily_reports r
     set regular_hours=totals.regular_hours,
         overtime_hours=totals.overtime_hours,
         updated_at=now()
  from (
    select e.daily_report_id,
           coalesce(sum(e.regular_hours),0) regular_hours,
           coalesce(sum(e.overtime_hours),0) overtime_hours
    from public.timekeeping_entries e
    join public.daily_reports source_report on source_report.id=e.daily_report_id
    where e.company_id=v_company_id
      and e.work_date between v_week_start and v_week_end
      and e.daily_report_id is not null
      and lower(coalesce(source_report.status,'draft'))<>'approved'
      -- Only the reports this employee actually appears on, so saving one
      -- crew does not take row locks across the whole company for the week.
      and e.daily_report_id in (
        select touched.daily_report_id
        from public.timekeeping_entries touched
        where touched.company_id=v_company_id
          and touched.employee_id=p_employee_id
          and touched.work_date between v_week_start and v_week_end
          and touched.daily_report_id is not null
      )
    group by e.daily_report_id
  ) totals
  where r.id=totals.daily_report_id
    and r.company_id=v_company_id
    and lower(coalesce(r.status,'draft'))<>'approved';
end;
$function$;

---------------------------------------------------------------------------
-- 4. Leadership time: admit Manager, exclude approved reports, and scope the
--    header refresh the same way.
--
-- The permission predicate previously listed ('gf','admin') for other people
-- and ('gf','superintendent','admin','owner') for self. 'manager' appeared in
-- NEITHER, while both callers (upsert_my_leadership_time and
-- upsert_leadership_employee_time) admit it -- so a Manager passed the caller
-- gate and then hit a raw 42501 here. The lists below match the callers and
-- the client predicates in leadership-my-time.js exactly.
---------------------------------------------------------------------------
create or replace function private.recalculate_leadership_week(p_company_id uuid, p_employee_id uuid, p_work_date date, p_actor_id uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $function$
declare
  v_actor_role text;
  v_week_start_day integer;
  v_week_start date;
  v_week_end date;
  v_running numeric := 0;
  v_total numeric;
  v_regular numeric;
  v_overtime numeric;
  rec record;
begin
  if auth.uid() is null or auth.uid() is distinct from p_actor_id then
    raise exception using errcode = '42501', message = 'Not authenticated.';
  end if;

  select lower(coalesce(profile.role,''))
    into v_actor_role
  from public.profiles profile
  where profile.id = auth.uid()
    and profile.company_id = p_company_id
    and coalesce(profile.active,true) is true;

  if v_actor_role is null or not exists (
    select 1 from public.timekeeping_employees employee
    where employee.id = p_employee_id
      and employee.company_id = p_company_id
      and employee.active is true
      and (
        -- entering time for another person
        v_actor_role in ('gf','admin','manager')
        or (
          -- entering one's own time
          v_actor_role in ('gf','superintendent','admin','manager','owner')
          and employee.linked_profile_id = auth.uid()
        )
      )
  ) then
    raise exception using errcode = '42501', message = 'You cannot recalculate time for this employee.';
  end if;

  select coalesce(company.week_start_day,1)
    into v_week_start_day
  from public.companies company
  where company.id = p_company_id;

  v_week_start := p_work_date - (((extract(dow from p_work_date)::integer - v_week_start_day + 7) % 7));
  v_week_end := v_week_start + 6;

  -- Mirror the crew recalculator: certified entries are immutable, so reserve
  -- their regular-hour allocation instead of rewriting them.
  select coalesce(sum(entry.regular_hours),0)
    into v_running
  from public.timekeeping_entries entry
  join public.daily_reports report on report.id = entry.daily_report_id
  where entry.company_id = p_company_id
    and entry.employee_id = p_employee_id
    and entry.work_date between v_week_start and v_week_end
    and lower(coalesce(report.status,'draft')) = 'approved';

  for rec in
    select entry.id,
           greatest(0, least(24, coalesce(entry.regular_hours,0) + coalesce(entry.overtime_hours,0))) as total_hours
    from public.timekeeping_entries entry
    left join public.daily_reports report on report.id = entry.daily_report_id
    where entry.company_id = p_company_id
      and entry.employee_id = p_employee_id
      and entry.work_date between v_week_start and v_week_end
      and lower(coalesce(report.status,'draft')) <> 'approved'
    order by entry.work_date, entry.created_at, entry.id
    for update of entry
  loop
    v_total := rec.total_hours;
    v_regular := least(v_total, greatest(0, 40 - v_running));
    v_overtime := greatest(0, v_total - v_regular);

    update public.timekeeping_entries
       set regular_hours = v_regular,
           overtime_hours = v_overtime,
           updated_by = p_actor_id,
           updated_at = now()
     where id = rec.id;

    v_running := v_running + v_regular;
  end loop;

  update public.daily_reports report
     set regular_hours = totals.regular_hours,
         overtime_hours = totals.overtime_hours,
         hours = totals.regular_hours + totals.overtime_hours,
         updated_at = now()
  from (
    select entry.daily_report_id,
           coalesce(sum(entry.regular_hours),0) as regular_hours,
           coalesce(sum(entry.overtime_hours),0) as overtime_hours
    from public.timekeeping_entries entry
    join public.daily_reports source_report on source_report.id = entry.daily_report_id
    where entry.company_id = p_company_id
      and entry.work_date between v_week_start and v_week_end
      and entry.daily_report_id is not null
      and lower(coalesce(source_report.status,'draft')) <> 'approved'
      and entry.daily_report_id in (
        select touched.daily_report_id
        from public.timekeeping_entries touched
        where touched.company_id = p_company_id
          and touched.employee_id = p_employee_id
          and touched.work_date between v_week_start and v_week_end
          and touched.daily_report_id is not null
      )
    group by entry.daily_report_id
  ) totals
  where report.id = totals.daily_report_id
    and report.company_id = p_company_id
    and lower(coalesce(report.status,'draft')) <> 'approved';
end;
$function$;
