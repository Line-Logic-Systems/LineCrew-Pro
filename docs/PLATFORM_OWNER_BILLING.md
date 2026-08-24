# LineCrew Pro platform owner and billing rollout

This branch adds a protected LineCrew Pro owner console plus a Stripe-ready subscription foundation. It is intentionally staged so no contractor can be locked out by billing until the test project, Stripe test mode, and the final grace-period policy have all been verified.

Nothing in this design requires exposing a Supabase service-role key, Stripe secret key, webhook signing secret, or Stripe Price ID in browser code.

## 1. Database migration

Run `supabase/migrations/20260818_platform_owner_and_billing.sql` in Supabase before deploying `owner.html`, `billing.html`, or the billing Edge Functions.

The migration creates:
- `platform_owners`: explicit LineCrew Pro platform-owner allowlist keyed to Supabase Auth user ID.
- `company_subscriptions`: one account/subscription row per contractor company.
- `billing_events`: Stripe webhook event ledger with retry-safe idempotency state.
- `platform_owner_audit_events`: immutable support/audit trail for owner-side subscription setting changes.
- `is_platform_owner()`: safe owner-console authorization check.
- `platform_owner_company_dashboard()`: company-level health/usage counts and subscription state without exposing contractor production detail.
- `platform_owner_set_subscription(...)`: owner-only manual/pilot plan management plus a separate nullable access override.
- `my_company_subscription_access()`: contractor-side effective access status for a later reviewed main-app gate.
- `my_company_billing_summary()`: company Admin-only billing summary used by `billing.html`.

Direct browser access to the new platform/billing tables is revoked. Browser pages use protected RPCs instead. The migration also creates a `pilot` subscription record with access enabled for every company that already exists, so installing the billing foundation does not change current contractor access.

## 2. Grant the first platform owner

After the migration, identify the Supabase Auth user ID for the LineCrew Pro owner account. In the Supabase SQL Editor, insert it manually:

```sql
insert into public.platform_owners (user_id)
values ('YOUR-AUTH-USER-UUID');
```

Do not create a public self-service route for granting platform-owner access. A normal contractor Admin must never be able to promote themselves into this allowlist.

## 3. Platform Owner Console

`owner.html` is a separate protected console. A normal contractor Admin can sign in to LineCrew Pro but cannot pass `is_platform_owner()` unless their exact Auth user ID is present in `platform_owners`.

The owner console shows:
- contractor company and billing-contact email
- company creation date and last-report activity date
- active user count
- active job count
- total daily-report count
- plan code
- monthly contracted value
- subscription state
- effective app access
- whether access is automatic, force-enabled, or force-blocked
- trial and billing-period dates
- Stripe/manual provider state
- whether Stripe customer/subscription links exist
- owner-only support notes

The console intentionally shows counts and billing metadata rather than raw contractor job/report contents.

### Access override behavior

`company_subscriptions.access_enabled` is the provider/base access state. `access_override` is nullable:
- `null`: automatic provider/base decision
- `true`: force allow
- `false`: force block

Effective access is `coalesce(access_override, access_enabled)`. Stripe webhooks update only provider/base access and never overwrite the owner override. This prevents a later webhook from silently undoing a deliberate LineCrew Pro support decision.

For Stripe-managed accounts, Stripe remains the source of truth for price, subscription status, trial dates, and period dates. The owner console disables direct edits to those Stripe-managed fields but still allows internal plan-label changes, support notes, and an access override.

## 4. Contractor Company Billing page

`billing.html` is an Admin-only company billing page. It:
- reuses the existing Supabase session when the Admin is already signed into LineCrew Pro
- verifies the user is an active company Admin
- displays only that company's billing summary
- never displays a Supabase service-role key or Stripe Price ID
- starts Checkout through the `create-billing-checkout` Edge Function
- opens Stripe Customer Portal through the `create-billing-portal` Edge Function
- offers only higher plans through the `create-plan-upgrade` Edge Function
- sends card/payment self-service to Stripe instead of storing payment details in LineCrew Pro
- blocks activation of a crew beyond the paid plan limit in Postgres while retaining inactive crews and all historical records

The main `index.html` is not hard-gated by billing on this branch. Linking the Billing page into Admin Controls and enforcing `my_company_subscription_access()` should be a later reviewed release after test-mode billing passes.

## 5. Stripe Edge Function configuration

Deploy these Edge Functions only after the database migration exists in the target project:
- `create-billing-checkout`
- `create-billing-portal`
- `create-plan-upgrade`
- `stripe-webhook`

Set these Supabase Edge Function secrets/config values:

- `STRIPE_SECRET_KEY` — Stripe secret key. Use a Stripe test-mode key first.
- `STRIPE_WEBHOOK_SECRET` — signing secret for the deployed webhook endpoint.
- `APP_URL` — LineCrew Pro base URL with no trailing slash.
- `BILLING_PLAN_PRICE_MAP` — JSON object mapping LineCrew Pro plan codes to Stripe Price IDs.
- `STRIPE_UPGRADE_PORTAL_CONFIGURATION_ID` — optional explicit ID for the dedicated Stripe Customer Portal configuration used only by the upgrade-confirmation flow. If omitted, the server discovers exactly one active configuration labeled with metadata `linecrew_purpose=linecrew_upgrade_only_v1` and otherwise fails closed.

