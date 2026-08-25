begin;

-- 202608190400_revoke_anon_security_definer.sql intentionally grants every
-- public SECURITY DEFINER function to authenticated before revoking PUBLIC and
-- anon. These billing-maintenance RPCs accept an arbitrary company UUID and
-- are service jobs, not browser APIs, so lock them back down after that sweep.
revoke all on function public.capture_company_crew_usage(uuid,date)
  from public, anon, authenticated;
revoke all on function public.capture_all_company_crew_usage(date)
  from public, anon, authenticated;
revoke all on function public.recalculate_company_crew_overage(uuid)
  from public, anon, authenticated;

grant execute on function public.capture_company_crew_usage(uuid,date) to service_role;
grant execute on function public.capture_all_company_crew_usage(date) to service_role;
grant execute on function public.recalculate_company_crew_overage(uuid) to service_role;

-- Stripe doesn't guarantee webhook delivery order. Persist the most recent
-- subscription-event creation time so an older retry cannot roll a company
-- back to an earlier plan, price, or crew limit.
alter table public.company_subscriptions
  add column if not exists last_stripe_event_created bigint not null default 0;

commit;
