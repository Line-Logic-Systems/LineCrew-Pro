-- Durable, idempotent offline submission for digital and uploaded JSAs.
-- Also returns the complete expanded JSA payload for GF/supervisor review.

alter table public.daily_report_jsas
  add column if not exists client_submission_id uuid;

create unique index if not exists daily_report_jsas_company_client_submission_uidx
  on public.daily_report_jsas(company_id, client_submission_id)
  where client_submission_id is not null;

create or replace function public.create_standalone_jsa_offline(
  p_client_submission_id uuid,
  p_job_id uuid,
  p_work_date date,
  p_crew_name text,
  p_job_briefing text,
  p_hazards text,
  p_controls text,
  p_ppe text,
  p_emergency_plan text,
  p_crew_members text,
  p_weather_conditions text,
  p_special_equipment text,
  p_foreman_acknowledged boolean,
  p_details jsonb
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_existing_id uuid;
  v_existing_creator uuid;
  v_jsa_id uuid;
begin
  if p_client_submission_id is null then
    raise exception using errcode='22023', message='A client submission ID is required.';
  end if;

  select p.company_id into v_company_id
  from public.profiles p
  where p.id=(select auth.uid()) and p.active is true;

  if v_company_id is null then
    raise exception using errcode='42501', message='An active company profile is required.';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_company_id::text || ':' || p_client_submission_id::text, 0)
  );

  select j.id,j.created_by into v_existing_id,v_existing_creator
  from public.daily_report_jsas j
  where j.company_id=v_company_id and j.client_submission_id=p_client_submission_id;

  if v_existing_id is not null then
    if v_existing_creator <> (select auth.uid()) then
      raise exception using errcode='42501', message='This submission ID belongs to another user.';
    end if;
    return v_existing_id;
  end if;

  v_jsa_id := public.create_standalone_jsa_v2(
    p_job_id,
    p_work_date,
    p_crew_name,
    p_job_briefing,
    p_hazards,
    p_controls,
    p_ppe,
    p_emergency_plan,
    p_crew_members,
    p_weather_conditions,
    p_special_equipment,
    p_foreman_acknowledged,
    p_details
  );

  update public.daily_report_jsas
  set client_submission_id=p_client_submission_id
  where id=v_jsa_id and company_id=v_company_id and created_by=(select auth.uid());

  return v_jsa_id;
end;
$$;

revoke all on function public.create_standalone_jsa_offline(uuid,uuid,date,text,text,text,text,text,text,text,text,text,boolean,jsonb) from public, anon;
grant execute on function public.create_standalone_jsa_offline(uuid,uuid,date,text,text,text,text,text,text,text,text,text,boolean,jsonb) to authenticated;

create or replace function public.create_uploaded_company_jsa_offline(
  p_client_submission_id uuid,
  p_job_id uuid,
  p_work_date date,
  p_crew_name text,
  p_notes text
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_existing_id uuid;
  v_existing_creator uuid;
  v_jsa_id uuid;
begin
  if p_client_submission_id is null then
    raise exception using errcode='22023', message='A client submission ID is required.';
  end if;

  select p.company_id into v_company_id
  from public.profiles p
  where p.id=(select auth.uid()) and p.active is true;

  if v_company_id is null then
    raise exception using errcode='42501', message='An active company profile is required.';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(v_company_id::text || ':' || p_client_submission_id::text, 0)
  );

  select j.id,j.created_by into v_existing_id,v_existing_creator
  from public.daily_report_jsas j
  where j.company_id=v_company_id and j.client_submission_id=p_client_submission_id;

  if v_existing_id is not null then
    if v_existing_creator <> (select auth.uid()) then
      raise exception using errcode='42501', message='This submission ID belongs to another user.';
    end if;
    return v_existing_id;
  end if;

  v_jsa_id := public.create_uploaded_company_jsa(
    p_job_id,
    p_work_date,
    p_crew_name,
    p_notes
  );

  update public.daily_report_jsas
  set client_submission_id=p_client_submission_id
  where id=v_jsa_id and company_id=v_company_id and created_by=(select auth.uid());

  return v_jsa_id;
end;
$$;

revoke all on function public.create_uploaded_company_jsa_offline(uuid,uuid,date,text,text) from public, anon;
grant execute on function public.create_uploaded_company_jsa_offline(uuid,uuid,date,text,text) to authenticated;

