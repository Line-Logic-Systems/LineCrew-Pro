begin;

-- Supervisors who can view the production dashboard also need the assignment
-- names shown on each progress card. Assignment changes remain limited to the
-- separate Jobs permission and set_job_leader_assignment RPC.
create or replace function public.get_job_leader_assignments()
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
     (
       v_role = 'superintendent'
       and not public.linecrew_has_capability('jobs')
       and not public.linecrew_has_capability('reporting')
     ) then
    raise exception using errcode = '42501',
      message = 'Jobs or Reporting permission is required to view job assignments.';
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

revoke all on function public.get_job_leader_assignments()
  from public, anon, authenticated;
grant execute on function public.get_job_leader_assignments()
  to authenticated;

commit;
