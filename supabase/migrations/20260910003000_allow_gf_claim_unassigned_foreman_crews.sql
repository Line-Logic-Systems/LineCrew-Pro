begin;

create or replace function public.set_gf_crew_assignment(
  p_foreman_id uuid,
  p_gf_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_foreman_ok boolean;
  v_gf_ok boolean;
begin
  select p.company_id, lower(coalesce(p.role,'')), p.active
    into v_company_id, v_role, v_active
  from public.profiles p
  where p.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin','owner','gf') then
    raise exception using errcode='42501',
      message='Only an Owner, Admin, or active General Foreman can manage GF crew assignments.';
  end if;

  select exists(
    select 1
    from public.profiles p
    where p.id = p_foreman_id
      and p.company_id = v_company_id
      and p.active is true
      and lower(coalesce(p.role,'')) = 'foreman'
  ) into v_foreman_ok;

  if not v_foreman_ok then
    raise exception using errcode='22023',
      message='The selected Foreman is not an active Foreman in your company.';
  end if;

  if v_role = 'gf' then
    if p_gf_id is distinct from auth.uid() then
      raise exception using errcode='42501',
        message='General Foremen may assign only unassigned Foreman crews to themselves.';
    end if;

    insert into public.gf_foreman_assignments(
      company_id,
      gf_id,
      foreman_id,
      created_by,
      updated_at
    )
    values(
      v_company_id,
      auth.uid(),
      p_foreman_id,
      auth.uid(),
      now()
    )
    on conflict (company_id,foreman_id) do nothing;

    if not found then
      raise exception using errcode='23505',
        message='This Foreman crew is already assigned. An Owner or Admin must change its General Foreman.';
    end if;

    return;
  end if;

  if p_gf_id is null then
    delete from public.gf_foreman_assignments a
    where a.company_id = v_company_id
      and a.foreman_id = p_foreman_id;
    return;
  end if;

  select exists(
    select 1
    from public.profiles p
    where p.id = p_gf_id
      and p.company_id = v_company_id
      and p.active is true
      and lower(coalesce(p.role,'')) = 'gf'
  ) into v_gf_ok;

  if not v_gf_ok then
    raise exception using errcode='22023',
      message='The selected General Foreman is not active in your company.';
  end if;

  insert into public.gf_foreman_assignments(
    company_id,
    gf_id,
    foreman_id,
    created_by,
    updated_at
  )
  values(
    v_company_id,
    p_gf_id,
    p_foreman_id,
    auth.uid(),
    now()
  )
  on conflict (company_id,foreman_id)
  do update
    set gf_id=excluded.gf_id,
        created_by=auth.uid(),
        updated_at=now();
end;
$$;

revoke all on function public.set_gf_crew_assignment(uuid,uuid)
from public, anon;

grant execute on function public.set_gf_crew_assignment(uuid,uuid)
to authenticated, service_role;

commit;
