begin;

alter table public.timekeeping_employees
  add column if not exists assigned_foreman_id uuid references public.profiles(id) on delete set null;

create index if not exists timekeeping_employees_assigned_foreman_idx
  on public.timekeeping_employees(company_id, assigned_foreman_id, active, full_name);

create or replace function public.set_my_timekeeping_crew(p_employee_ids uuid[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_user_id uuid := auth.uid();
  v_company_id uuid;
  v_role text;
begin
  select p.company_id, lower(coalesce(p.role, ''))
    into v_company_id, v_role
  from public.profiles p
  where p.id = v_user_id;

  if v_company_id is null or v_role <> 'foreman' then
    raise exception using errcode='42501', message='Only a Foreman can set their own timekeeping crew.';
  end if;

  if exists (
    select 1
    from public.timekeeping_employees e
    where e.id = any(coalesce(p_employee_ids, array[]::uuid[]))
      and e.company_id = v_company_id
      and e.assigned_foreman_id is not null
      and e.assigned_foreman_id <> v_user_id
  ) then
    raise exception using errcode='42501', message='One or more selected employees are already assigned to another Foreman.';
  end if;

  update public.timekeeping_employees
  set assigned_foreman_id = null,
      updated_at = now()
  where company_id = v_company_id
    and assigned_foreman_id = v_user_id
    and not (id = any(coalesce(p_employee_ids, array[]::uuid[])));

  update public.timekeeping_employees
  set assigned_foreman_id = v_user_id,
      updated_at = now()
  where company_id = v_company_id
    and active = true
    and id = any(coalesce(p_employee_ids, array[]::uuid[]))
    and (assigned_foreman_id is null or assigned_foreman_id = v_user_id);
end;
$$;

revoke all on function public.set_my_timekeeping_crew(uuid[]) from public;
revoke all on function public.set_my_timekeeping_crew(uuid[]) from anon;
grant execute on function public.set_my_timekeeping_crew(uuid[]) to authenticated;

create or replace function public.admin_import_timekeeping_roster(p_rows jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_row jsonb;
  v_employee_number text;
  v_full_name text;
  v_classification text;
  v_default_crew text;
  v_existing_id uuid;
  v_inserted integer := 0;
  v_updated integer := 0;
begin
  select p.company_id, lower(coalesce(p.role, ''))
    into v_company_id, v_role
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_role <> 'admin' then
    raise exception using errcode='42501', message='Only a company Admin can import the employee roster.';
  end if;

  if jsonb_typeof(p_rows) <> 'array' then
    raise exception using errcode='22023', message='Roster rows must be an array.';
  end if;

  for v_row in select value from jsonb_array_elements(p_rows)
  loop
    v_employee_number := nullif(btrim(coalesce(v_row->>'employee_number','')), '');
    v_full_name := nullif(btrim(coalesce(v_row->>'full_name','')), '');
    v_classification := nullif(btrim(coalesce(v_row->>'classification','')), '');
    v_default_crew := nullif(btrim(coalesce(v_row->>'default_crew_name','')), '');

    if v_full_name is null then
      continue;
    end if;

    v_existing_id := null;
    if v_employee_number is not null then
      select e.id into v_existing_id
      from public.timekeeping_employees e
      where e.company_id = v_company_id
        and lower(coalesce(e.employee_number,'')) = lower(v_employee_number)
      limit 1;
    end if;

    if v_existing_id is null then
      select e.id into v_existing_id
      from public.timekeeping_employees e
      where e.company_id = v_company_id
        and lower(e.full_name) = lower(v_full_name)
      limit 1;
    end if;

    if v_existing_id is null then
      insert into public.timekeeping_employees(
        company_id, employee_number, full_name, classification, default_crew_name, active, created_by
      ) values (
        v_company_id, v_employee_number, v_full_name, v_classification, v_default_crew, true, auth.uid()
      );
      v_inserted := v_inserted + 1;
    else
      update public.timekeeping_employees
      set employee_number = coalesce(v_employee_number, employee_number),
          full_name = v_full_name,
          classification = coalesce(v_classification, classification),
          default_crew_name = coalesce(v_default_crew, default_crew_name),
          active = true,
          updated_at = now()
      where id = v_existing_id;
      v_updated := v_updated + 1;
    end if;
  end loop;

  return jsonb_build_object('inserted', v_inserted, 'updated', v_updated);
end;
$$;

revoke all on function public.admin_import_timekeeping_roster(jsonb) from public;
revoke all on function public.admin_import_timekeeping_roster(jsonb) from anon;
grant execute on function public.admin_import_timekeeping_roster(jsonb) to authenticated;

commit;
