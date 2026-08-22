create or replace function public.sync_daily_report_hours_from_timekeeping()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_report_id uuid;
  v_reg numeric := 0;
  v_ot numeric := 0;
begin
  v_report_id := coalesce(new.daily_report_id, old.daily_report_id);
  if v_report_id is null then
    return coalesce(new, old);
  end if;

  select coalesce(sum(t.regular_hours),0), coalesce(sum(t.overtime_hours),0)
    into v_reg, v_ot
  from public.timekeeping_entries t
  where t.daily_report_id=v_report_id;

  update public.daily_reports d
     set regular_hours=v_reg,
         overtime_hours=v_ot,
         hours=v_reg+v_ot,
         updated_at=now()
   where d.id=v_report_id;

  return coalesce(new, old);
end;
$function$;

drop trigger if exists trg_sync_daily_report_hours_from_timekeeping on public.timekeeping_entries;
create trigger trg_sync_daily_report_hours_from_timekeeping
after insert or update or delete on public.timekeeping_entries
for each row execute function public.sync_daily_report_hours_from_timekeeping();

create or replace function public.submit_daily_report(p_report_id uuid)
returns void
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_reviewed_at timestamptz;
  v_review_notes text;
  v_corrections text;
  v_reg numeric := 0;
  v_ot numeric := 0;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if not exists (
    select 1 from public.daily_production_unit_locations l
    where l.daily_report_id = p_report_id
      and l.company_id = public.my_company_id()
  ) then
    raise exception 'Add at least one unit before submitting this daily report.';
  end if;

  if not exists (
    select 1 from public.timekeeping_entries t
    where t.daily_report_id=p_report_id
      and t.company_id=public.my_company_id()
  ) then
    raise exception 'Add Crew Time for at least one employee before submitting this daily report.';
  end if;

  select coalesce(sum(t.regular_hours),0), coalesce(sum(t.overtime_hours),0)
    into v_reg, v_ot
  from public.timekeeping_entries t
  where t.daily_report_id=p_report_id
    and t.company_id=public.my_company_id();

  select reviewed_at, review_notes
  into v_reviewed_at, v_review_notes
  from public.daily_reports
  where id=p_report_id
    and company_id=public.my_company_id()
    and foreman_id=auth.uid()
    and status in ('draft','rejected');

  if not found then
    raise exception 'Report not found or cannot be submitted';
  end if;

  if v_reviewed_at is not null and nullif(btrim(coalesce(v_review_notes,'')),'') is not null then
    select string_agg('• ' || e.event_notes, E'\n' order by e.created_at)
    into v_corrections
    from public.daily_report_audit_events e
    where e.daily_report_id=p_report_id
      and e.company_id=public.my_company_id()
      and e.event_type='foreman_correction'
      and e.created_at >= v_reviewed_at;
  end if;

  update public.daily_reports
  set status='submitted',
      submitted_at=now(),
      updated_at=now(),
      regular_hours=v_reg,
      overtime_hours=v_ot,
      hours=v_reg+v_ot,
      review_notes = case
        when nullif(v_corrections,'') is not null then
          regexp_replace(coalesce(v_review_notes,''), E'\n\nFOREMAN CORRECTIONS:[\s\S]*$', '', 'g') || E'\n\nFOREMAN CORRECTIONS:\n' || v_corrections
        else v_review_notes
      end
  where id=p_report_id
    and company_id=public.my_company_id()
    and foreman_id=auth.uid()
    and status in ('draft','rejected');
end;
$function$;
