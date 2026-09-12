create or replace function public.submit_daily_report(p_report_id uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_reviewed_at timestamptz;
  v_review_notes text;
  v_corrections text;
  v_reg numeric := 0;
  v_ot numeric := 0;
begin
  if auth.uid() is null then
    raise exception 'Not authenticated';
  end if;

  if not exists (
    select 1
    from public.daily_reports report
    join public.jobs job
      on job.id = report.job_id
     and job.company_id = report.company_id
    where report.id = p_report_id
      and report.company_id = public.my_company_id()
      and report.foreman_id = auth.uid()
      and report.status in ('draft','rejected')
      and job.active is true
  ) then
    raise exception 'Report not found, job is closed, or report cannot be submitted';
  end if;

  if not exists (
    select 1 from public.daily_production_unit_locations l
    where l.daily_report_id = p_report_id
      and l.company_id = public.my_company_id()
  ) then
    raise exception 'Add at least one unit before submitting this daily report.';
  end if;

  if exists (
    select 1
    from public.get_daily_report_unit_locations_visible_v2(p_report_id) item
    join public.daily_production_unit_locations location
      on location.id = item.location_line_id
     and location.company_id = public.my_company_id()
    where item.authorization_status = 'redline'
      and nullif(btrim(coalesce(location.redline_comment, '')), '') is null
  ) then
    raise exception 'Add a comment explaining each redline before submitting this daily report.';
  end if;

  if not exists (
    select 1 from public.timekeeping_entries t
    where t.daily_report_id=p_report_id
      and t.company_id=public.my_company_id()
  ) then
    raise exception 'Add Crew Time for at least one employee before submitting this daily report.';
  end if;

  select coalesce(sum(t.regular_hours),0), coalesce(sum(t.overtime_hours),0)
    into v_reg, v_ot
  from public.timekeeping_entries t
  where t.daily_report_id=p_report_id
    and t.company_id=public.my_company_id();

  select report.reviewed_at, report.review_notes
  into v_reviewed_at, v_review_notes
  from public.daily_reports report
  join public.jobs job
    on job.id = report.job_id
   and job.company_id = report.company_id
  where report.id=p_report_id
    and report.company_id=public.my_company_id()
    and report.foreman_id=auth.uid()
    and report.status in ('draft','rejected')
    and job.active is true
  for update of report;

  if not found then
    raise exception 'Report not found, job is closed, or report cannot be submitted';
  end if;

  if v_reviewed_at is not null and nullif(btrim(coalesce(v_review_notes,'')),'') is not null then
    select string_agg('• ' || e.event_notes, E'\n' order by e.created_at)
    into v_corrections
    from public.daily_report_audit_events e
    where e.daily_report_id=p_report_id
      and e.company_id=public.my_company_id()
      and e.event_type='foreman_correction'
      and e.created_at >= v_reviewed_at;
  end if;

  update public.daily_reports report
  set status='submitted',
      submitted_at=now(),
      updated_at=now(),
      regular_hours=v_reg,
      overtime_hours=v_ot,
      hours=v_reg+v_ot,
      review_notes = case
        when nullif(v_corrections,'') is not null then
          regexp_replace(coalesce(v_review_notes,''), E'\n\nFOREMAN CORRECTIONS:[\s\S]*$', '', 'g') || E'\n\nFOREMAN CORRECTIONS:\n' || v_corrections
        else v_review_notes
      end
  where report.id=p_report_id
    and report.company_id=public.my_company_id()
    and report.foreman_id=auth.uid()
    and report.status in ('draft','rejected')
    and exists (
      select 1 from public.jobs job
      where job.id=report.job_id
        and job.company_id=report.company_id
        and job.active is true
    );

  if not found then
    raise exception 'Job closed or report changed before submission completed';
  end if;
end;
$$;

revoke all on function public.submit_daily_report(uuid) from public, anon;
grant execute on function public.submit_daily_report(uuid) to authenticated, service_role;

create or replace function public.approve_daily_report(p_report_id uuid, p_review_notes text default null)
returns void
language plpgsql
security definer
set search_path to ''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
  v_report_company_id uuid;
  v_report_status text;
  v_report_creator uuid;
  v_report_foreman uuid;
  v_require_gf boolean;
  v_redline_count bigint;
  v_existing_notes text;
  v_new_note text;
  v_job_active boolean;
begin
  select profile.company_id, lower(coalesce(profile.role, '')), profile.active
  into v_company_id, v_role, v_active
  from public.profiles profile
  where profile.id = auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin','manager','gf','owner','superintendent') then
    raise exception using errcode='42501',
      message='Only active company leadership can approve reports.';
  end if;

  if v_role = 'superintendent' and not public.linecrew_has_capability('production_review') then
    raise exception using errcode='42501',
      message='This Superintendent does not have production review permission.';
  end if;

  select report.company_id, lower(coalesce(report.status,'draft')),
         report.created_by, report.foreman_id, report.review_notes, job.active
  into v_report_company_id, v_report_status, v_report_creator,
       v_report_foreman, v_existing_notes, v_job_active
  from public.daily_reports report
  join public.jobs job
    on job.id=report.job_id
   and job.company_id=report.company_id
  where report.id=p_report_id
  for update of report;

  if v_report_company_id is null or v_report_company_id <> v_company_id then
    raise exception using errcode='P0002',
      message='Daily report was not found in your company.';
  end if;

  if v_job_active is not true then
    raise exception using errcode='23514',
      message='Closed jobs are read-only. Reopen the job before approving this report.';
  end if;

  if v_report_status <> 'submitted' then
    raise exception using errcode='23514',
      message='Only submitted reports can be approved.';
  end if;

  if auth.uid() = v_report_creator or auth.uid() = v_report_foreman then
    raise exception using errcode='42501',
      message='A Daily Report must be approved by someone other than its author or Foreman.';
  end if;

  select company.require_gf_redline_approval
  into v_require_gf
  from public.companies company
  where company.id=v_company_id;

  select count(*)
  into v_redline_count
  from public.get_daily_report_unit_locations_v2(p_report_id) location
  where location.authorization_status='redline';

  v_new_note := nullif(btrim(coalesce(p_review_notes,'')),'');

  if coalesce(v_require_gf,false) and v_redline_count > 0 and
     v_role in ('admin','manager','owner','superintendent') and v_new_note is null then
    raise exception using errcode='22023',
      message='Enter an override reason because this company requires GF approval for redlines.';
  end if;

  update public.daily_reports report
  set status='approved',
      approved_by=auth.uid(),
      approved_at=now(),
      reviewed_by=auth.uid(),
      reviewed_at=now(),
      updated_at=now(),
      review_notes=case
        when v_new_note is null then v_existing_notes
        when nullif(btrim(coalesce(v_existing_notes,'')),'') is null then v_new_note
        else btrim(v_existing_notes) || E'\n\nGF APPROVAL:\n' || v_new_note
      end,
      redline_override_by=case
        when coalesce(v_require_gf,false) and v_redline_count > 0 and
             v_role in ('admin','manager','owner','superintendent') then auth.uid()
        else null
      end,
      redline_override_reason=case
        when coalesce(v_require_gf,false) and v_redline_count > 0 and
             v_role in ('admin','manager','owner','superintendent') then v_new_note
        else null
      end,
      redline_override_at=case
        when coalesce(v_require_gf,false) and v_redline_count > 0 and
             v_role in ('admin','manager','owner','superintendent') then now()
        else null
      end
  where report.id=p_report_id
    and report.company_id=v_company_id
    and report.status='submitted'
    and exists (
      select 1 from public.jobs job
      where job.id=report.job_id
        and job.company_id=report.company_id
        and job.active is true
    );

  if not found then
    raise exception using errcode='40001',
      message='Job closed or report changed before approval completed.';
  end if;
end;
$$;

revoke all on function public.approve_daily_report(uuid,text) from public, anon;
grant execute on function public.approve_daily_report(uuid,text) to authenticated, service_role;

drop policy if exists daily_reports_leadership_update on public.daily_reports;
create policy daily_reports_leadership_update
on public.daily_reports
for update
to authenticated
using (
  company_id = public.my_company_id()
  and lower(coalesce(public.my_role(),'')) in ('owner','manager','admin','gf')
  and exists (
    select 1 from public.jobs job
    where job.id = daily_reports.job_id
      and job.company_id = daily_reports.company_id
      and job.active is true
  )
)
with check (
  company_id = public.my_company_id()
  and lower(coalesce(public.my_role(),'')) in ('owner','manager','admin','gf')
  and exists (
    select 1 from public.jobs job
    where job.id = daily_reports.job_id
      and job.company_id = daily_reports.company_id
      and job.active is true
  )
);
