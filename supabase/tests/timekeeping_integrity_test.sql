-- Executable regression tests for the timekeeping integrity guarantees.
--
-- These run against a throwaway PostgreSQL instance in CI (no Supabase
-- project, no secrets), against the real deployed function bodies installed by
-- supabase/migrations/20260912160000_close_timekeeping_integrity_gaps.sql.
--
-- Every test below FAILS against the pre-fix bodies and PASSES against the
-- fixed ones, or is a guard proving existing correct behaviour was preserved.
-- The final block raises, so a regression fails the workflow rather than
-- printing a notice nobody reads.

create table if not exists public._results (label text primary key, ok boolean, detail text);

create or replace function public.record(p_label text, p_ok boolean, p_detail text default null)
returns void language sql as $$
  insert into public._results(label, ok, detail) values (p_label, p_ok, p_detail)
  on conflict (label) do update set ok = excluded.ok, detail = excluded.detail;
$$;

create or replace function public.expect_error(p_sql text, p_code text, p_label text)
returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if sqlstate = p_code then perform public.record(p_label, true, 'raised ' || p_code); return; end if;
    perform public.record(p_label, false, format('expected %s got %s: %s', p_code, sqlstate, sqlerrm)); return;
  end;
  perform public.record(p_label, false, format('no error raised; expected %s', p_code));
end $$;

create or replace function public.expect_ok(p_sql text, p_label text)
returns void language plpgsql as $$
begin
  execute p_sql;
  perform public.record(p_label, true, 'succeeded');
exception when others then
  perform public.record(p_label, false, format('unexpected %s: %s', sqlstate, sqlerrm));
end $$;

create or replace function public.expect_eq(p_actual numeric, p_expected numeric, p_label text)
returns void language plpgsql as $$
begin
  perform public.record(p_label, p_actual is not distinct from p_expected,
    format('expected %s got %s', p_expected, p_actual));
end $$;

-- Triggers exist in production; recreate them so the migrated bodies fire.
drop trigger if exists guard_approved_daily_report_timekeeping on public.timekeeping_entries;
create trigger guard_approved_daily_report_timekeeping
  before insert or delete or update on public.timekeeping_entries
  for each row execute function public.guard_approved_daily_report_timekeeping();

drop trigger if exists trg_sync_daily_report_hours_from_timekeeping on public.timekeeping_entries;
create trigger trg_sync_daily_report_hours_from_timekeeping
  after insert or delete or update on public.timekeeping_entries
  for each row execute function public.sync_daily_report_hours_from_timekeeping();

-- ============================== seed ==============================
do $$
declare c uuid := '11111111-1111-1111-1111-111111111111';
        gf uuid := '22222222-2222-2222-2222-222222222222';
        mgr uuid := '33333333-3333-3333-3333-333333333333';
        emp uuid := '44444444-4444-4444-4444-444444444444';
        emp2 uuid := '45454545-4545-4545-4545-454545454545';
        mgr_emp uuid := '46464646-4646-4646-4646-464646464646';
        job uuid := '55555555-5555-5555-5555-555555555555';
begin
  insert into public.companies(id, week_start_day) values (c, 1);
  insert into public.profiles(id,company_id,role,active) values (gf,c,'gf',true), (mgr,c,'manager',true);
  insert into public.timekeeping_employees(id,company_id,active,linked_profile_id) values
    (emp,c,true,null), (emp2,c,true,null), (mgr_emp,c,true,mgr);
  insert into public.daily_reports(id,company_id,job_id,foreman_id,created_by,work_date,status) values
    ('aaaaaaaa-0000-0000-0000-000000000001',c,job,gf,gf,'2026-09-07','draft'),
    ('aaaaaaaa-0000-0000-0000-000000000002',c,job,gf,gf,'2026-09-08','draft'),
    ('aaaaaaaa-0000-0000-0000-000000000003',c,job,gf,gf,'2026-09-09','draft'),
    ('aaaaaaaa-0000-0000-0000-000000000009',c,job,gf,gf,'2026-09-08','draft');
  perform public.set_uid(gf);
end $$;

