# LineCrew Pro platform owner and billing rollout

This branch adds a protected Line Logic Systems owner console plus a Stripe-ready subscription foundation. Nothing in this document requires exposing Supabase service-role or Stripe secrets to the browser.

## 1. Database migration

Run `supabase/migrations/20260818_platform_owner_and_billing.sql` in Supabase before deploying `owner.html` or the billing Edge Functions.

The migration creates:
- `platform_owners`: explicit Line Logic platform-owner allowlist keyed to Supabase Auth user ID.
- `company_subscriptions`: one subscription/account record per contractor company.
- `billing_events`: idempotent Stripe webhook audit records.
- `is_platform_owner()`: safe browser check for owner-console access.
- `platform_owner_company_dashboard()`: company-level counts and subscription status only.
- `platform_owner_set_subscription(...)`: owner-only manual plan/status/access management.
- `my_company_subscription_access()`: contractor-side subscription/access status.

Direct browser access to all three new tables is revoked. The owner console uses the protected RPCs instead of direct table access.

## 2. Grant the first platform owner

After the migration, identify the Supabase Auth user ID for the Line Logic owner account. In the Supabase SQL Editor, insert it manually:

```sql
insert into public.platform_owners (user_id)
values ('YOUR-AUTH-USER-UUID');
```

Do not create a public self-service route for granting platform-owner access.

## 3. Platform Owner Console

`owner.html` is a separate protected console. A normal contractor Admin can sign in to LineCrew Pro but cannot pass `is_platform_owner()` unless their Auth user ID is explicitly present in `platform_owners`.

The console currently shows:
- contractor company name and ID
- active users
- active jobs
- total daily reports
- plan code
- monthly contracted price
- subscription state
- app access enabled/blocked
- trial and billing-period dates
- Stripe/manual provider status

The owner can configure manual/pilot subscriptions immediately, before Stripe is connected.

## 4. Stripe Edge Function secrets

Deploy these Edge Functions only after Stripe is ready:
- `create-billing-checkout`
- `create-billing-portal`
- `stripe-webhook`

Set the following Supabase Edge Function secrets:

- `STRIPE_SECRET_KEY` — Stripe secret key.
- `STRIPE_WEBHOOK_SECRET` — signing secret from the Stripe webhook endpoint.
- `APP_URL` — production LineCrew Pro URL with no trailing slash.
- `BILLING_ALLOWED_PRICE_IDS` — comma-separated Stripe Price IDs that contractor Admins are allowed to purchase.

Supabase provides `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY` to deployed Edge Functions. Never put the service-role or Stripe secret key in `index.html`, `owner.html`, or GitHub Pages configuration.

## 5. Stripe webhook endpoint

Point Stripe to the deployed `stripe-webhook` Edge Function URL. The function verifies the `Stripe-Signature` header with HMAC SHA-256 and a five-minute timestamp tolerance before parsing the event.

Recommended events:
- `checkout.session.completed`
- `customer.subscription.created`
- `customer.subscription.updated`
- `customer.subscription.deleted`
- `invoice.paid`
- `invoice.payment_failed`

Webhook events are recorded by Stripe event ID so retries do not process the same event twice.

## 6. Access policy

Current foundation behavior:
- Manual/pilot account records can be configured from `owner.html`.
- `my_company_subscription_access()` returns a safe contractor-side status.
- Stripe status updates are stored automatically once the webhook is deployed.
- `active`, `trialing`, and `past_due` currently retain access in the webhook foundation; `paused`, `canceled`, and `incomplete` disable it.

Before hard-blocking contractor sign-in, decide the desired grace-period policy for `past_due`. Recommended first-launch behavior is a 7–14 day dunning/grace period instead of immediate field lockout.

## 7. What is intentionally not automatic yet

The foundation does **not** silently block the existing production app before the migration and billing policy have been pilot-tested. Wiring `access_enabled=false` into the main app should be done as a separate reviewed release after:

1. the migration is live,
2. the first platform owner is granted,
3. the owner console is tested,
4. Stripe test-mode checkout and webhook events pass,
5. the desired past-due grace policy is approved.

This avoids accidentally locking an active contractor out of safety or production records because of a billing-configuration mistake.

## 8. Recommended plan setup

LineCrew Pro can support any plan codes and monthly prices. Keep Stripe Product/Price IDs in Stripe and `BILLING_ALLOWED_PRICE_IDS`; do not hard-code secret billing configuration into the browser.

A simple first commercial setup could use one or more monthly Stripe Price IDs and keep company-specific negotiated pricing as separate Stripe Prices. The owner console stores the actual contracted monthly amount returned by Stripe once billing is active.

## 9. Safe test order

1. Apply the migration to the disposable `LineCrew Pro Test` project.
2. Add a test Auth user to `platform_owners`.
3. Open `owner.html` against the test project and confirm a normal company Admin is denied.
4. Create a manual pilot subscription and confirm only the selected company changes.
5. Deploy the three Edge Functions to the test project with Stripe **test-mode** keys.
6. Complete a test Checkout Session.
7. Verify `company_subscriptions` updates and `billing_events` contains the signed webhook event.
8. Open the Stripe customer portal from an authenticated company Admin session.
9. Run the two-company tenant isolation test again after the migration.
10. Only then plan a production deployment.
