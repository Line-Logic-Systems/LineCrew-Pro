# LineCrew Pro
Commercial multi-company powerline management platform.

## Production architecture

- Marketing website: `https://linecrewpro.com` via GitHub Pages from `main:/docs`.
- Operational app: `https://app.linecrewpro.com` via Vercel from the repository root on `main`.
- Authentication, database and storage: Supabase.
- Company data is multi-tenant and must remain scoped by authenticated `company_id` in database policies/RPCs and server-side functions.
- The in-app LineCrew Assistant is Admin-only and its server function must independently verify the authenticated profile role.

## Release rules

1. Never place service-role, OpenAI, Stripe secret, database password or other server-only credentials in `index.html`, `/docs`, `vercel.json`, or other public static files.
2. Run `node scripts/validate-app.mjs` and `node scripts/validate-production-readiness.mjs` before production changes.
3. Database changes belong in `supabase/migrations` and must be applied to the intended Supabase project before merging frontend code that depends on them.
4. Edge Function changes must be deployed to Supabase separately; a Vercel deployment does not deploy Supabase functions.
5. Production application changes merge to `main`, which triggers the Vercel production deployment.
6. Marketing-site changes in `/docs` also live on `main`; GitHub Pages serves only `/docs`.
7. Keep `linecrewpro.com` and `app.linecrewpro.com` HTTPS-only.

## Security baseline

The Vercel app uses `vercel.json` to add anti-clickjacking, MIME-sniffing, referrer, indexing and HSTS response headers. The production-readiness CI gate also checks that the public app shell does not expose known server-side secret patterns and that the Admin-only AI function still enforces authentication, Admin role and company scoping.

## Supabase migrations

Database changes are stored in `supabase/migrations` and must be applied to Supabase before merging the matching frontend pull request into `main`.

`20260815_secure_price_book_activation.sql` makes Price Book activation an admin-only, company-scoped transaction and prevents multiple active versions of the same company/contract/Price Book family.
