begin;

alter table public.billing_export_batches
  add column if not exists billing_type text,
  add column if not exists billing_sequence integer;

with numbered as (
  select id,
    row_number() over (
      partition by company_id, job_id
      order by created_at, id
    )::integer as sequence_number
  from public.billing_export_batches
)
update public.billing_export_batches batch
set billing_type=coalesce(batch.billing_type,'partial'),
    billing_sequence=coalesce(batch.billing_sequence,numbered.sequence_number)
from numbered
where numbered.id=batch.id;

alter table public.billing_export_batches
  alter column billing_type set default 'partial',
  alter column billing_type set not null,
  alter column billing_sequence set default 1,
  alter column billing_sequence set not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname='billing_export_batches_type_check'
      and conrelid='public.billing_export_batches'::regclass
  ) then
    alter table public.billing_export_batches
      add constraint billing_export_batches_type_check
      check (billing_type in ('partial','final'));
  end if;
end;
$$;

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

  v_batch_id:=public.create_billing_export_batch(
    p_job_id,p_date_from,p_date_to,p_include_redlines,p_notes
  );

  update public.billing_export_batches batch
  set billing_type=case when coalesce(p_is_final,false) then 'final' else 'partial' end,
      billing_sequence=v_sequence
  where batch.id=v_batch_id and batch.company_id=v_company_id;

  return v_batch_id;
end;
$$;

create or replace function public.get_billing_export_batches_v2()
returns table(
  batch_id uuid,batch_number text,job_id uuid,job_number text,job_name text,
  date_from date,date_to date,include_redlines boolean,status text,
  billing_type text,billing_sequence integer,
  authorized_line_count integer,redline_line_count integer,total_value numeric,
  notes text,created_by_name text,created_at timestamptz,exported_at timestamptz,
  submitted_at timestamptz,paid_at timestamptz,voided_at timestamptz
)
language plpgsql stable security definer set search_path=''
as $$
declare v_company_id uuid; v_role text; v_active boolean;
begin
  select profile.company_id,lower(coalesce(profile.role,'')),profile.active
  into v_company_id,v_role,v_active
  from public.profiles profile where profile.id=auth.uid();

  if v_company_id is null or v_active is not true or
     v_role not in ('admin','owner','superintendent') then
    raise exception using errcode='42501',message='Billing export access is required.';
  end if;
  if v_role='superintendent' and (
    not public.linecrew_has_capability('reporting') or
    not public.linecrew_has_capability('actual_pricing')
  ) then
    raise exception using errcode='42501',
      message='Reporting and Actual Pricing permissions are required.';
  end if;

  return query
  select batch.id,batch.batch_number,batch.job_id,job.job_number,job.job_name,
    batch.date_from,batch.date_to,batch.include_redlines,batch.status,
    batch.billing_type,batch.billing_sequence,
    batch.authorized_line_count,batch.redline_line_count,batch.total_value,
    batch.notes,creator.full_name,batch.created_at,batch.exported_at,
    batch.submitted_at,batch.paid_at,batch.voided_at
  from public.billing_export_batches batch
  join public.jobs job on job.id=batch.job_id and job.company_id=batch.company_id
  left join public.profiles creator on creator.id=batch.created_by
  where batch.company_id=v_company_id
  order by batch.created_at desc;
end;
$$;

revoke all on function public.create_billing_export_batch_v2(uuid,date,date,boolean,text,boolean)
  from public,anon;
revoke all on function public.get_billing_export_batches_v2() from public,anon;
revoke execute on function public.create_billing_export_batch(uuid,date,date,boolean,text)
  from authenticated;
grant execute on function public.create_billing_export_batch_v2(uuid,date,date,boolean,text,boolean)
  to authenticated;
grant execute on function public.get_billing_export_batches_v2() to authenticated;

commit;
