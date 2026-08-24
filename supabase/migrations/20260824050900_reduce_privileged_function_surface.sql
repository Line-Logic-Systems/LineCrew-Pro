begin;

-- Trigger and event-trigger functions are infrastructure, not public RPCs.
revoke all on function public.protect_daily_report_unit_history()
  from public, anon, authenticated;
revoke all on function public.rls_auto_enable()
  from public, anon, authenticated;

-- This resolver is an implementation detail of guarded job-packet RPCs.
-- Keeping it off the authenticated API prevents import IDs from being used
-- to probe price-book item identifiers across companies.
revoke all on function public.resolve_utility_packet_price_item(uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.resolve_utility_packet_price_item(uuid, text, text)
  to service_role;

-- The compatibility wrapper performs no privileged table work itself. Its
-- target function, linecrew_set_member_role, retains the company and role
-- checks and remains the only SECURITY DEFINER boundary.
alter function public.set_company_member_role(uuid, text) security invoker;
revoke all on function public.set_company_member_role(uuid, text)
  from public, anon;
grant execute on function public.set_company_member_role(uuid, text)
  to authenticated, service_role;

commit;
