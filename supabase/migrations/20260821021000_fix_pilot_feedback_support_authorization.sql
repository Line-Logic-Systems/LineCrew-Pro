create or replace function public.support_list_pilot_feedback(p_limit integer default 100)
returns table(
  id uuid,company_id uuid,company_name text,submitted_by uuid,submitted_name text,
  category text,rating smallint,message text,page text,contact_ok boolean,
  created_at timestamptz,resolved_at timestamptz
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not public.is_platform_support() then
    raise exception using errcode='42501', message='Platform support access required.';
  end if;
  return query
  select f.id,f.company_id,c.name,f.submitted_by,p.full_name,
    f.category,f.rating,f.message,f.page,f.contact_ok,f.created_at,f.resolved_at
  from public.pilot_feedback f
  join public.companies c on c.id=f.company_id
  join public.profiles p on p.id=f.submitted_by and p.company_id=f.company_id
  order by f.created_at desc
  limit least(greatest(coalesce(p_limit,100),1),250);
end;
$$;

create or replace function public.support_resolve_pilot_feedback(p_feedback_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_company_id uuid;
begin
  if not public.is_platform_support() then
    raise exception using errcode='42501', message='Platform support access required.';
  end if;
  update public.pilot_feedback
  set resolved_at=coalesce(resolved_at,now()),resolved_by=coalesce(resolved_by,auth.uid())
  where id=p_feedback_id
  returning company_id into v_company_id;
  if v_company_id is null then
    raise exception using errcode='P0002', message='Feedback was not found.';
  end if;
  insert into public.support_audit_events(
    company_id,support_user_id,actor_user_id,event_type,metadata
  ) values (
    v_company_id,auth.uid(),auth.uid(),'pilot_feedback_resolved',
    jsonb_build_object('feedback_id',p_feedback_id)
  );
end;
$$;

revoke all on function public.support_list_pilot_feedback(integer) from public, anon;
revoke all on function public.support_resolve_pilot_feedback(uuid) from public, anon;
grant execute on function public.support_list_pilot_feedback(integer) to authenticated;
grant execute on function public.support_resolve_pilot_feedback(uuid) to authenticated;
