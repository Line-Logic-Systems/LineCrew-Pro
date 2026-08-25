begin;

-- Subscription descriptions promise a maximum number of active crews. Keep
-- inactive crews for history, but enforce the active limit in Postgres so a
-- browser change, direct REST call, or stale frontend cannot bypass billing.
create or replace function public.enforce_active_crew_plan_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_plan text;
  v_limit integer;
  v_active_crews integer;
begin
  if coalesce(new.active, true) = false then
    return new;
  end if;

  -- Updates that leave the same active crew in the same company do not add
  -- capacity and must remain editable.
  if tg_op = 'UPDATE'
     and coalesce(old.active, true) = true
     and old.company_id = new.company_id then
    return new;
  end if;

  -- Serialize capacity-changing writes per company so concurrent inserts
  -- cannot both observe the same final slot.
  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(new.company_id::text, 487921)
  );

  select lower(coalesce(cs.plan_code, 'pilot'))
  into v_plan
  from public.company_subscriptions cs
  where cs.company_id = new.company_id;

  -- Pilot/custom companies are manually managed. Paid standard tiers have a
  -- fixed active-crew limit derived server-side from the plan code.
  if v_plan is null or v_plan in ('pilot', 'custom') then
    return new;
  end if;

  v_limit := public.plan_crew_limit(v_plan);
  if v_limit is null then
    raise exception 'This company does not have a valid crew plan. Contact LineCrew Pro support.';
  end if;

  select count(*)::integer
  into v_active_crews
  from public.crews c
  where c.company_id = new.company_id
    and coalesce(c.active, true) = true
    and c.id is distinct from new.id;

  if v_active_crews >= v_limit then
    raise exception '% includes up to % active crews. Deactivate an existing crew or upgrade the company plan before activating another crew.',
      initcap(v_plan), v_limit;
  end if;

  return new;
end;
$$;

revoke all on function public.enforce_active_crew_plan_limit() from public, anon, authenticated;

drop trigger if exists linecrew_enforce_active_crew_plan_limit on public.crews;
create trigger linecrew_enforce_active_crew_plan_limit
before insert or update of active, company_id on public.crews
for each row execute function public.enforce_active_crew_plan_limit();

comment on function public.enforce_active_crew_plan_limit() is
'Keeps historical inactive crews but blocks a standard paid plan from exceeding its server-side active crew limit.';

commit;
