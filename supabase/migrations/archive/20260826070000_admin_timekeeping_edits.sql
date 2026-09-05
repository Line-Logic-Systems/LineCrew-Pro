begin;

create table if not exists public.timekeeping_edit_audit (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  timekeeping_entry_id uuid not null references public.timekeeping_entries(id) on delete cascade,
  daily_report_id uuid references public.daily_reports(id) on delete set null,
  employee_id uuid not null references public.timekeeping_employees(id) on delete restrict,
  work_date date not null,
  edited_by uuid not null references public.profiles(id) on delete restrict,
  reason text,
  before_values jsonb not null,
  after_values jsonb not null,
  edited_at timestamptz not null default now()
);

create index if not exists timekeeping_edit_audit_company_date_idx
  on public.timekeeping_edit_audit(company_id, edited_at desc);
create index if not exists timekeeping_edit_audit_entry_idx
  on public.timekeeping_edit_audit(timekeeping_entry_id, edited_at desc);

alter table public.timekeeping_edit_audit enable row level security;

drop policy if exists timekeeping_edit_audit_admin_select on public.timekeeping_edit_audit;
create policy timekeeping_edit_audit_admin_select
on public.timekeeping_edit_audit for select to authenticated
using (
  company_id = (select public.my_company_id())
  and lower(coalesce((select public.my_role()),'')) in ('owner','admin')
);

revoke all on public.timekeeping_edit_audit from public, anon, authenticated;
grant select on public.timekeeping_edit_audit to authenticated;

create or replace function public.admin_update_timekeeping_entry(
  p_daily_report_id uuid,
  p_employee_id uuid,
  p_start_time time without time zone,
  p_stop_time time without time zone,
  p_lunch_minutes integer,
  p_regular_hours numeric,
  p_overtime_hours numeric,
  p_per_diem boolean,
  p_equipment_used text,
  p_equipment_not_used boolean,
  p_reason text default null
)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_profile public.profiles%rowtype;
  v_entry public.timekeeping_entries%rowtype;
  v_before jsonb;
  v_after jsonb;
begin
  if auth.uid() is null then
    raise exception using errcode='42501', message='Not authenticated.';
  end if;

  select * into v_profile
  from public.profiles p
  where p.id = auth.uid();

  if v_profile.id is null or coalesce(v_profile.active,true) is not true
     or lower(coalesce(v_profile.role,'')) not in ('owner','admin') then
    raise exception using errcode='42501', message='Only an active Owner or Admin can edit submitted time.';
  end if;

  if p_lunch_minutes is null or p_lunch_minutes < 0 or p_lunch_minutes > 720 then
    raise exception using errcode='22023', message='Lunch must be between 0 and 720 minutes.';
  end if;
  if p_regular_hours is null or p_overtime_hours is null
     or p_regular_hours < 0 or p_overtime_hours < 0
     or p_regular_hours + p_overtime_hours > 24 then
    raise exception using errcode='22023', message='Regular plus OT hours must be between 0 and 24.';
  end if;

  select e.* into v_entry
  from public.timekeeping_entries e
  join public.daily_reports r on r.id=e.daily_report_id and r.company_id=e.company_id
  where e.company_id=v_profile.company_id
    and e.daily_report_id=p_daily_report_id
    and e.employee_id=p_employee_id
  for update;

  if v_entry.id is null then
    raise exception using errcode='P0002', message='Time entry was not found in your company.';
  end if;

  v_before := jsonb_build_object(
    'start_time',v_entry.start_time,'stop_time',v_entry.stop_time,'lunch_minutes',v_entry.lunch_minutes,
    'regular_hours',v_entry.regular_hours,'overtime_hours',v_entry.overtime_hours,'per_diem',v_entry.per_diem,
    'equipment_used',v_entry.equipment_used,'equipment_not_used',v_entry.equipment_not_used
  );

  update public.timekeeping_entries e
  set start_time=p_start_time,
      stop_time=p_stop_time,
      lunch_minutes=p_lunch_minutes,
      regular_hours=p_regular_hours,
      overtime_hours=p_overtime_hours,
      per_diem=coalesce(p_per_diem,false),
      equipment_used=case when coalesce(p_equipment_not_used,false) then null else nullif(btrim(coalesce(p_equipment_used,'')),'') end,
      equipment_not_used=coalesce(p_equipment_not_used,false),
      updated_by=auth.uid(),
      updated_at=now()
  where e.id=v_entry.id;

  perform public.recalculate_timekeeping_employee_week(p_daily_report_id,p_employee_id);

  select e.* into v_entry from public.timekeeping_entries e where e.id=v_entry.id;
  v_after := jsonb_build_object(
    'start_time',v_entry.start_time,'stop_time',v_entry.stop_time,'lunch_minutes',v_entry.lunch_minutes,
    'regular_hours',v_entry.regular_hours,'overtime_hours',v_entry.overtime_hours,'per_diem',v_entry.per_diem,
    'equipment_used',v_entry.equipment_used,'equipment_not_used',v_entry.equipment_not_used
  );

  insert into public.timekeeping_edit_audit(
    company_id,timekeeping_entry_id,daily_report_id,employee_id,work_date,edited_by,reason,before_values,after_values
  ) values (
    v_entry.company_id,v_entry.id,v_entry.daily_report_id,v_entry.employee_id,v_entry.work_date,auth.uid(),nullif(btrim(coalesce(p_reason,'')),''),v_before,v_after
  );
end;
$$;

revoke all on function public.admin_update_timekeeping_entry(uuid,uuid,time without time zone,time without time zone,integer,numeric,numeric,boolean,text,boolean,text) from public, anon;
grant execute on function public.admin_update_timekeeping_entry(uuid,uuid,time without time zone,time without time zone,integer,numeric,numeric,boolean,text,boolean,text) to authenticated;

commit;
