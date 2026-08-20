begin;

create table if not exists public.timekeeping_pay_periods (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  period_start date not null,
  period_end date not null,
  status text not null default 'open' check (status in ('open','approved','locked')),
  approved_by uuid references public.profiles(id) on delete set null,
  approved_at timestamptz,
  locked_by uuid references public.profiles(id) on delete set null,
  locked_at timestamptz,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint timekeeping_pay_period_dates_check check (period_end >= period_start),
  constraint timekeeping_pay_period_company_dates_unique unique (company_id, period_start, period_end)
);

create index if not exists timekeeping_pay_periods_company_dates_idx
  on public.timekeeping_pay_periods(company_id, period_start desc, period_end desc);

create table if not exists public.timekeeping_pay_period_audit (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  period_start date not null,
  period_end date not null,
  action text not null,
  actor_id uuid references public.profiles(id) on delete set null,
  detail text,
  created_at timestamptz not null default now()
);

create index if not exists timekeeping_pay_period_audit_company_idx
  on public.timekeeping_pay_period_audit(company_id, created_at desc);

alter table public.timekeeping_pay_periods enable row level security;
alter table public.timekeeping_pay_period_audit enable row level security;

drop policy if exists timekeeping_pay_periods_select_company on public.timekeeping_pay_periods;
create policy timekeeping_pay_periods_select_company
on public.timekeeping_pay_periods for select
to authenticated
using (
  company_id = (select p.company_id from public.profiles p where p.id = auth.uid())
);

drop policy if exists timekeeping_pay_period_audit_select_company on public.timekeeping_pay_period_audit;
create policy timekeeping_pay_period_audit_select_company
on public.timekeeping_pay_period_audit for select
to authenticated
using (
  company_id = (select p.company_id from public.profiles p where p.id = auth.uid())
);

grant select on public.timekeeping_pay_periods to authenticated;
grant select on public.timekeeping_pay_period_audit to authenticated;

create or replace function public.timekeeping_period_state(
  p_start date,
  p_end date
)
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
set search_path = public
as $$
  with me as (
    select company_id from public.profiles where id = auth.uid()
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

revoke all on function public.timekeeping_period_state(date,date) from public;
revoke all on function public.timekeeping_period_state(date,date) from anon;
grant execute on function public.timekeeping_period_state(date,date) to authenticated;

create or replace function public.timekeeping_set_period_status(
  p_start date,
  p_end date,
  p_action text
)
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
set search_path = public
as $$
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
  on conflict (company_id,period_start,period_end) do nothing;

  select pp.status into v_status
  from public.timekeeping_pay_periods pp
  where pp.company_id=v_company and pp.period_start=p_start and pp.period_end=p_end
  for update;

  if lower(p_action)='approve' then
    update public.timekeeping_pay_periods
       set status='approved', approved_by=v_user, approved_at=now(), locked_by=null, locked_at=null, updated_at=now()
     where company_id=v_company and period_start=p_start and period_end=p_end;
  elsif lower(p_action)='reopen' then
    if v_status='locked' then
      raise exception using errcode='42501', message='Unlock the pay period before reopening it.';
    end if;
    update public.timekeeping_pay_periods
       set status='open', approved_by=null, approved_at=null, locked_by=null, locked_at=null, updated_at=now()
     where company_id=v_company and period_start=p_start and period_end=p_end;
  elsif lower(p_action)='lock' then
    if v_status <> 'approved' then
      raise exception using errcode='22023', message='Approve the pay period before locking it.';
    end if;
    update public.timekeeping_pay_periods
       set status='locked', locked_by=v_user, locked_at=now(), updated_at=now()
     where company_id=v_company and period_start=p_start and period_end=p_end;
  elsif lower(p_action)='unlock' then
    update public.timekeeping_pay_periods
       set status='approved', locked_by=null, locked_at=null, updated_at=now()
     where company_id=v_company and period_start=p_start and period_end=p_end;
  end if;

  insert into public.timekeeping_pay_period_audit(company_id,period_start,period_end,action,actor_id,detail)
  values(v_company,p_start,p_end,lower(p_action),v_user,'Status action from Timekeeping workspace');

  return query
  select pp.period_start,pp.period_end,pp.status,pp.approved_by,pp.approved_at,pp.locked_by,pp.locked_at
  from public.timekeeping_pay_periods pp
  where pp.company_id=v_company and pp.period_start=p_start and pp.period_end=p_end;
end;
$$;

revoke all on function public.timekeeping_set_period_status(date,date,text) from public;
revoke all on function public.timekeeping_set_period_status(date,date,text) from anon;
grant execute on function public.timekeeping_set_period_status(date,date,text) to authenticated;

create or replace function public.guard_timekeeping_locked_period()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company uuid := coalesce(new.company_id, old.company_id);
  v_work_date date := coalesce(new.work_date, old.work_date);
  v_period record;
begin
  select pp.* into v_period
  from public.timekeeping_pay_periods pp
  where pp.company_id=v_company
    and v_work_date between pp.period_start and pp.period_end
    and pp.status in ('approved','locked')
  order by case pp.status when 'locked' then 0 else 1 end, pp.period_start desc
  limit 1;

  if found and v_period.status='locked' then
    raise exception using errcode='42501', message='This pay period is locked. Unlock it before changing Timekeeping.';
  end if;

  if found and v_period.status='approved' then
    update public.timekeeping_pay_periods
       set status='open', approved_by=null, approved_at=null, updated_at=now()
     where id=v_period.id;
    insert into public.timekeeping_pay_period_audit(company_id,period_start,period_end,action,actor_id,detail)
    values(v_company,v_period.period_start,v_period.period_end,'auto_reopen',auth.uid(),'Time entry changed after approval');
  end if;

  return coalesce(new, old);
end;
$$;

drop trigger if exists guard_timekeeping_locked_period on public.timekeeping_entries;
create trigger guard_timekeeping_locked_period
before insert or update or delete on public.timekeeping_entries
for each row execute function public.guard_timekeeping_locked_period();

commit;
