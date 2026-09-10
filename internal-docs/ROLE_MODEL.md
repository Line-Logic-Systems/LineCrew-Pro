# LineCrew Pro role model

## Hierarchy

1. **Owner** — single highest company role. Full company access, including role/access governance and explicit ownership transfer.
2. **Manager** — Owner-equivalent operational oversight. Can manage Manager/Admin and lower accounts, but cannot change, suspend, replace, demote, transfer or assign the Owner.
3. **Admin** — full operational administration. Can manage Superintendent/GF/Foreman/Safety roles and promote an active lower-role member to Admin, but cannot alter an existing Owner/Manager/Admin or assign Owner/Manager.
4. **Superintendent** — broad Admin-like operational access, with individual capabilities removable by an Owner/Manager/Admin.
5. **General Foreman** — field supervision/review role.
6. **Foreman** — field reporting/JSA role and default new-member role.
7. **Safety** — read-only company JSA workspace. Can search, review, print/download attachments and export JSA results, with no job, production, timekeeping, price, crew, company-setting or JSA mutation access.

## Owner governance

- An Owner, Manager or Admin can promote an active eligible lower-role member to Admin.
- An Owner can assign or remove Manager. A Manager can manage Manager/Admin and lower roles, but every Owner-row update is blocked at the database layer for Manager sessions.
- Only the Owner can demote or otherwise alter an existing Admin.
- An Admin cannot assign Owner or change an existing Owner/Admin.
- A company has at most one Owner. The generic role controls cannot create or remove Owner.
- Existing companies with no Owner allow one authenticated active Admin to claim the initial Owner role through the company-scoped bootstrap RPC.
- Once an Owner exists, ownership changes only through the explicit Owner-controlled transfer. The chosen active Admin becomes Owner and the prior Owner becomes Admin atomically.

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

The AI assistant is intentionally Owner/Admin-only and is not a configurable Superintendent capability.

Billing/subscription/platform-owner functions remain outside the Superintendent capability model.

## Security rules

- All roles remain scoped to their authenticated `company_id`.
- Owner access cannot be reduced through Superintendent overrides.
- Only Owner/Manager/Admin may change a Superintendent's overrides.
- Role changes go through the company-scoped role-management RPC rather than trusting hidden frontend controls.
- A user cannot use the permission system to grant themselves cross-company access.
- Frontend hiding is convenience only; sensitive mutations must also enforce the role/capability in Supabase policies or RPC functions.
