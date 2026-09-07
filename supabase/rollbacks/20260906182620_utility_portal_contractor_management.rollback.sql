-- Reverse order: 182620, 134013, 071452, 070834, 064624, 064002, 060001, 055947, 055940.

drop function if exists public.utility_unassigned_job_count();
drop function if exists public.utility_job_contract_warning(uuid[]);
drop function if exists public.utility_activity_feed(timestamptz, bigint, integer);
drop function if exists public.utility_contract_visibility_state(uuid, uuid);
drop function if exists public.utility_list_representatives(uuid);
drop function if exists public.utility_list_organizations(boolean);
drop function if exists public.utility_restore_representative(uuid);
drop function if exists public.utility_revoke_representative(uuid);
drop function if exists public.utility_cancel_invitation(uuid);
drop function if exists public.utility_upsert_invitation(uuid, text, text, text, timestamptz);
drop function if exists public.utility_set_grant_show_quantities(uuid, boolean);
drop function if exists public.utility_revoke_contract_grant(uuid);
drop function if exists public.utility_add_contract_grants(uuid, uuid[], boolean[]);
drop function if exists public.utility_create_organization_with_grants(text, uuid[], boolean[]);
drop function if exists public.utility_require_portal_enabled(uuid);
drop function if exists public.utility_require_contractor_manager();
