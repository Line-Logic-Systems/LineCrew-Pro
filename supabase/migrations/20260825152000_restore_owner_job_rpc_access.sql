begin;

create or replace function public.update_job(
  p_job_id uuid,
  p_job_number text,
  p_job_name text,
  p_customer_name text default null,
  p_utility_name text default null
)
returns void
language plpgsql
security definer
set search_path to ''
as $$
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Not authenticated.';
  end if;
  if lower(coalesce(public.my_role(), '')) not in ('owner', 'admin', 'gf') then
    raise exception using errcode = '42501',
      message = 'Only the Company Owner, Admin or General Foreman can update jobs.';
  end if;
  update public.jobs
  set job_number = btrim(p_job_number),
      job_name = btrim(p_job_name),
      customer_name = nullif(btrim(p_customer_name), ''),
      utility_name = nullif(btrim(p_utility_name), '')
  where id = p_job_id and company_id = public.my_company_id();
  if not found then
    raise exception using errcode = 'P0002', message = 'Job not found.';
  end if;
end;
$$;

create or replace function public.delete_job(p_job_id uuid)
returns void
language plpgsql
security definer
set search_path to ''
as $$
begin
  if auth.uid() is null then
    raise exception using errcode = '42501', message = 'Not authenticated.';
  end if;
  if lower(coalesce(public.my_role(), '')) not in ('owner', 'admin') then
    raise exception using errcode = '42501',
      message = 'Only the Company Owner or Admin can delete jobs.';
  end if;
  delete from public.jobs
  where id = p_job_id and company_id = public.my_company_id();
  if not found then
    raise exception using errcode = 'P0002', message = 'Job not found.';
  end if;
end;
$$;

revoke all on function public.update_job(uuid,text,text,text,text) from public, anon;
grant execute on function public.update_job(uuid,text,text,text,text) to authenticated;
revoke all on function public.delete_job(uuid) from public, anon;
grant execute on function public.delete_job(uuid) to authenticated;

commit;
