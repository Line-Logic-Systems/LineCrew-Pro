# Beta / Pilot onboarding security notes

The Beta/Pilot application flow is intentionally separated from contractor data and normal paid checkout.

- Public website applications are accepted only through `submit-beta-application`. The underlying `beta_applications` table has RLS enabled and no anon/authenticated table grants.
- Public submissions are origin-checked, size-limited, validated, honeypot-protected, duplicate-suppressed, and fingerprint-rate-limited.
- Beta approval and decline are restricted to `platform_owners`. The review Edge Function validates the caller and the database RPCs independently re-check `is_platform_owner()`.
- Approval creates/reuses the company subscription as `pilot`, $0, manual provider, `trialing`, with a finite expiry.
- The initial Beta invitation is server-generated with `intended_role='admin'`. Clients cannot submit the role. Existing normal team invitations continue to default to Foreman.
- The invite token is cryptographically random and stored only as a hash-like token value in the invitation record; it expires after 48 hours and is one-use.
- Pilot status for the Admin onboarding checklist is read from server-controlled subscription state, never user metadata.
- Pilot conversion uses the existing `create-billing-checkout` Edge Function, which requires an active Owner/Admin and MFA AAL2 before creating Stripe Checkout.
- No Stripe card details are stored by LineCrew Pro, and conversion keeps the same company/data rather than recreating the tenant.

Production rollout should occur only after the Beta onboarding CI guardrails and existing regression suites are green, followed by Supabase security advisor review and a production smoke test with no real customer application data.
