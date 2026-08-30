# Beta onboarding rollout checklist

1. Run `node scripts/validate-beta-onboarding.mjs`.
2. Run `node scripts/validate-marketing-site.mjs`.
3. Run `node scripts/validate-end-to-end-regressions.mjs`.
4. Verify sandbox approval transaction creates one company, one Pilot subscription, and one Admin invitation.
5. Confirm `beta_applications` remains inaccessible to anon/authenticated table roles.
6. Confirm `review-beta-application` requires JWT and platform-owner allowlist membership.
7. Run Supabase security/performance advisors after the migration.
8. Merge only after CI is green.
9. Apply the production migration and deploy both Beta Edge Functions.
10. Smoke-test public application submission and owner-console visibility with a controlled test application; remove the controlled test record afterward.
