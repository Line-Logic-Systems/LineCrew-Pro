# Approved Beta company flow

1. Applicant receives the Supabase Auth invitation after Platform Owner approval.
2. Invitation signup creates the first company profile as Admin using the server-controlled invitation role.
3. Admin completes MFA as required by LineCrew Pro.
4. Pilot Admin dashboard shows the Beta Company Setup checklist.
5. Checklist reflects company-scoped setup state: company branding, leadership/users, crews, equipment, customers/contracts, price book and first job.
6. Pilot Admin can choose Convert to Paid Plan. The conversion route presents Starter, Business, Pro and Enterprise choices.
7. Selected plan opens the existing secure Stripe Checkout after Owner/Admin and MFA AAL2 verification.
8. Stripe activation updates the existing company subscription; the tenant and its operational data remain unchanged.
