-- Supabase applies default API-role grants when a function is created, so
-- recreating my_company_billing_summary in 20260905161500 handed EXECUTE back
-- to anon. That is the same drift 20260905014500 exists to correct for
-- platform_owner_set_subscription and linecrew_monthly_cents, and a plain
-- "revoke all from public" does not undo an explicit role grant.
--
-- The function already defends itself: an anonymous caller has no auth.uid(),
-- so it raises 42501 before reading any row. This closes the gap anyway,
-- because a company billing RPC should not be reachable by an unauthenticated
-- client at all.

revoke execute on function public.my_company_billing_summary() from anon;
