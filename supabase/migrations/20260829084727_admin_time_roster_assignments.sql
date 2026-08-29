begin;

-- Personnel can remain assigned to their normal Foreman crew while also being
-- assigned to one Admin for the Admin's recurring My Time roster.
alter table public.timekeeping_employees
  add column if not exists assigned_admin_id uuid references public.profiles(id) on delete set null,
  add column if not exists admin_assigned_by uuid references public.profiles(id) on delete set null,
  add column if not exists admin_assigned_at timestamptz;

create index if not exists timekeeping_employees_assigned_admin_idx
  on public.timekeeping_employees(company_id, assigned_admin_id, active, full_name);

create index if not exists timekeeping_employees_admin_assigned_by_idx
  on public.timekeeping_employees(admin_assigned_by);

create or replace function public.validate_timekeeping_employee_admin_assignment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.assigned_admin_id is not null and not exists (
    select 1
    from public.profiles administrator
    where administrator.id = new.assigned_admin_id
      and administrator.company_id = new.company_id
      and administrator.active is true
      and lower(coalesce(administrator.role, '')) = 'admin'
  ) then
    raise exception using
      errcode = '23514',
      message = 'The assigned Admin must be an active Admin in this company.';
  end if;

  if tg_op = 'INSERT' then
    new.admin_assigned_by := case
      when new.assigned_admin_id is null then null
      else auth.uid()
    end;
    new.admin_assigned_at := case
      when new.assigned_admin_id is null then null
      else now()
    end;
  elsif new.assigned_admin_id is distinct from old.assigned_admin_id then
    new.admin_assigned_by := case
      when new.assigned_admin_id is null then null
      else auth.uid()
    end;
    new.admin_assigned_at := case
      when new.assigned_admin_id is null then null
      else now()
    end;
  end if;

  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists validate_timekeeping_employee_admin_assignment
  on public.timekeeping_employees;
create trigger validate_timekeeping_employee_admin_assignment
before insert or update of assigned_admin_id
on public.timekeeping_employees
for each row execute function public.validate_timekeeping_employee_admin_assignment();

revoke all on function public.validate_timekeeping_employee_admin_assignment()
  from public, anon, authenticated;

commit;
