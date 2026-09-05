-- Post end-to-end hardening: scale new GF/timekeeping tables and close direct REST gaps.

-- Cover FK lookups that become hot as companies add crews and payroll history.
create index if not exists gf_foreman_assignments_foreman_id_idx
  on public.gf_foreman_assignments(foreman_id);
create index if not exists gf_foreman_assignments_gf_id_idx
  on public.gf_foreman_assignments(gf_id);
create index if not exists gf_foreman_assignments_created_by_idx
  on public.gf_foreman_assignments(created_by);

create index if not exists timekeeping_edit_audit_daily_report_id_idx
  on public.timekeeping_edit_audit(daily_report_id);
create index if not exists timekeeping_edit_audit_employee_id_idx
  on public.timekeeping_edit_audit(employee_id);
create index if not exists timekeeping_edit_audit_edited_by_idx
  on public.timekeeping_edit_audit(edited_by);

-- Pay-period state/history are readable only by active members of the same company.
drop policy if exists timekeeping_pay_periods_select_company on public.timekeeping_pay_periods;
create policy timekeeping_pay_periods_select_company
on public.timekeeping_pay_periods
for select
to authenticated
using (
  company_id = (select public.my_company_id())
  and (select public.current_user_has_active_profile())
);

drop policy if exists timekeeping_pay_period_audit_select_company on public.timekeeping_pay_period_audit;
create policy timekeeping_pay_period_audit_select_company
on public.timekeeping_pay_period_audit
for select
to authenticated
using (
  company_id = (select public.my_company_id())
  and (select public.current_user_has_active_profile())
);

-- These tables are changed only through guarded SECURITY DEFINER RPCs.
revoke all on table public.timekeeping_pay_periods from anon;
revoke all on table public.timekeeping_pay_period_audit from anon;
revoke insert, update, delete, truncate, references, trigger on table public.timekeeping_pay_periods from authenticated;
revoke insert, update, delete, truncate, references, trigger on table public.timekeeping_pay_period_audit from authenticated;
grant select on table public.timekeeping_pay_periods to authenticated;
grant select on table public.timekeeping_pay_period_audit to authenticated;

-- A suspended account must not read pay-period state through the RPC.
create or replace function public.timekeeping_period_state(p_start date, p_end date)
returns table(
  period_start date,
  period_end date,
  status text,
  approved_by uuid,
  approved_at timestamptz,
  locked_by uuid,
  locked_at timestamptz
)
language sql
security definer
set search_path = ''
as $$
  with me as (
    select p.company_id
    from public.profiles p
    where p.id = auth.uid()
      and p.active is true
  )
  select
    p_start,
    p_end,
    coalesce(pp.status, 'open') as status,
    pp.approved_by,
    pp.approved_at,
    pp.locked_by,
    pp.locked_at
  from me
  left join public.timekeeping_pay_periods pp
    on pp.company_id = me.company_id
   and pp.period_start = p_start
   and pp.period_end = p_end;
$$;

-- Keep the existing role workflow, but require an active profile for every state change.
create or replace function public.timekeeping_set_period_status(p_start date, p_end date, p_action text)
returns table(
  period_start date,
  period_end date,
  status text,
  approved_by uuid,
  approved_at timestamptz,
  locked_by uuid,
  locked_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user uuid := auth.uid();
  v_company uuid;
  v_role text;
  v_active boolean;
  v_status text;
begin
  select p.company_id, lower(coalesce(p.role,'')), p.active
    into v_company, v_role, v_active
  from public.profiles p
  where p.id = v_user;

  if v_company is null or v_active is not true then
    raise exception using errcode='42501', message='Active company access is required.';
  end if;
  if p_start is null or p_end is null or p_end < p_start then
    raise exception using errcode='22023', message='Choose a valid pay period.';
  end if;
  if lower(coalesce(p_action,'')) not in ('approve','reopen','lock','unlock') then
    raise exception using errcode='22023', message='Unsupported Timekeeping pay-period action.';
  end if;

  if lower(p_action) in ('approve','reopen') and v_role not in ('gf','admin','owner') then
    raise exception using errcode='42501', message='Only a General Foreman, Admin, or Owner can approve or reopen Timekeeping.';
  end if;
  if lower(p_action) in ('lock','unlock') and v_role not in ('admin','owner') then
    raise exception using errcode='42501', message='Only an Admin or Owner can lock or unlock a pay period.';
  end if;

  insert into public.timekeeping_pay_periods(company_id,period_start,period_end,status)
  values(v_company,p_start,p_end,'open')
  on conflict on constraint timekeeping_pay_period_company_dates_unique do nothing;

  select pp.status into v_status
  from public.timekeeping_pay_periods pp
  where pp.company_id=v_company and pp.period_start=p_start and pp.period_end=p_end
  for update;

  if lower(p_action)='approve' then
    update public.timekeeping_pay_periods pp
       set status='approved', approved_by=v_user, approved_at=now(), locked_by=null, locked_at=null, updated_at=now()
     where pp.company_id=v_company and pp.period_start=p_start and pp.period_end=p_end;
  elsif lower(p_action)='reopen' then
    if v_status='locked' then
      raise exception using errcode='42501', message='Unlock the pay period before reopening it.';
    end if;
    update public.timekeeping_pay_periods pp
       set status='open', approved_by=null, approved_at=null, locked_by=null, locked_at=null, updated_at=now()
     where pp.company_id=v_company and pp.period_start=p_start and pp.period_end=p_end;
  elsif lower(p_action)='lock' then
    if v_status <> 'approved' then
      raise exception using errcode='22023', message='Approve the pay period before locking it.';
    end if;
    update public.timekeeping_pay_periods pp
       set status='locked', locked_by=v_user, locked_at=now(), updated_at=now()
     where pp.company_id=v_company and pp.period_start=p_start and pp.period_end=p_end;
  elsif lower(p_action)='unlock' then
    update public.timekeeping_pay_periods pp
       set status='approved', locked_by=null, locked_at=null, updated_at=now()
     where pp.company_id=v_company and pp.period_start=p_start and pp.period_end=p_end;
  end if;

  insert into public.timekeeping_pay_period_audit(company_id,period_start,period_end,action,actor_id,detail)
  values(v_company,p_start,p_end,lower(p_action),v_user,'Status action from Timekeeping workspace');

  return query
  select pp.period_start,pp.period_end,pp.status,pp.approved_by,pp.approved_at,pp.locked_by,pp.locked_at
  from public.timekeeping_pay_periods pp
  where pp.company_id=v_company and pp.period_start=p_start and pp.period_end=p_end;
end;
$$;

revoke all on function public.timekeeping_period_state(date,date) from public, anon;
grant execute on function public.timekeeping_period_state(date,date) to authenticated, service_role;
revoke all on function public.timekeeping_set_period_status(date,date,text) from public, anon;
grant execute on function public.timekeeping_set_period_status(date,date,text) to authenticated, service_role;
