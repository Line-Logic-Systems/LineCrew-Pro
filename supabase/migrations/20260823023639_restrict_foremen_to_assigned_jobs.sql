begin;

-- Preserve a permanent record of who assigned or unassigned each job leader.
create table if not exists public.job_assignment_audit_events (
  id bigint generated always as identity primary key,
  company_id uuid not null references public.companies(id) on delete cascade,
  job_id uuid null references public.jobs(id) on delete set null,
  member_id uuid null references public.profiles(id) on delete set null,
  actor_id uuid null references public.profiles(id) on delete set null,
  action text not null check (action in ('assigned', 'unassigned')),
  job_number text not null,
  member_name text not null,
  actor_name text not null,
  created_at timestamptz not null default now()
);

create index if not exists job_assignment_audit_company_job_idx
  on public.job_assignment_audit_events(company_id, job_id, created_at desc);

create index if not exists job_assignment_audit_company_member_idx
  on public.job_assignment_audit_events(company_id, member_id, created_at desc);

alter table public.job_assignment_audit_events enable row level security;
revoke all on table public.job_assignment_audit_events from anon, authenticated;

-- This helper is used by RLS and write guards. It never accepts a company id
-- from the client; the current authenticated profile is the authority.
create or replace function public.linecrew_foreman_has_job_assignment(p_job_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.profiles profile
    join public.job_leader_assignments assignment
      on assignment.member_id = profile.id
     and assignment.company_id = profile.company_id
    join public.jobs job
      on job.id = assignment.job_id
     and job.company_id = assignment.company_id
    where profile.id = auth.uid()
      and profile.active is true
      and lower(coalesce(profile.role, '')) = 'foreman'
      and assignment.job_id = p_job_id
  );
$$;

revoke all on function public.linecrew_foreman_has_job_assignment(uuid)
  from public, anon;
grant execute on function public.linecrew_foreman_has_job_assignment(uuid)
  to authenticated;

-- Remove the former broad policies. They allowed every active company member
-- to read and mutate every job, which made assignments informational only.
drop policy if exists active_profile_required on public.jobs;
drop policy if exists jobs_same_company_select on public.jobs;
drop policy if exists jobs_admin_gf_manage on public.jobs;
drop policy if exists linecrew_owner_jobs_manage on public.jobs;
drop policy if exists linecrew_superintendent_jobs_manage on public.jobs;

create policy jobs_role_scoped_select
on public.jobs
for select
to authenticated
using (
  company_id = (select public.my_company_id())
  and (select public.current_user_has_active_profile())
  and (
    lower(coalesce((select public.my_role()), '')) in ('owner', 'admin', 'gf')
    or (
      lower(coalesce((select public.my_role()), '')) = 'superintendent'
      and (select public.linecrew_has_capability('jobs'))
    )
    or (
      lower(coalesce((select public.my_role()), '')) = 'foreman'
      and (select public.linecrew_foreman_has_job_assignment(id))
    )
  )
);

create policy jobs_admin_gf_manage
on public.jobs
for all
to authenticated
using (
  company_id = (select public.my_company_id())
  and (select public.current_user_has_active_profile())
  and lower(coalesce((select public.my_role()), '')) in ('admin', 'gf')
)
with check (
  company_id = (select public.my_company_id())
  and (select public.current_user_has_active_profile())
  and lower(coalesce((select public.my_role()), '')) in ('admin', 'gf')
);

create policy linecrew_owner_jobs_manage
on public.jobs
for all
to authenticated
using (
  company_id = (select public.my_company_id())
  and (select public.current_user_has_active_profile())
  and lower(coalesce((select public.my_role()), '')) = 'owner'
)
with check (
  company_id = (select public.my_company_id())
  and (select public.current_user_has_active_profile())
  and lower(coalesce((select public.my_role()), '')) = 'owner'
);

create policy linecrew_superintendent_jobs_manage
on public.jobs
for all
to authenticated
using (
  company_id = (select public.my_company_id())
  and (select public.current_user_has_active_profile())
  and lower(coalesce((select public.my_role()), '')) = 'superintendent'
  and (select public.linecrew_has_capability('jobs'))
)
with check (
  company_id = (select public.my_company_id())
  and (select public.current_user_has_active_profile())
  and lower(coalesce((select public.my_role()), '')) = 'superintendent'
  and (select public.linecrew_has_capability('jobs'))
);

-- Foremen can inspect only their own assignment rows. Leadership with Jobs
-- authority can inspect assignment records for its company.
drop policy if exists job_leader_assignments_same_company_select
  on public.job_leader_assignments;

create policy job_leader_assignments_role_scoped_select
on public.job_leader_assignments
for select
to authenticated
using (
  company_id = (select public.my_company_id())
  and (select public.current_user_has_active_profile())
  and (
    member_id = auth.uid()
    or lower(coalesce((select public.my_role()), '')) in ('owner', 'admin', 'gf')
    or (
      lower(coalesce((select public.my_role()), '')) = 'superintendent'
      and (select public.linecrew_has_capability('jobs'))
    )
  )
);

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
     v_role not in ('owner', 'admin', 'gf', 'superintendent') or
     (v_role = 'superintendent' and not public.linecrew_has_capability('jobs')) then
    raise exception using errcode = '42501',
      message = 'Jobs permission is required to manage job assignments.';
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

