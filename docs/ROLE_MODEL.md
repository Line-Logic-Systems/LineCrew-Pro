# LineCrew Pro role model

## Hierarchy

1. **Owner** — highest company role. Full company access, including role/access governance.
2. **Admin** — full operational administration. Can manage Superintendent permissions.
3. **Superintendent** — broad Admin-like operational access, with individual capabilities removable by an Owner/Admin.
4. **General Foreman** — field supervision/review role.
5. **Foreman** — field reporting/JSA role and default new-member role.

## Superintendent capability model

Superintendents default to broad access. `profiles.role_permissions` stores per-user overrides. A missing capability key means allowed; an explicit `false` means denied. This makes it possible to begin with Admin-like access and restrict only the areas a company does not want a particular Superintendent to use.

Initial capability names for frontend enforcement:

- `company_settings`
- `team_management`
- `role_management`
- `customers_contracts`
- `price_books`
- `jobs`
- `job_packages`
- `production_review`
- `reporting`
- `storm_mode`
- `safety_records`
- `actual_pricing`
- `exports`
- `ai_assistant`

Billing/subscription/platform-owner functions remain outside the Superintendent capability model.

## Security rules

- All roles remain scoped to their authenticated `company_id`.
- Owner access cannot be reduced through Superintendent overrides.
- Only Owner/Admin may change a Superintendent's overrides.
- A user cannot use this mechanism to grant themselves a role or cross-company access.
- Frontend hiding is convenience only; sensitive mutations must also enforce the role/capability in Supabase policies or RPC functions.
