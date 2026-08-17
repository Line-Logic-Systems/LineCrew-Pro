# LineCrew-Pro
Commercial multi-company powerline management platform

## Supabase migrations

Database changes are stored in `supabase/migrations` and must be applied to
Supabase before merging the matching frontend pull request into `main`.

`20260815_secure_price_book_activation.sql` makes Price Book activation an
admin-only, company-scoped transaction and prevents multiple active versions
of the same company/contract/Price Book family.

Deployment refresh: 2026-08-17.
Deployment retry after GitHub Pages recovery: 2026-08-17.
