begin;

create table if not exists public.storm_mode_assignments (
  company_id uuid not null references public.companies(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  assigned_by uuid not null references auth.users(id) on delete restrict default auth.uid(),
  created_at timestamptz not null default now(),
  primary key (company_id, user_id)
);

create index if not exists storm_mode_assignments_user_idx
  on public.storm_mode_assignments(user_id, company_id);

alter table public.storm_mode_assignments enable row level security;

revoke all on table public.storm_mode_assignments from public, anon, authenticated;

create or replace function public.is_current_user_in_storm_mode()
returns boolean
language sql
security definer
set search_path = ''
stable
as $$
  select coalesce((
    select c.storm_mode_enabled
       and exists (
         select 1
         from public.storm_mode_assignments a
         where a.company_id = p.company_id
           and a.user_id = auth.uid()
       )
    from public.profiles p
    join public.companies c on c.id = p.company_id
    where p.id = auth.uid()
      and coalesce(p.active, true)
  ), false);
$$;

create or replace function public.get_storm_mode_assignments()
returns table (
  user_id uuid,
  full_name text,
  role text,
  active boolean,
  assigned boolean
)
language plpgsql
security definer
set search_path = ''
stable
as $$
declare
  v_company_id uuid;
  v_role text;
begin
  select p.company_id, lower(coalesce(p.role, ''))
    into v_company_id, v_role
  from public.profiles p
  where p.id = auth.uid()
    and coalesce(p.active, true);

  if v_company_id is null or v_role <> 'admin' then
    raise exception using errcode = '42501',
      message = 'Only a company Admin can view Storm Mode crew assignments.';
  end if;

  return query
  select p.id,
         coalesce(nullif(trim(p.full_name), ''), 'Unnamed Team Member'),
         lower(coalesce(p.role, 'foreman')),
         coalesce(p.active, true),
         (a.user_id is not null)
  from public.profiles p
  left join public.storm_mode_assignments a
    on a.company_id = p.company_id
   and a.user_id = p.id
  where p.company_id = v_company_id
    and lower(coalesce(p.role, 'foreman')) in ('foreman', 'gf', 'admin')
  order by
    case lower(coalesce(p.role, 'foreman'))
      when 'gf' then 1
      when 'foreman' then 2
      else 3
    end,
    lower(coalesce(p.full_name, ''));
end;
$$;

create or replace function public.set_storm_mode_assignments(
  p_user_ids uuid[]
)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_requested_count integer;
  v_valid_count integer;
begin
  select p.company_id, lower(coalesce(p.role, ''))
    into v_company_id, v_role
  from public.profiles p
  where p.id = auth.uid()
    and coalesce(p.active, true);

  if v_company_id is null or v_role <> 'admin' then
    raise exception using errcode = '42501',
      message = 'Only a company Admin can change Storm Mode crew assignments.';
  end if;

  select count(distinct requested_id)
    into v_requested_count
  from unnest(coalesce(p_user_ids, array[]::uuid[])) requested_id;

  select count(*)
    into v_valid_count
  from public.profiles p
  where p.company_id = v_company_id
    and p.id = any(coalesce(p_user_ids, array[]::uuid[]))
    and coalesce(p.active, true)
    and lower(coalesce(p.role, 'foreman')) in ('foreman', 'gf', 'admin');

  if v_requested_count <> v_valid_count then
    raise exception using errcode = '22023',
      message = 'One or more selected Storm Mode crew leaders are invalid for this company.';
  end if;

  delete from public.storm_mode_assignments
  where company_id = v_company_id;

  insert into public.storm_mode_assignments(company_id, user_id, assigned_by)
  select v_company_id, p.id, auth.uid()
  from public.profiles p
  where p.company_id = v_company_id
    and p.id = any(coalesce(p_user_ids, array[]::uuid[]))
    and coalesce(p.active, true)
    and lower(coalesce(p.role, 'foreman')) in ('foreman', 'gf', 'admin')
  on conflict (company_id, user_id) do nothing;

  return v_valid_count;
end;
$$;

create or replace function public.set_daily_report_storm_context(
  p_report_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_report_created_by uuid;
  v_enabled boolean;
  v_event_name text;
  v_assigned boolean;
begin
  select p.company_id, lower(coalesce(p.role, ''))
    into v_company_id, v_role
  from public.profiles p
  where p.id = auth.uid()
    and coalesce(p.active, true);

  if v_company_id is null or v_role not in ('foreman','gf','admin') then
    raise exception using errcode = '42501',
      message = 'You are not allowed to update this daily report.';
  end if;

  select dr.created_by
    into v_report_created_by
  from public.daily_reports dr
  where dr.id = p_report_id
    and dr.company_id = v_company_id;

  if v_report_created_by is null then
    raise exception using errcode = 'P0002',
      message = 'Daily report was not found for your company.';
  end if;

  if v_role = 'foreman' and v_report_created_by <> auth.uid() then
    raise exception using errcode = '42501',
      message = 'Foremen may only update their own daily reports.';
  end if;

  select c.storm_mode_enabled, c.storm_event_name,
         exists (
           select 1
           from public.storm_mode_assignments a
           where a.company_id = v_company_id
             and a.user_id = v_report_created_by
         )
    into v_enabled, v_event_name, v_assigned
  from public.companies c
  where c.id = v_company_id;

  update public.daily_reports
  set storm_mode = coalesce(v_enabled, false) and coalesce(v_assigned, false),
      storm_event_name = case
        when coalesce(v_enabled, false) and coalesce(v_assigned, false)
          then v_event_name
        else null
      end
  where id = p_report_id
    and company_id = v_company_id;
end;
$$;

revoke all on function public.is_current_user_in_storm_mode() from public, anon;
revoke all on function public.get_storm_mode_assignments() from public, anon;
revoke all on function public.set_storm_mode_assignments(uuid[]) from public, anon;
revoke all on function public.set_daily_report_storm_context(uuid) from public, anon;

grant execute on function public.is_current_user_in_storm_mode() to authenticated;
grant execute on function public.get_storm_mode_assignments() to authenticated;
grant execute on function public.set_storm_mode_assignments(uuid[]) to authenticated;
grant execute on function public.set_daily_report_storm_context(uuid) to authenticated;

commit;
