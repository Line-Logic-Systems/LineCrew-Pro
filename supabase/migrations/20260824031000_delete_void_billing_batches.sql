begin;

create or replace function public.delete_void_billing_export_batch(p_batch_id uuid)
returns void
language plpgsql
security definer
set search_path=''
as $$
declare
  v_company_id uuid;
  v_role text;
  v_active boolean;
begin
  select profile.company_id,lower(coalesce(profile.role,'')),profile.active
  into v_company_id,v_role,v_active
  from public.profiles profile
  where profile.id=auth.uid();

  if v_company_id is null or v_active is not true or v_role not in ('admin','owner') then
    raise exception using errcode='42501',
      message='Only an active Admin or Owner can delete a voided billing batch.';
  end if;

  delete from public.billing_export_batches batch
  where batch.id=p_batch_id
    and batch.company_id=v_company_id
    and batch.status='void';

  if not found then
    raise exception using errcode='P0002',
      message='Voided billing batch was not found in your company.';
  end if;
end;
$$;

revoke all on function public.delete_void_billing_export_batch(uuid) from public,anon;
grant execute on function public.delete_void_billing_export_batch(uuid) to authenticated;

commit;