Example shape only:

```json
{"standard":"price_REPLACE_ME","pro":"price_REPLACE_ME"}
```

The real Price IDs belong in the Edge Function secret/config store, not in `billing.html`, `owner.html`, `index.html`, or the repository.

Supabase supplies `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY` to deployed Edge Functions. Never put the service-role key or Stripe secret key in GitHub Pages/browser configuration.

## 6. Checkout security model

A contractor Admin does not submit or choose a Stripe Price ID directly.

Checkout instead:
1. authenticates the user,
2. verifies active Admin role,
3. derives the company from the signed-in profile,
4. reads the plan already assigned to that company,
5. resolves that plan to a Stripe Price from server-side `BILLING_PLAN_PRICE_MAP`,
6. refuses plans that are not present in the map,
7. refuses to create another live Stripe subscription when one is already linked,
8. creates/reuses the Stripe customer, and
9. places company ID and plan code into server-generated Checkout/subscription metadata.

The plan map fails closed: no configured mapping means no Checkout.

### Upgrade-only Stripe Portal configuration

Keep plan switching **off** in the normal Customer Portal used by the **Manage Billing** button. Create a separate Stripe Customer Portal configuration for upgrade confirmations. Label it with metadata `linecrew_purpose=linecrew_upgrade_only_v1`. You may also put its `bpc_...` ID in `STRIPE_UPGRADE_PORTAL_CONFIGURATION_ID`; the explicit ID takes precedence.

The dedicated configuration must allow **price changes only**, use `always_invoice` proration, and include the Starter, Business, Pro, and Enterprise monthly products/prices. It is never opened as a general portal. `create-plan-upgrade` verifies the price-only and immediate-proration settings on every request; Stripe rejects a server-selected target that is not in the configuration. The endpoint uses the configuration only with Stripe's `subscription_update_confirm` deep-link flow, which displays the exact server-selected higher plan and its immediate prorated charge for confirmation.

The upgrade endpoint fails closed unless all of these checks pass:

1. the caller is an authenticated, active company Admin;
2. the company has one active or trialing Stripe subscription;
3. Stripe's customer on that subscription matches the customer stored for the company;
4. the subscription has exactly one item;
5. its current Stripe Price maps to a known LineCrew Pro plan;
6. the requested plan ranks strictly above the current plan;
7. the target Stripe Price comes from server-side `BILLING_PLAN_PRICE_MAP`; and
8. the subscription is not already scheduled to cancel.

The browser submits only a plan code such as `business`. It never submits or controls a Stripe Price ID. Stripe shows the prorated amount and handles payment authentication. Only the signed webhook changes the stored plan and active-crew limit after Stripe confirms the update.

## 7. Stripe webhook endpoint

Point Stripe to the deployed `stripe-webhook` Edge Function URL. The function validates `Stripe-Signature` with HMAC SHA-256 and a five-minute timestamp tolerance before processing the JSON body.

Subscribe to these events:
- `checkout.session.completed`
- `customer.subscription.created`
- `customer.subscription.updated`
- `customer.subscription.deleted`
- `invoice.paid`
- `invoice.payment_failed`

### Retry and ordering safety

The webhook stores each Stripe event ID in `billing_events`.

If Stripe retries an event:
- an already processed event returns success without processing twice;
- an event previously inserted but not successfully processed is retried rather than incorrectly treated as complete;
- processing errors are stored in `error_text` and return HTTP 500 so Stripe can retry.

`checkout.session.completed` links identifiers but does not blindly mark the company active. Subscription events remain the source of truth for actual subscription state.

For subscription events, the webhook resolves the LineCrew Pro plan from the subscription's current Stripe Price ID using `BILLING_PLAN_PRICE_MAP`. Customer Portal plan changes do not rewrite old subscription metadata, so metadata alone must never determine the new crew limit. An unmapped Stripe Price fails closed and is retried rather than silently assigning the wrong plan.

`invoice.payment_failed` marks the account `past_due` but preserves pilot/grace access. `invoice.paid` is audit-only and does not blindly reactivate a canceled or paused subscription. `customer.subscription.updated` remains the authoritative state update.

The webhook accepts both older top-level subscription period timestamps and the newer item-level period timestamps so the billing foundation is less sensitive to Stripe API-version changes.

## 8. Active crew enforcement

Standard plans are enforced in Postgres, not only in the browser:

- Starter: up to 5 active crews
- Business: up to 10 active crews
- Pro: up to 20 active crews
- Enterprise: up to 40 active crews

Inactive crews remain stored for job, report, employee, and audit history. When a company reaches its limit, activating another crew is rejected with an upgrade/deactivate message. A per-company transaction lock prevents two simultaneous crew inserts from taking the same final slot. Pilot and custom plans remain manually managed.

