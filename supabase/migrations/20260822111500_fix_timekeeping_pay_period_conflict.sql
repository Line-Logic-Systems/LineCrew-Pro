create or replace function public.timekeeping_set_period_status(p_start date, p_end date, p_action text)
returns table(period_start date, period_end date, status text, approved_by uuid, approved_at timestamptz, locked_by uuid, locked_at timestamptz)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_user uuid := auth.uid();
  v_company uuid;
  v_role text;
  v_status text;
begin
  select p.company_id, lower(coalesce(p.role,''))
    into v_company, v_role
  from public.profiles p
  where p.id = v_user;

  if v_company is null then
    raise exception using errcode='42501', message='Company access is required.';
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
$function$;
