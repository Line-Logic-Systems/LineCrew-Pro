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
    company_id,actor_id,event_type,details
  ) values (
    v_company_id,auth.uid(),'pilot_feedback_resolved',
    jsonb_build_object('feedback_id',p_feedback_id)
  );
end;
$$;

revoke all on function public.support_resolve_pilot_feedback(uuid) from public, anon;
grant execute on function public.support_resolve_pilot_feedback(uuid) to authenticated;
