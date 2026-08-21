# LineCrew Pro
Commercial multi-company powerline management platform.

## Production architecture

- Marketing website: `https://linecrewpro.com` via GitHub Pages from `main:/docs`.
- Operational app: `https://app.linecrewpro.com` via Vercel from the repository root on `main`.
- Authentication, database and storage: Supabase.
- Production Supabase project reference: `ldgkyxuozbozgkvwzadg`.
- Company data is multi-tenant and must remain scoped by authenticated `company_id` in database policies/RPCs and server-side functions.
- The in-app LineCrew Assistant is Admin-only. Its server function independently verifies authenticated role, active status and company scope. Conversation history stays in the signed-in browser session and is cleared at sign-out.
- Independent disaster backups are packaged by GitHub Actions and copied to the private Azure Blob container `linecrew-pro-backups` in storage account `linecrewprobackup`.

## Release rules

1. Never place service-role, OpenAI, Stripe secret, database password or other server-only credentials in `index.html`, `/docs`, `vercel.json`, or other public static files.
2. Run `node scripts/validate-app.mjs` and `node scripts/validate-production-readiness.mjs` before production changes.
3. Database changes belong in `supabase/migrations` and must be applied to the intended Supabase project before merging frontend code that depends on them.
4. Edge Function changes must be deployed to Supabase separately; a Vercel deployment does not deploy Supabase functions.
5. Production application changes merge to `main`, which triggers the Vercel production deployment.
6. Marketing-site changes in `/docs` also live on `main`; GitHub Pages serves only `/docs`.
7. Keep `linecrewpro.com` and `app.linecrewpro.com` HTTPS-only.
8. Before destructive production changes, verify a recent successful `Independent Disaster Backup` and confirm its Azure copy exists.

## Security baseline

The Vercel app uses `vercel.json` to add anti-clickjacking, MIME-sniffing, referrer, indexing and HSTS response headers. The production-readiness CI gate checks that the public app shell does not expose known server-side secret patterns and that the company assistant enforces authentication, role/capability authorization and company scoping.

Role hierarchy is Owner > Admin > Superintendent > General Foreman > Foreman. Owner protects company governance and Admin management. Admin has broad operational administration. Superintendent permissions are configurable. General Foreman and Foreman remain field/production roles with narrower access.

## Supabase migrations

Database changes are stored in `supabase/migrations` and must be applied to Supabase before merging the matching frontend pull request into `main`.

Key current role/security migrations include:
- `20260818_owner_superintendent_roles.sql`
- `20260818_owner_superintendent_team_access.sql`
- `202608190100_owner_legacy_compatibility.sql`
- `202608190200_superintendent_legacy_compatibility.sql`
- `202608190300_capability_whitelist.sql`
- `202608190400_revoke_anon_security_definer.sql`

## Disaster recovery

- Workflow: `.github/workflows/independent-backup.yml`
- Backup script: `scripts/backup-supabase.mjs`
- Recovery runbook: `docs/DISASTER_RECOVERY.md`
- Azure storage account: `linecrewprobackup`
- Azure container: `linecrew-pro-backups`

The backup contains the Git repository bundle/history, exported application tables, Supabase Storage objects and a manifest. The workflow also retains a GitHub artifact and copies the packaged backup to Azure.
