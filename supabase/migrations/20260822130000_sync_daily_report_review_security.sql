-- Track the live Daily Report RPCs, widen leadership review permissions to the
-- documented role model, and keep JSA reads aligned with application access.

begin;

create or replace function public.can_review_daily_reports()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.profiles p
    where p.id = auth.uid()
      and p.company_id = public.my_company_id()
      and p.active is true
      and (
        lower(p.role) in ('owner', 'admin', 'gf')
        or (
          lower(p.role) = 'superintendent'
          and public.linecrew_has_capability('production_review')
        )
      )
  );
$$;

create or replace function public.create_daily_report(
  p_job_id uuid,
  p_work_date date,
  p_regular_hours numeric default 0,
  p_overtime_hours numeric default 0,
  p_crew_name text default null,
  p_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid;
  v_report_id uuid;
  v_foreman_name text;
begin
  select p.company_id, p.full_name
  into v_company_id, v_foreman_name
  from public.profiles p
  where p.id = auth.uid()
    and p.active is true;

  if v_company_id is null then
    raise exception 'An active user profile is required';
  end if;

  if not exists (
    select 1
    from public.jobs j
    where j.id = p_job_id
      and j.company_id = v_company_id
      and j.active is true
  ) then
    raise exception 'Active job not found';
  end if;

  insert into public.daily_reports (
    company_id, job_id, work_date, foreman_id, created_by, foreman_name,
    crew_name, regular_hours, overtime_hours, notes
  ) values (
    v_company_id, p_job_id, coalesce(p_work_date, current_date), auth.uid(),
    auth.uid(), v_foreman_name, nullif(trim(p_crew_name), ''),
    coalesce(p_regular_hours, 0), coalesce(p_overtime_hours, 0),
    nullif(trim(p_notes), '')
  )
  returning id into v_report_id;

  return v_report_id;
end;
$$;

create or replace function public.update_daily_report(
  p_report_id uuid,
  p_job_id uuid,
  p_work_date date,
  p_regular_hours numeric,
  p_overtime_hours numeric,
  p_crew_name text,
  p_notes text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_company_id uuid := public.my_company_id();
begin
  if auth.uid() is null or v_company_id is null then
    raise exception 'Not authenticated';
  end if;

  if not exists (
    select 1
    from public.jobs j
    where j.id = p_job_id
      and j.company_id = v_company_id
      and j.active is true
  ) then
    raise exception 'Active job not found';
  end if;

  update public.daily_reports
  set job_id = p_job_id,
      work_date = p_work_date,
      regular_hours = coalesce(p_regular_hours, 0),
      overtime_hours = coalesce(p_overtime_hours, 0),
      crew_name = nullif(trim(p_crew_name), ''),
      notes = nullif(trim(p_notes), ''),
      updated_at = now()
  where id = p_report_id
    and company_id = v_company_id
    and status = 'draft'
    and foreman_id = auth.uid();

  if not found then
    raise exception 'Draft report not found or cannot be edited';
  end if;
end;
$$;

create or replace function public.return_daily_report(
  p_report_id uuid,
  p_review_notes text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.can_review_daily_reports() then
    raise exception 'You do not have permission to return reports';
  end if;

  if nullif(trim(p_review_notes), '') is null then
    raise exception 'Review notes are required when returning a report';
  end if;

  update public.daily_reports
  set status = 'draft',
      reviewed_at = now(),
      review_notes = trim(p_review_notes),
      updated_at = now()
  where id = p_report_id
    and company_id = public.my_company_id()
    and status = 'submitted';

  if not found then
    raise exception 'Report not found or cannot be returned';
  end if;
end;
$$;

revoke all on function public.can_review_daily_reports() from public, anon;
revoke all on function public.create_daily_report(uuid,date,numeric,numeric,text,text) from public, anon;
revoke all on function public.update_daily_report(uuid,uuid,date,numeric,numeric,text,text) from public, anon;
revoke all on function public.return_daily_report(uuid,text) from public, anon;
grant execute on function public.can_review_daily_reports() to authenticated;
grant execute on function public.create_daily_report(uuid,date,numeric,numeric,text,text) to authenticated;
grant execute on function public.update_daily_report(uuid,uuid,date,numeric,numeric,text,text) to authenticated;
grant execute on function public.return_daily_report(uuid,text) to authenticated;

drop policy if exists daily_report_jsas_same_company_select on public.daily_report_jsas;
create policy daily_report_jsas_role_scoped_select
on public.daily_report_jsas
for select
to authenticated
using (
  company_id = public.my_company_id()
  and (
    created_by = auth.uid()
    or public.my_role() in ('owner', 'admin', 'gf')
    or (
      public.my_role() = 'superintendent'
      and public.linecrew_has_capability('safety_records')
    )
  )
);

drop policy if exists "jsa attachment company read" on public.jsa_upload_attachments;
create policy "jsa attachment role scoped read"
on public.jsa_upload_attachments
for select
to authenticated
using (
  company_id = public.my_company_id()
  and exists (
    select 1
    from public.daily_report_jsas j
    where j.id = jsa_upload_attachments.jsa_id
      and j.company_id = jsa_upload_attachments.company_id
      and (
        j.created_by = auth.uid()
        or public.my_role() in ('owner', 'admin', 'gf')
        or (
          public.my_role() = 'superintendent'
          and public.linecrew_has_capability('safety_records')
        )
      )
  )
);

commit;
