begin;

create table if not exists public.job_leader_assignments (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id) on delete cascade,
  job_id uuid not null references public.jobs(id) on delete cascade,
  member_id uuid not null references public.profiles(id) on delete cascade,
  assigned_by uuid null references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  unique (job_id, member_id)
);

create index if not exists job_leader_assignments_company_job_idx
  on public.job_leader_assignments(company_id, job_id);

create index if not exists job_leader_assignments_company_member_idx
  on public.job_leader_assignments(company_id, member_id);

alter table public.job_leader_assignments enable row level security;

drop policy if exists job_leader_assignments_same_company_select
  on public.job_leader_assignments;

create policy job_leader_assignments_same_company_select
on public.job_leader_assignments
for select
to authenticated
using (
  company_id = (
    select profile.company_id
    from public.profiles profile
    where profile.id = auth.uid()
      and profile.active is true
  )
);

revoke all on table public.job_leader_assignments from anon;
revoke insert, update, delete on table public.job_leader_assignments from authenticated;
grant select on table public.job_leader_assignments to authenticated;

create or replace function public.get_assignable_job_leaders()
returns table (
  member_id uuid,
  full_name text,
  member_role text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin', 'gf') then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin or General Foreman can manage job leaders.';
  end if;

  return query
  select
    profile.id,
    coalesce(nullif(trim(profile.full_name), ''), 'Unnamed Team Member')::text,
    lower(coalesce(profile.role, 'foreman'))::text
  from public.profiles profile
  where profile.company_id = v_company_id
    and profile.active is true
    and lower(coalesce(profile.role, 'foreman')) in ('foreman', 'gf')
  order by
    case when lower(coalesce(profile.role, 'foreman')) = 'gf' then 0 else 1 end,
    lower(coalesce(profile.full_name, ''));
end;
$$;

create or replace function public.get_job_leader_assignments()
returns table (
  job_id uuid,
  member_id uuid,
  full_name text,
  member_role text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin', 'gf') then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin or General Foreman can view job leader assignments.';
  end if;

  return query
  select
    assignment.job_id,
    assignment.member_id,
    coalesce(nullif(trim(profile.full_name), ''), 'Unnamed Team Member')::text,
    lower(coalesce(profile.role, 'foreman'))::text
  from public.job_leader_assignments assignment
  join public.jobs job
    on job.id = assignment.job_id
   and job.company_id = assignment.company_id
  join public.profiles profile
    on profile.id = assignment.member_id
   and profile.company_id = assignment.company_id
  where assignment.company_id = v_company_id
  order by lower(coalesce(profile.full_name, ''));
end;
$$;

create or replace function public.set_job_leader_assignment(
  p_job_id uuid,
  p_member_id uuid,
  p_assigned boolean
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
  v_member_role text;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin', 'gf') then
    raise exception using errcode = '42501',
      message = 'Only an active company Admin or General Foreman can change job leaders.';
  end if;

  if not exists (
    select 1
    from public.jobs job
    where job.id = p_job_id
      and job.company_id = v_company_id
  ) then
    raise exception using errcode = 'P0002',
      message = 'Job was not found in your company.';
  end if;

  select lower(coalesce(profile.role, 'foreman'))
  into v_member_role
  from public.profiles profile
  where profile.id = p_member_id
    and profile.company_id = v_company_id
    and profile.active is true;

  if v_member_role is null or v_member_role not in ('foreman', 'gf') then
    raise exception using errcode = '22023',
      message = 'Select an active Foreman or General Foreman from your company.';
  end if;

  if coalesce(p_assigned, false) then
    insert into public.job_leader_assignments (
      company_id,
      job_id,
      member_id,
      assigned_by
    ) values (
      v_company_id,
      p_job_id,
      p_member_id,
      auth.uid()
    )
    on conflict (job_id, member_id) do nothing;
  else
    delete from public.job_leader_assignments assignment
    where assignment.company_id = v_company_id
      and assignment.job_id = p_job_id
      and assignment.member_id = p_member_id;
  end if;
end;
$$;

revoke all on function public.get_assignable_job_leaders() from public, anon;
revoke all on function public.get_job_leader_assignments() from public, anon;
revoke all on function public.set_job_leader_assignment(uuid, uuid, boolean)
  from public, anon;

grant execute on function public.get_assignable_job_leaders()
  to authenticated;
grant execute on function public.get_job_leader_assignments()
  to authenticated;
grant execute on function public.set_job_leader_assignment(uuid, uuid, boolean)
  to authenticated;

commit;
