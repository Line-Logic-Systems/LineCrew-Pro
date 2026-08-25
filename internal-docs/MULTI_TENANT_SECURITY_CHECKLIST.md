# Multi-Tenant Security Checklist

LineCrew Pro must treat every contractor company as a separate security boundary.

## Required design rules

- Browser requests never choose an arbitrary company for privileged writes.
- Security-definer RPCs resolve `company_id` from the authenticated user's profile.
- Every business table includes `company_id`.
- Foreign-key relationships are checked inside the same company.
- Row Level Security remains enabled on all tenant tables.
- Storage buckets containing company data remain private.
- Storage paths begin with the authenticated member's company UUID.
- Signed URLs expire and are not stored as public links.
- Admin-only changes verify the caller's role in the database, not only in JavaScript.
- Foremen see the field-adjusted value rules already configured for their contract.
- Actual contract values remain limited to Admin and General Foreman roles.

## Cross-company test before commercial launch

Create Company A and Company B with separate Admin, GF and Foreman accounts.

For every module, create records in both companies and verify:

1. Company A members see only Company A records.
2. Company B members see only Company B records.
3. Copying a Company A record UUID into a Company B browser/RPC call is rejected.
4. Company B cannot open Company A signed attachment URLs after expiration.
5. Foremen cannot invoke Admin-only RPCs from the browser console.
6. Suspended members cannot perform protected work.
7. The last Admin cannot accidentally remove the company's only Admin.
8. Join codes can be rotated and old codes stop working.

## Launch blockers

Do not sell or onboard production customers until:

- the full cross-company test passes;
- automated backup and restore procedures are tested;
- error monitoring is installed;
- subscription entitlements remain enforced server-side through the production pre-request hook and guarded access RPCs;
- privacy policy, terms and data retention rules are approved;
- browser and mobile testing is complete;
- a disaster-recovery owner and support process are assigned.