-- Make attachment registration safe to replay after an interrupted upload.
create or replace function public.register_jsa_upload_attachment(
  p_jsa_id uuid,
  p_storage_path text,
  p_original_filename text,
  p_mime_type text,
  p_file_size_bytes bigint,
  p_page_order integer default 1
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company_id uuid;
  v_jsa_creator uuid;
  v_jsa_source text;
  v_id uuid;
begin
  select p.company_id into v_company_id
  from public.profiles p
  where p.id=(select auth.uid()) and p.active is true;

  select j.created_by,j.jsa_source into v_jsa_creator,v_jsa_source
  from public.daily_report_jsas j
  where j.id=p_jsa_id and j.company_id=v_company_id;

  if v_jsa_creator is null or v_jsa_source <> 'upload' then
    raise exception using errcode='P0002', message='Uploaded JSA record was not found for your company.';
  end if;
  if v_jsa_creator <> (select auth.uid()) and not exists(
    select 1 from public.profiles p
    where p.id=(select auth.uid()) and p.company_id=v_company_id and p.active is true
      and (
        lower(p.role) in ('owner','admin','gf')
        or (lower(p.role)='superintendent' and public.linecrew_has_capability('safety_records'))
      )
  ) then
    raise exception using errcode='42501', message='You cannot add files to this JSA.';
  end if;
  if p_mime_type not in ('application/pdf','image/jpeg','image/png','image/heic','image/heif')
     or p_file_size_bytes <= 0 or p_file_size_bytes > 15728640 then
    raise exception using errcode='22023', message='Upload a PDF or supported image no larger than 15 MB.';
  end if;
  if p_storage_path not like (v_company_id::text || '/' || p_jsa_id::text || '/%') then
    raise exception using errcode='42501', message='Invalid JSA storage path.';
  end if;

  insert into public.jsa_upload_attachments(
    company_id,jsa_id,storage_path,original_filename,mime_type,file_size_bytes,page_order,uploaded_by
  ) values (
    v_company_id,p_jsa_id,p_storage_path,p_original_filename,p_mime_type,p_file_size_bytes,
    greatest(coalesce(p_page_order,1),1),(select auth.uid())
  )
  on conflict (jsa_id,storage_path) do update set
    original_filename=excluded.original_filename,
    mime_type=excluded.mime_type,
    file_size_bytes=excluded.file_size_bytes,
    page_order=excluded.page_order
  returning id into v_id;

  return v_id;
end;
$$;

revoke all on function public.register_jsa_upload_attachment(uuid,text,text,text,bigint,integer) from public, anon;
grant execute on function public.register_jsa_upload_attachment(uuid,text,text,text,bigint,integer) to authenticated;

-- The scoped safety feed must include the expanded form details for a true
-- read-only copy of the Foreman's JSA. Uploaded forms remain in their file viewer.
drop function if exists public.get_company_jsas_scoped(boolean);

create function public.get_company_jsas_scoped(p_show_all boolean default false)
returns table(
  id uuid,
  daily_report_id uuid,
  job_id uuid,
  job_number text,
  job_name text,
  work_date date,
  crew_name text,
  weather_conditions text,
  job_briefing text,
  hazards text,
  controls text,
  ppe text,
  emergency_plan text,
  crew_members text,
  special_equipment text,
  foreman_name text,
  acknowledged_at timestamptz,
  created_at timestamptz,
  foreman_id uuid,
  details jsonb
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
  v_has_assignments boolean := false;
begin
  select p.company_id,lower(coalesce(p.role,'')),p.active
  into v_company_id,v_role,v_active
  from public.profiles p
  where p.id=(select auth.uid());

  if v_company_id is null or v_active is not true or
     v_role not in ('foreman','gf','admin','owner','superintendent') then
    raise exception using errcode='42501', message='You are not allowed to view JSAs.';
  end if;

  if v_role='superintendent' and not public.linecrew_has_capability('safety_records') then
    raise exception using errcode='42501', message='This Superintendent does not have safety records permission.';
  end if;

  if v_role='gf' then
    select exists(
      select 1 from public.gf_foreman_assignments a
      where a.company_id=v_company_id and a.gf_id=(select auth.uid())
    ) into v_has_assignments;
  end if;

  return query
  select safety.id,
         safety.daily_report_id,
         safety.job_id,
         job.job_number,
         job.job_name,
         safety.work_date,
         safety.crew_name,
         safety.weather_conditions,
         safety.job_briefing,
         safety.hazards,
         safety.controls,
         safety.ppe,
         safety.emergency_plan,
         safety.crew_members,
         safety.special_equipment,
         coalesce(nullif(trim(profile.full_name),''),'Foreman'),
         safety.acknowledged_at,
         safety.created_at,
         safety.created_by,
         coalesce(safety.details,'{}'::jsonb)
  from public.daily_report_jsas safety
  join public.jobs job
    on job.id=safety.job_id and job.company_id=safety.company_id
  left join public.profiles profile
    on profile.id=safety.created_by and profile.company_id=safety.company_id
  where safety.company_id=v_company_id
    and coalesce(safety.jsa_source,'digital')='digital'
    and (
      (v_role='foreman' and safety.created_by=(select auth.uid()))
      or v_role in ('admin','owner','superintendent')
      or (
        v_role='gf' and (
          coalesce(p_show_all,false)
          or not v_has_assignments
          or exists(
            select 1 from public.gf_foreman_assignments a
            where a.company_id=v_company_id
              and a.gf_id=(select auth.uid())
              and a.foreman_id=safety.created_by
          )
        )
      )
    )
  order by safety.work_date desc,safety.created_at desc;
end;
$$;

revoke all on function public.get_company_jsas_scoped(boolean) from public, anon;
grant execute on function public.get_company_jsas_scoped(boolean) to authenticated, service_role;

