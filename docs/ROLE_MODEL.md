# LineCrew Pro role model

## Hierarchy

1. **Owner** — highest company role. Full company access, including role/access governance and control of Admins.
2. **Admin** — full operational administration. Can manage Superintendent/GF/Foreman roles and Superintendent permissions, but cannot add, remove, demote or modify an Owner or another Admin.
3. **Superintendent** — broad Admin-like operational access, with individual capabilities removable by an Owner/Admin.
4. **General Foreman** — field supervision/review role.
5. **Foreman** — field reporting/JSA role and default new-member role.

## Owner governance

- An Owner can promote a member to Admin or remove/demote an Admin.
- Only an Owner can assign another Owner.
- An Admin cannot promote anyone to Owner or Admin.
- An Admin cannot demote or otherwise alter an Owner or another Admin.
- A company must always retain at least one Owner. The last Owner cannot be demoted until another Owner exists.
- Existing companies with no Owner may allow one authenticated current Admin to claim the initial Owner role exactly once through the company-scoped bootstrap RPC.

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
- Only Owner/Admin may change a Superintendent's overrides.
- Role changes go through the company-scoped role-management RPC rather than trusting hidden frontend controls.
- A user cannot use the permission system to grant themselves cross-company access.
- Frontend hiding is convenience only; sensitive mutations must also enforce the role/capability in Supabase policies or RPC functions.
