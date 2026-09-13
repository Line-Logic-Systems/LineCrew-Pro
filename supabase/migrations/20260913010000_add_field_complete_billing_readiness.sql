-- Preserve the latest accepted authorization baseline after a package is closed.
-- A closed package is historical but remains the active commercial baseline until
-- a newer revision is activated.
do $$
declare v_oid oid; v_definition text; v_updated text;
begin
  v_oid:=to_regprocedure('public.get_job_progress_dashboard_v2(uuid)');
  if v_oid is null then raise exception 'get_job_progress_dashboard_v2(uuid) is missing'; end if;
  select pg_get_functiondef(v_oid) into v_definition;
  v_updated:=replace(
    v_definition,
    'where package.company_id=v_company_id and package.status=''active''',
    'where package.company_id=v_company_id and package.status in (''active'',''closed'')
      and package.id=(select candidate.id from public.job_packages candidate
        where candidate.company_id=package.company_id and candidate.job_id=package.job_id
          and candidate.status in (''active'',''closed'')
        order by candidate.revision_number desc,candidate.created_at desc,candidate.id desc limit 1)'
  );
  if v_updated=v_definition then
    raise exception 'Expected active-package dashboard predicates were not found';
  end if;
  execute v_updated;
end $$;

-- General Foremen review field production, but package lifecycle is an Admin control.
do $$
declare v_oid oid; v_definition text; v_updated text;
begin
  v_oid:=to_regprocedure('public.set_job_package_status(uuid,text)');
  if v_oid is null then raise exception 'set_job_package_status(uuid,text) is missing'; end if;
  select pg_get_functiondef(v_oid) into v_definition;
  v_updated:=replace(v_definition,'begin
  if not public.linecrew_can_manage_job_packages() then','BEGIN
  if exists(select 1 from public.profiles p where p.id=auth.uid()
    and p.active is true and lower(coalesce(p.role,''))=''gf'') then
    raise exception using errcode=''42501'',message=''Only Admin leadership can change a utility package status.'';
  end if;
  if not public.linecrew_can_manage_job_packages() then');
  if v_updated=v_definition then
    raise exception 'Expected package-status authorization block was not found';
  end if;
  execute v_updated;
end $$;

do $$
declare v_oid oid; v_definition text; v_updated text;
begin
  v_oid:=to_regprocedure('public.get_job_billing_reconciliation_v3(uuid)');
  if v_oid is null then raise exception 'get_job_billing_reconciliation_v3(uuid) is missing'; end if;
  select pg_get_functiondef(v_oid) into v_definition;
  v_updated:=replace(
    v_definition,
    'where package.company_id=v_company_id and package.job_id=p_job_id and package.status=''active''',
    'where package.company_id=v_company_id and package.job_id=p_job_id
      and package.status in (''active'',''closed'')
      and package.id=(select candidate.id from public.job_packages candidate
        where candidate.company_id=v_company_id and candidate.job_id=p_job_id
          and candidate.status in (''active'',''closed'')
        order by candidate.revision_number desc,candidate.created_at desc,candidate.id desc limit 1)'
  );
  if v_updated=v_definition then
    raise exception 'Expected active-package reconciliation predicate was not found';
  end if;
  execute v_updated;
end $$;

create table public.job_billing_readiness (
  job_id uuid primary key references public.jobs(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  status text not null default 'not_ready'
    check (status in ('not_ready','ready')),
  submitted_by uuid references auth.users(id),
  submitted_at timestamptz,
  override_reason text,
  returned_by uuid references auth.users(id),
  returned_at timestamptz,
  return_reason text,
  updated_at timestamptz not null default now()
);

create table public.job_billing_readiness_events (
  id bigint generated always as identity primary key,
  job_id uuid not null references public.jobs(id) on delete cascade,
  company_id uuid not null references public.companies(id) on delete cascade,
  actor_id uuid not null references auth.users(id),
  event_type text not null check (event_type in ('submitted','returned')),
  approved_percent numeric not null,
  reason text,
  created_at timestamptz not null default now()
);

alter table public.job_billing_readiness enable row level security;
alter table public.job_billing_readiness_events enable row level security;
revoke all on table public.job_billing_readiness from public,anon,authenticated;
revoke all on table public.job_billing_readiness_events from public,anon,authenticated;
revoke all on sequence public.job_billing_readiness_events_id_seq from public,anon,authenticated;

create or replace function public.get_job_billing_readiness(p_job_id uuid default null)
returns table(job_id uuid,status text,submitted_by uuid,submitted_at timestamptz,
  override_reason text,returned_by uuid,returned_at timestamptz,return_reason text)
language plpgsql stable security definer set search_path=''
as $$
declare v_company_id uuid; v_role text; v_active boolean;
begin
  select p.company_id,lower(coalesce(p.role,'')),p.active
    into v_company_id,v_role,v_active
  from public.profiles p where p.id=auth.uid();
  if v_company_id is null or v_active is not true or
     v_role not in ('owner','manager','admin','superintendent','gf') then
    raise exception using errcode='42501',message='Active company leadership is required.';
  end if;
  if p_job_id is not null and not exists(
    select 1 from public.jobs j where j.id=p_job_id and j.company_id=v_company_id
  ) then raise exception using errcode='P0002',message='Job was not found in your company.'; end if;
  return query select r.job_id,r.status,r.submitted_by,r.submitted_at,r.override_reason,
    r.returned_by,r.returned_at,r.return_reason
  from public.job_billing_readiness r
  where r.company_id=v_company_id and (p_job_id is null or r.job_id=p_job_id);
end;
$$;

create or replace function public.set_job_billing_readiness(
  p_job_id uuid,p_ready boolean,p_reason text default null
) returns text
language plpgsql volatile security definer set search_path=''
as $$
declare v_company_id uuid; v_role text; v_active boolean; v_job_active boolean;
  v_percent numeric; v_reason text:=nullif(btrim(coalesce(p_reason,'')),''); v_status text;
begin
  select p.company_id,lower(coalesce(p.role,'')),p.active
    into v_company_id,v_role,v_active
  from public.profiles p where p.id=auth.uid();
  if v_company_id is null or v_active is not true then
    raise exception using errcode='42501',message='An active company profile is required.';
  end if;
  if p_ready and v_role not in ('gf','owner','manager','admin') then
    raise exception using errcode='42501',message='GF or Admin leadership is required to submit a job for billing.';
  end if;
  if not p_ready and v_role not in ('owner','manager','admin') then
    raise exception using errcode='42501',message='Admin leadership is required to return a job.';
  end if;
  select j.active into v_job_active from public.jobs j
  where j.id=p_job_id and j.company_id=v_company_id for update;
  if v_job_active is null then raise exception using errcode='P0002',message='Job was not found in your company.'; end if;
  if v_job_active is not true then raise exception using errcode='22023',message='A closed job cannot change billing readiness.'; end if;
  select coalesce(d.approved_percent,0) into v_percent
  from public.get_job_progress_dashboard_v2(p_job_id) d;
  v_percent:=coalesce(v_percent,0);
  if p_ready and v_percent<100 and v_reason is null then
    raise exception using errcode='22023',message='A reason is required to submit a job below 100%.';
  end if;
  if not p_ready and v_reason is null then
    raise exception using errcode='22023',message='A return reason is required.';
  end if;
  v_status:=case when p_ready then 'ready' else 'not_ready' end;
  insert into public.job_billing_readiness(job_id,company_id,status,submitted_by,submitted_at,
    override_reason,returned_by,returned_at,return_reason,updated_at)
  values(p_job_id,v_company_id,v_status,
    case when p_ready then auth.uid() end,case when p_ready then now() end,
    case when p_ready then v_reason end,case when not p_ready then auth.uid() end,
    case when not p_ready then now() end,case when not p_ready then v_reason end,now())
  on conflict(job_id) do update set status=excluded.status,
    submitted_by=case when p_ready then auth.uid() else job_billing_readiness.submitted_by end,
    submitted_at=case when p_ready then now() else job_billing_readiness.submitted_at end,
    override_reason=case when p_ready then v_reason else job_billing_readiness.override_reason end,
    returned_by=case when not p_ready then auth.uid() else null end,
    returned_at=case when not p_ready then now() else null end,
    return_reason=case when not p_ready then v_reason else null end,updated_at=now();
  insert into public.job_billing_readiness_events(
    job_id,company_id,actor_id,event_type,approved_percent,reason
  ) values(p_job_id,v_company_id,auth.uid(),case when p_ready then 'submitted' else 'returned' end,v_percent,v_reason);
  return v_status;
end;
$$;

revoke all on function public.get_job_billing_readiness(uuid) from public,anon;
revoke all on function public.set_job_billing_readiness(uuid,boolean,text) from public,anon;
grant execute on function public.get_job_billing_readiness(uuid) to authenticated,service_role;
grant execute on function public.set_job_billing_readiness(uuid,boolean,text) to authenticated,service_role;

comment on function public.set_job_billing_readiness(uuid,boolean,text) is
  'GF/Admin field-complete handoff to billing. Below-100 submissions and all Admin returns require an audited reason; this never closes a package or job.';