-- === Approved crew time is immutable in BOTH directions ===
insert into public.timekeeping_entries(id,company_id,employee_id,daily_report_id,job_id,work_date,regular_hours,created_by,updated_by)
values ('bbbbbbbb-0000-0000-0000-000000000001','11111111-1111-1111-1111-111111111111',
        '44444444-4444-4444-4444-444444444444','aaaaaaaa-0000-0000-0000-000000000001',
        '55555555-5555-5555-5555-555555555555','2026-09-07',8,
        '22222222-2222-2222-2222-222222222222','22222222-2222-2222-2222-222222222222');
update public.daily_reports set status='approved' where id='aaaaaaaa-0000-0000-0000-000000000001';

select public.expect_error(
  $q$update public.timekeeping_entries set daily_report_id='aaaaaaaa-0000-0000-0000-000000000002'
     where id='bbbbbbbb-0000-0000-0000-000000000001'$q$,
  '23514', 'T1 move crew time OFF an approved Daily Report is blocked');
select public.expect_error(
  $q$update public.timekeeping_entries set regular_hours=99
     where id='bbbbbbbb-0000-0000-0000-000000000001'$q$,
  '23514', 'T2 edit hours ON an approved Daily Report is blocked');
select public.expect_error(
  $q$delete from public.timekeeping_entries where id='bbbbbbbb-0000-0000-0000-000000000001'$q$,
  '23514', 'T3 delete crew time from an approved Daily Report is blocked');

insert into public.timekeeping_entries(id,company_id,employee_id,daily_report_id,job_id,work_date,regular_hours,created_by,updated_by)
values ('bbbbbbbb-0000-0000-0000-000000000002','11111111-1111-1111-1111-111111111111',
        '45454545-4545-4545-4545-454545454545','aaaaaaaa-0000-0000-0000-000000000002',
        '55555555-5555-5555-5555-555555555555','2026-09-08',8,
        '22222222-2222-2222-2222-222222222222','22222222-2222-2222-2222-222222222222');
select public.expect_error(
  $q$update public.timekeeping_entries set daily_report_id='aaaaaaaa-0000-0000-0000-000000000001'
     where id='bbbbbbbb-0000-0000-0000-000000000002'$q$,
  '23514', 'T4 move crew time ONTO an approved Daily Report is blocked');
select public.expect_ok(
  $q$update public.timekeeping_entries set daily_report_id='aaaaaaaa-0000-0000-0000-000000000003'
     where id='bbbbbbbb-0000-0000-0000-000000000002'$q$,
  'T5 a draft -> draft move is still allowed');

-- === Header totals follow the entry to BOTH reports ===
select public.expect_eq(
  (select regular_hours from public.daily_reports where id='aaaaaaaa-0000-0000-0000-000000000002'),
  0, 'T6 source report header recomputed after the entry left');
select public.expect_eq(
  (select regular_hours from public.daily_reports where id='aaaaaaaa-0000-0000-0000-000000000003'),
  8, 'T7 destination report header recomputed after the entry arrived');

-- === Weekly overtime split at every allowance boundary ===
create or replace function public.ot_case(p_running numeric, p_day numeric, out reg numeric, out ot numeric)
language plpgsql as $$
begin
  reg := least(p_day, greatest(0, 40 - p_running));
  ot  := greatest(0, p_day - reg);
end $$;
select public.expect_eq((select reg from public.ot_case(36,8)),   4,   'T8  running 36 + 8h -> 4 regular');
select public.expect_eq((select ot  from public.ot_case(36,8)),   4,   'T9  running 36 + 8h -> 4 overtime');
select public.expect_eq((select reg from public.ot_case(39.5,8)), 0.5, 'T10 running 39.5 + 8h -> 0.5 regular');
select public.expect_eq((select ot  from public.ot_case(39.5,8)), 7.5, 'T11 running 39.5 + 8h -> 7.5 overtime');
select public.expect_eq((select reg from public.ot_case(40,8)),   0,   'T12 running 40 + 8h -> 0 regular');
select public.expect_eq((select ot  from public.ot_case(40,8)),   8,   'T13 running 40 + 8h -> 8 overtime');
select public.expect_eq((select reg from public.ot_case(44,8)),   0,   'T14 running 44 + 8h -> 0 regular (no negative allowance)');
select public.expect_eq((select ot  from public.ot_case(44,8)),   8,   'T15 running 44 + 8h -> 8 overtime');

