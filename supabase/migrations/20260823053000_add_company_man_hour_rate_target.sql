begin;

alter table public.companies
  add column if not exists required_man_hour_rate numeric(12,2);

alter table public.companies
  drop constraint if exists companies_required_man_hour_rate_valid;

alter table public.companies
  add constraint companies_required_man_hour_rate_valid
  check (
    required_man_hour_rate is null
    or required_man_hour_rate between 0.01 and 1000000
  );

create or replace function public.update_company_man_hour_rate(
  p_required_rate numeric
)
returns numeric
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_rate numeric(12,2);
begin
  select p.company_id, lower(p.role)
    into v_company_id, v_role
  from public.profiles p
  where p.id = auth.uid()
    and p.active is true;

  if v_company_id is null or v_role not in ('owner', 'admin') then
    raise exception 'Only an active company Owner or Admin may set the required man-hour rate.'
      using errcode = '42501';
  end if;

  if p_required_rate is null or p_required_rate = 0 then
    v_rate := null;
  elsif p_required_rate < 0.01 or p_required_rate > 1000000 then
    raise exception 'Required man-hour rate must be between 0.01 and 1,000,000.'
      using errcode = '22003';
  else
    v_rate := round(p_required_rate, 2);
  end if;

  update public.companies
  set required_man_hour_rate = v_rate
  where id = v_company_id;

  return v_rate;
end;
$$;

revoke all on function public.update_company_man_hour_rate(numeric) from public;
revoke all on function public.update_company_man_hour_rate(numeric) from anon;
grant execute on function public.update_company_man_hour_rate(numeric) to authenticated;

commit;
