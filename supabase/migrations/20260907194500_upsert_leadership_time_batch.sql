create or replace function public.upsert_leadership_time_batch(p_entries jsonb)
returns table (
  employee_id uuid,
  entry_id uuid,
  regular_hours numeric,
  overtime_hours numeric
)
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_item jsonb;
  v_employee_id uuid;
  v_self_employee_id uuid;
  v_entry_id uuid;
  v_regular_hours numeric;
  v_overtime_hours numeric;
  v_company_id uuid;
  v_role text;
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Not authenticated.';
  end if;

  select profile.company_id, lower(coalesce(profile.role, ''))
    into v_company_id, v_role
  from public.profiles profile
  where profile.id = auth.uid()
    and profile.active is true;

  if v_company_id is null or v_role not in ('gf', 'admin') then
    raise exception using errcode = '42501', message = 'Only an active General Foreman or Admin can save group time.';
  end if;

  if p_entries is null
     or jsonb_typeof(p_entries) <> 'array'
     or jsonb_array_length(p_entries) < 1
     or jsonb_array_length(p_entries) > 100 then
    raise exception using errcode = '22023', message = 'Submit between 1 and 100 time rows.';
  end if;

  select employee.id
    into v_self_employee_id
  from public.timekeeping_employees employee
  where employee.company_id = v_company_id
    and employee.linked_profile_id = auth.uid()
    and employee.active is true;

  for v_item in select value from jsonb_array_elements(p_entries)
  loop
    begin
      v_employee_id := nullif(v_item->>'employee_id', '')::uuid;
    exception when invalid_text_representation then
      raise exception using errcode = '22023', message = 'Each time row must identify a valid employee.';
    end;

    if v_employee_id is null then
      raise exception using errcode = '22023', message = 'Each time row must identify an employee.';
    end if;

    if v_employee_id = v_self_employee_id then
      select saved.entry_id, saved.regular_hours, saved.overtime_hours
        into v_entry_id, v_regular_hours, v_overtime_hours
      from public.upsert_my_leadership_time(
        nullif(v_item->>'entry_id', '')::uuid,
        nullif(v_item->>'work_date', '')::date,
        nullif(v_item->>'start_time', '')::time,
        nullif(v_item->>'stop_time', '')::time,
        coalesce((v_item->>'lunch_minutes')::integer, 0),
        nullif(v_item->>'job_id', '')::uuid,
        nullif(v_item->>'labor_code', ''),
        coalesce((v_item->>'per_diem')::boolean, false),
        nullif(v_item->>'equipment_used', ''),
        coalesce((v_item->>'equipment_not_used')::boolean, false),
        nullif(v_item->>'notes', '')
      ) saved;
    else
      select saved.entry_id, saved.regular_hours, saved.overtime_hours
        into v_entry_id, v_regular_hours, v_overtime_hours
      from public.upsert_leadership_employee_time(
        v_employee_id,
        nullif(v_item->>'entry_id', '')::uuid,
        nullif(v_item->>'work_date', '')::date,
        nullif(v_item->>'start_time', '')::time,
        nullif(v_item->>'stop_time', '')::time,
        coalesce((v_item->>'lunch_minutes')::integer, 0),
        nullif(v_item->>'job_id', '')::uuid,
        nullif(v_item->>'labor_code', ''),
        coalesce((v_item->>'per_diem')::boolean, false),
        nullif(v_item->>'equipment_used', ''),
        coalesce((v_item->>'equipment_not_used')::boolean, false),
        nullif(v_item->>'notes', '')
      ) saved;
    end if;

    employee_id := v_employee_id;
    entry_id := v_entry_id;
    regular_hours := v_regular_hours;
    overtime_hours := v_overtime_hours;
    return next;
  end loop;
end;
$$;

revoke all on function public.upsert_leadership_time_batch(jsonb) from public, anon;
grant execute on function public.upsert_leadership_time_batch(jsonb) to authenticated, service_role;