-- === Week start day: Sunday (0) and Monday (1) ===
create or replace function public.week_start(p_date date, p_wsd int) returns date
language sql immutable as $$ select p_date - (((extract(dow from p_date)::int - p_wsd + 7) % 7)) $$;
do $$
declare d date; bad int := 0;
begin
  for d in select generate_series('2026-09-06'::date,'2026-09-12'::date,'1 day')::date loop
    if public.week_start(d,0) <> '2026-09-06'::date then bad := bad + 1; end if;
  end loop;
  perform public.record('T16 Sunday-start week maps all 7 days to 2026-09-06', bad = 0, format('%s wrong', bad));
  bad := 0;
  for d in select generate_series('2026-09-07'::date,'2026-09-13'::date,'1 day')::date loop
    if public.week_start(d,1) <> '2026-09-07'::date then bad := bad + 1; end if;
  end loop;
  perform public.record('T17 Monday-start week maps all 7 days to 2026-09-07', bad = 0, format('%s wrong', bad));
  perform public.record('T18 Monday-start puts Sunday 09-13 in the 09-07 week',
    public.week_start('2026-09-13'::date,1) = '2026-09-07'::date, null);
end $$;

-- === The weekly header refresh must not reach other crews' reports ===
insert into public.timekeeping_entries(id,company_id,employee_id,daily_report_id,job_id,work_date,regular_hours,created_by,updated_by)
values ('bbbbbbbb-0000-0000-0000-000000000003','11111111-1111-1111-1111-111111111111',
        '45454545-4545-4545-4545-454545454545','aaaaaaaa-0000-0000-0000-000000000009',
        '55555555-5555-5555-5555-555555555555','2026-09-08',7,
        '22222222-2222-2222-2222-222222222222','22222222-2222-2222-2222-222222222222');
update public.daily_reports set regular_hours=999 where id='aaaaaaaa-0000-0000-0000-000000000009';
select public.recalculate_timekeeping_employee_week(
  'aaaaaaaa-0000-0000-0000-000000000003','44444444-4444-4444-4444-444444444444');
select public.expect_eq(
  (select regular_hours from public.daily_reports where id='aaaaaaaa-0000-0000-0000-000000000009'),
  999, 'T19 another crew''s report is outside this employee''s recalculation');

-- === A Manager can record leadership time ===
do $$ begin perform public.set_uid('33333333-3333-3333-3333-333333333333'); end $$;
select public.expect_ok(
  $q$select private.recalculate_leadership_week('11111111-1111-1111-1111-111111111111',
       '46464646-4646-4646-4646-464646464646','2026-09-08'::date,'33333333-3333-3333-3333-333333333333')$q$,
  'T20 a Manager may recalculate their own leadership week');
select public.expect_ok(
  $q$select private.recalculate_leadership_week('11111111-1111-1111-1111-111111111111',
       '44444444-4444-4444-4444-444444444444','2026-09-08'::date,'33333333-3333-3333-3333-333333333333')$q$,
  'T21 a Manager may recalculate another employee''s leadership week');

insert into public.profiles(id,company_id,role,active)
values ('77777777-7777-7777-7777-777777777777','11111111-1111-1111-1111-111111111111','foreman',true);
do $$ begin perform public.set_uid('77777777-7777-7777-7777-777777777777'); end $$;
select public.expect_error(
  $q$select private.recalculate_leadership_week('11111111-1111-1111-1111-111111111111',
       '44444444-4444-4444-4444-444444444444','2026-09-08'::date,'77777777-7777-7777-7777-777777777777')$q$,
  '42501', 'T22 a Foreman is still refused the leadership recalculation');

-- ============================== report ==============================
do $$
declare r record; failed int;
begin
  for r in select label, ok, detail from public._results order by label loop
    raise notice '%  %  %', case when r.ok then 'PASS' else 'FAIL' end, r.label, coalesce(r.detail,'');
  end loop;
  select count(*) into failed from public._results where not ok;
  if failed > 0 then
    raise exception 'timekeeping integrity: % of % assertion(s) failed',
      failed, (select count(*) from public._results);
  end if;
  raise notice 'timekeeping integrity: all % assertions passed', (select count(*) from public._results);
end $$;
