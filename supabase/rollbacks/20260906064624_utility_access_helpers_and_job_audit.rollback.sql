-- Reverse order: 182620, 134013, 071452, 070834, 064624, 064002, 060001, 055947, 055940.
drop trigger if exists utility_job_contract_visibility_audit on public.jobs;
drop trigger if exists utility_identity_blocks_profile_id_update on public.profiles;
drop function if exists public.utility_log_job_contract_visibility();
drop function if exists public.utility_has_job_access(uuid);
drop function if exists public.utility_has_contract_access(uuid);
drop function if exists public.utility_grant_hidden_reasons(uuid, uuid);
drop function if exists public.utility_visibility_hidden_reasons(boolean, date, date, text, timestamptz, boolean, boolean, boolean, timestamptz, date);
drop function if exists public.utility_current_org_id();
drop function if exists public.utility_current_user_id();
-- Do not restore anon table privileges. The forward migration intentionally
-- tightened this feature's grant-level boundary, and rollback must not weaken it.
