create or replace function public.audit_returned_daily_unit_change()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_status text;
  v_review_notes text;
  v_actor_name text;
  v_actor_role text;
  v_change text;
begin
  if new.install_quantity is not distinct from old.install_quantity
     and new.retirement_quantity is not distinct from old.retirement_quantity then
    return new;
  end if;

  select lower(coalesce(dr.status,'')), dr.review_notes
    into v_status, v_review_notes
  from public.daily_reports dr
  where dr.id = new.daily_report_id
    and dr.company_id = new.company_id;

  if v_status <> 'draft' or nullif(trim(coalesce(v_review_notes,'')), '') is null then
    return new;
  end if;

  select coalesce(p.full_name,'Foreman'), lower(coalesce(p.role,'foreman'))
    into v_actor_name, v_actor_role
  from public.profiles p
  where p.id = auth.uid();

  v_change := 'WP ' || coalesce(new.pole_location,'') ||
    ' / ' || coalesce((select dpu.item_code from public.daily_production_units dpu where dpu.id = new.daily_production_unit_id), 'Unit') ||
    ' changed — installed ' || coalesce(old.install_quantity,0) || ' → ' || coalesce(new.install_quantity,0) ||
    ', removed ' || coalesce(old.retirement_quantity,0) || ' → ' || coalesce(new.retirement_quantity,0);

  insert into public.daily_report_audit_events(
    company_id,daily_report_id,event_type,actor_id,actor_name,actor_role,event_notes,created_at
  ) values (
    new.company_id,new.daily_report_id,'foreman_correction',auth.uid(),
    coalesce(v_actor_name,'Foreman'),coalesce(v_actor_role,'foreman'),v_change,now()
  );

  return new;
end;
$$;

