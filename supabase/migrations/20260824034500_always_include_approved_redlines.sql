begin;

comment on column public.billing_export_batches.include_redlines is
  'True when exports should add a separate redline summary. Approved redlines are always included in the main billing production.';

create or replace function public.create_billing_export_batch_v2(
  p_job_id uuid,
  p_date_from date default null,
  p_date_to date default null,
  p_include_redlines boolean default false,
  p_notes text default null,
  p_is_final boolean default false
)
returns uuid
language plpgsql
security definer
set search_path=''
as $$
declare
  v_company_id uuid;
  v_batch_id uuid;
  v_sequence integer;
begin
  select profile.company_id
  into v_company_id
  from public.profiles profile
  where profile.id=auth.uid() and profile.active=true;

  if v_company_id is null then
    raise exception using errcode='42501',message='An active company profile is required.';
  end if;

  perform 1
  from public.jobs job
  where job.id=p_job_id and job.company_id=v_company_id
  for update;
  if not found then
    raise exception using errcode='P0002',message='Job was not found in your company.';
  end if;

  if exists (
    select 1
    from public.billing_export_batches batch
    where batch.company_id=v_company_id
      and batch.job_id=p_job_id
      and batch.billing_type='final'
      and batch.status<>'void'
  ) then
    raise exception using errcode='23514',
      message='This job already has an active Final Bill. Void it before creating another billing batch.';
  end if;

  select coalesce(max(batch.billing_sequence),0)+1
  into v_sequence
  from public.billing_export_batches batch
  where batch.company_id=v_company_id and batch.job_id=p_job_id;

  -- Approved redlines always belong in the billing batch and remain beside
  -- their work point. The checkbox only controls the extra export summary.
  v_batch_id:=public.create_billing_export_batch(
    p_job_id,p_date_from,p_date_to,true,p_notes
  );

  update public.billing_export_batches batch
  set billing_type=case when coalesce(p_is_final,false) then 'final' else 'partial' end,
      billing_sequence=v_sequence,
      include_redlines=coalesce(p_include_redlines,false)
  where batch.id=v_batch_id and batch.company_id=v_company_id;

  return v_batch_id;
end;
$$;

revoke all on function public.create_billing_export_batch_v2(uuid,date,date,boolean,text,boolean)
  from public,anon;
grant execute on function public.create_billing_export_batch_v2(uuid,date,date,boolean,text,boolean)
  to authenticated;

commit;