drop function if exists public.get_job_leader_assignments();
create function public.get_job_leader_assignments()
returns table (
  job_id uuid,
  member_id uuid,
  full_name text,
  member_role text,
  assigned_by_name text,
  assigned_at timestamptz
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
     v_role not in ('owner', 'admin', 'gf', 'superintendent') or
     (v_role = 'superintendent' and not public.linecrew_has_capability('jobs')) then
    raise exception using errcode = '42501',
      message = 'Jobs permission is required to view job assignments.';
  end if;

  return query
  select
    assignment.job_id,
    assignment.member_id,
    coalesce(nullif(trim(member.full_name), ''), 'Unnamed Team Member')::text,
    lower(coalesce(member.role, 'foreman'))::text,
    coalesce(nullif(trim(actor.full_name), ''), 'Unknown Team Member')::text,
    assignment.created_at
  from public.job_leader_assignments assignment
  join public.jobs job
    on job.id = assignment.job_id
   and job.company_id = assignment.company_id
  join public.profiles member
    on member.id = assignment.member_id
   and member.company_id = assignment.company_id
  left join public.profiles actor
    on actor.id = assignment.assigned_by
   and actor.company_id = assignment.company_id
  where assignment.company_id = v_company_id
  order by lower(coalesce(member.full_name, ''));
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
  v_member_name text;
  v_actor_name text;
  v_job_number text;
  v_changed boolean := false;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active,
         coalesce(nullif(trim(profile.full_name), ''), 'Unknown Team Member')
  into v_company_id, v_role, v_active, v_actor_name
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('owner', 'admin', 'gf', 'superintendent') or
     (v_role = 'superintendent' and not public.linecrew_has_capability('jobs')) then
    raise exception using errcode = '42501',
      message = 'Jobs permission is required to change job assignments.';
  end if;

  select job.job_number
  into v_job_number
  from public.jobs job
  where job.id = p_job_id
    and job.company_id = v_company_id;

  if v_job_number is null then
    raise exception using errcode = 'P0002',
      message = 'Job was not found in your company.';
  end if;

  select lower(coalesce(profile.role, 'foreman')),
         coalesce(nullif(trim(profile.full_name), ''), 'Unnamed Team Member')
  into v_member_role, v_member_name
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
      company_id, job_id, member_id, assigned_by, created_at
    ) values (
      v_company_id, p_job_id, p_member_id, auth.uid(), now()
    )
    on conflict (job_id, member_id) do nothing;
    v_changed := found;
  else
    delete from public.job_leader_assignments assignment
    where assignment.company_id = v_company_id
      and assignment.job_id = p_job_id
      and assignment.member_id = p_member_id;
    v_changed := found;
  end if;

  if v_changed then
    insert into public.job_assignment_audit_events (
      company_id, job_id, member_id, actor_id, action,
      job_number, member_name, actor_name
    ) values (
      v_company_id, p_job_id, p_member_id, auth.uid(),
      case when coalesce(p_assigned, false) then 'assigned' else 'unassigned' end,
      v_job_number, v_member_name, v_actor_name
    );
  end if;
end;
$$;

create or replace function public.get_job_assignment_history(p_job_id uuid)
returns table (
  action text,
  member_name text,
  actor_name text,
  event_at timestamptz
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
     v_role not in ('owner', 'admin', 'gf', 'superintendent') or
     (v_role = 'superintendent' and not public.linecrew_has_capability('jobs')) then
    raise exception using errcode = '42501',
      message = 'Jobs permission is required to view assignment history.';
  end if;

  if not exists (
    select 1 from public.jobs job
    where job.id = p_job_id and job.company_id = v_company_id
  ) then
    raise exception using errcode = 'P0002',
      message = 'Job was not found in your company.';
  end if;

  return query
  select event.action, event.member_name, event.actor_name, event.created_at
  from public.job_assignment_audit_events event
  where event.company_id = v_company_id
    and event.job_id = p_job_id
  order by event.created_at desc, event.id desc;
end;
$$;

-- A Foreman cannot create or move a daily report/JSA to a guessed job UUID.
-- The guards run inside the database even when the calling RPC is definer-based.
create or replace function public.enforce_foreman_assigned_job()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_role text;
  v_active boolean;
  v_company_id uuid;
begin
  if auth.uid() is null then
    return new;
  end if;

  select lower(coalesce(profile.role, '')), profile.active, profile.company_id
  into v_role, v_active, v_company_id
  from public.profiles profile
  where profile.id = auth.uid();

  if v_active is not true then
    raise exception using errcode = '42501',
      message = 'An active company profile is required.';
  end if;

  if v_role = 'foreman' and (
    new.company_id is distinct from v_company_id
    or not public.linecrew_foreman_has_job_assignment(new.job_id)
  ) then
    raise exception using errcode = '42501',
      message = 'This job is not assigned to you.';
  end if;

  return new;
end;
$$;

drop trigger if exists daily_reports_foreman_assigned_job
  on public.daily_reports;
create trigger daily_reports_foreman_assigned_job
before insert or update of job_id, company_id
on public.daily_reports
for each row execute function public.enforce_foreman_assigned_job();

drop trigger if exists daily_report_jsas_foreman_assigned_job
  on public.daily_report_jsas;
create trigger daily_report_jsas_foreman_assigned_job
before insert or update of job_id, company_id
on public.daily_report_jsas
for each row execute function public.enforce_foreman_assigned_job();

revoke all on function public.get_assignable_job_leaders() from public, anon, authenticated;
revoke all on function public.get_job_leader_assignments() from public, anon, authenticated;
revoke all on function public.set_job_leader_assignment(uuid, uuid, boolean) from public, anon, authenticated;
revoke all on function public.get_job_assignment_history(uuid) from public, anon, authenticated;
revoke all on function public.enforce_foreman_assigned_job() from public, anon, authenticated;

grant execute on function public.get_assignable_job_leaders() to authenticated;
grant execute on function public.get_job_leader_assignments() to authenticated;
grant execute on function public.set_job_leader_assignment(uuid, uuid, boolean) to authenticated;
grant execute on function public.get_job_assignment_history(uuid) to authenticated;

commit;