If a manually processed downgrade leaves a company above its new limit, LineCrew Pro preserves all data and existing access, reports the over-limit state, and blocks additional crew activation until the company deactivates crews or upgrades again. General Customer Portal plan switching remains off. Company Admins use the LineCrew Pro upgrade cards, which permit only a move to a higher plan; payment-method changes and cancellation remain available in the normal portal.

## 9. Current access policy

Current billing-foundation behavior:
- existing companies are seeded as `pilot`, `trialing`, access enabled
- manual/pilot account records can be configured by the platform owner
- `my_company_subscription_access()` returns effective access
- Stripe status updates are stored when the webhook is deployed
- `active`, `trialing`, `past_due`, and `incomplete` currently retain base access during pilot
- `paused` and `canceled` disable base access
- an owner override can always force allow or force block without being overwritten by Stripe

The production app does **not** yet enforce this billing value. That omission is deliberate.

Before hard-blocking contractor sign-in, choose a grace/dunning policy for past-due accounts. A practical first-launch policy is usually a grace period rather than immediate field lockout, because crews may need continued access to safety and production records while an office payment issue is resolved.

## 10. What is intentionally not automatic yet

The branch does not silently block the existing production app. Wiring `access_enabled=false` into `index.html` should be done as a separate reviewed release only after:

1. the migration passes in the disposable Supabase test project,
2. a test platform-owner account is granted,
3. a normal contractor Admin is proven unable to open `owner.html`,
4. manual plan/access changes are proven company-specific,
5. Stripe test-mode Checkout succeeds,
6. signed webhook state changes and retries are verified,
7. Customer Portal succeeds,
8. the two-company isolation test still passes, and
9. the past-due grace policy is approved.

This sequence prevents a billing configuration mistake from becoming a field-operations outage.

## 11. Recommended B2B plan setup

LineCrew Pro can support negotiated contractor pricing without exposing raw Stripe configuration to users.

A simple first commercial workflow is:
1. LineCrew Pro support assigns the contractor's `plan_code` in `owner.html`.
2. The matching plan code exists in server-side `BILLING_PLAN_PRICE_MAP`.
3. The contractor Admin opens `billing.html` and starts Stripe Checkout.
4. Stripe becomes the source of truth for the actual subscription amount/status.
5. The webhook updates the company subscription record.
6. LineCrew Pro retains a separate support-only access override.

For customer-specific negotiated prices, create the needed Stripe Price and map an internal plan code to it server-side. No Stripe secret or Price ID needs to appear in the browser.

## 12. Safe test order

1. Apply `20260818_platform_owner_and_billing.sql` to the disposable **LineCrew Pro Test** project only.
2. Add one test Auth user to `platform_owners`.
3. Use a Vercel preview deployment. `index.html`, `owner.html`, and `billing.html` automatically select the disposable LineCrew Pro Test project on `*.vercel.app` hosts, while `app.linecrewpro.com` continues to select production. Every preview page displays a sandbox banner.
4. Confirm an ordinary contractor Admin is denied from `owner.html`.
5. From the owner console, change a single test company's manual plan/status/access override and confirm no second company changes.
6. Confirm owner audit rows are created for owner-side subscription changes.
7. Deploy the four billing Edge Functions to the test Supabase project with Stripe **test-mode** keys.
8. Set a test `BILLING_PLAN_PRICE_MAP` using test Price IDs.
9. Assign that plan code to a test contractor.
10. Complete Checkout from an authenticated test company Admin session.
11. Verify `checkout.session.completed` links the Stripe customer/subscription without prematurely forcing active status.
12. Verify `customer.subscription.created/updated` supplies the authoritative status and billing period.
13. Send/retry a signed webhook event and confirm already processed events are not applied twice.
14. Force a webhook-processing failure in the disposable project, retry the same Stripe event, and confirm it can recover from an unprocessed ledger row.
15. Verify a normal Foreman cannot use `my_company_billing_summary()`.
16. Open Stripe Customer Portal from a company Admin session.
17. Keep plan switching and quantity changes disabled in the normal sandbox Customer Portal.
18. Create a dedicated sandbox Portal configuration labeled `linecrew_purpose=linecrew_upgrade_only_v1` that permits price changes only, uses `always_invoice` proration, and includes the Starter, Business, Pro, and Enterprise monthly products. Optionally save its ID as `STRIPE_UPGRADE_PORTAL_CONFIGURATION_ID`.
19. Use the billing page to upgrade the test subscription and confirm Stripe shows the exact higher plan and proration before confirmation.
20. Confirm the billing page updates its plan, price, and active-crew limit from the new Stripe Price ID after the webhook arrives.
21. Confirm Starter accepts active crews 1–5, rejects active crew 6, and still permits an inactive historical crew.
22. Re-run the two-company isolation test after the migration.
23. Only after all of the above should a production rollout and app-access gate be prepared.
