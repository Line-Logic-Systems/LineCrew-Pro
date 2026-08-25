# Test Platform Owner Access

This procedure is for the disposable **LineCrew Pro Test** Supabase project only. It must never target production.

## Prerequisites

- `20260818010000_platform_owner_and_billing.sql` has been applied to the test project.
- `20260818020000_crew_tier_usage_policy.sql` has been applied.
- `20260818030000_crew_tier_automation_and_visibility.sql` has been applied.
- `20260824223848_enforce_active_crew_plan_limit.sql` has been applied.
- `20260825000000_lock_crew_usage_rpc_execution.sql` has been applied last.
- The GitHub `isolation-test` environment contains the disposable-project Supabase secrets already used by `Test platform billing isolation`.
- The Auth user you want to use already exists in the LineCrew Pro Test Supabase project.

## Grant test platform-owner access

1. Open GitHub Actions.
2. Choose **Manage test platform owner**.
3. Click **Run workflow**.
4. Select branch `feature/platform-owner-billing`.
5. Enter the existing test Auth user's email.
6. Choose action `grant`.
7. Type `DISPOSABLE_ONLY` exactly.
8. Run the workflow.
9. Confirm the run completes green.

The workflow resolves the user by email using the test project's service role inside GitHub Actions, then upserts only that Auth user ID into `public.platform_owners`. It verifies the row exists before reporting success.

## Revoke test platform-owner access

Run the same workflow with action `revoke`. The job deletes only that user's `platform_owners` row and verifies it is gone.

## Safety controls

The script refuses to run unless:

- `LINECREW_ISOLATION_TEST_CONFIRM` equals `DISPOSABLE_ONLY`;
- `SUPABASE_TEST_URL` matches `SUPABASE_TEST_PROJECT_REF`;
- `SUPABASE_TEST_PROJECT_REF` does **not** equal `SUPABASE_PRODUCTION_PROJECT_REF`;
- the requested action is exactly `grant` or `revoke`;
- the target email resolves to an existing Auth user in the configured test project.

The service-role key is never printed, stored in browser code, or committed to the repository.

## Owner console smoke test

After a successful grant:

1. Open the test deployment of `owner.html`.
2. Sign in with the allowlisted test Auth account.
3. Confirm the Platform Owner Console loads.
4. Confirm the company list shows billing/usage summaries rather than raw contractor production details.
5. Open one test company and change a manual plan, internal support note, or access override.
6. Confirm a second company is unchanged.
7. Confirm the owner audit event is created.
8. Sign out.
9. Revoke the test platform-owner allowlist row when testing is complete if that account should not retain owner access.

A normal contractor Admin that is not explicitly allowlisted must continue to fail the `is_platform_owner()` check.
