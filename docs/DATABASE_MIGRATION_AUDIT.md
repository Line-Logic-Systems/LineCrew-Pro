# Database Migration Audit

Audit date: 2026-08-18
Target branch: `chatgpt-dev`
Production schema baseline: `supabase/baseline/00000000000000_public_schema.sql`

## Outcome

The production `public` schema is now captured and verified without customer row data. The existing migrations must **not** be replayed against production or renamed in place. They document changes that are already represented in the verified baseline, but they are not yet a safe, deterministic rebuild chain.

No live database changes were made during this audit.

## Inventory

- Verified baseline: 7,434 lines
- Historical migrations: 28 files / 5,814 lines
- Migration version prefixes: 3
- Tables in the production `public` baseline: 27
- Historical migration groups:
  - `20260815`: 7 files
  - `20260816`: 11 files
  - `20260817`: 10 files

## Findings

### Critical: migration versions are not unique

All 28 historical migration filenames share only three version prefixes. Supabase records the numeric prefix as the migration version. Multiple files with the same version make clean provisioning and migration-history reconciliation unsafe.

**Safe resolution:** keep these files unchanged as historical records. Establish the verified baseline as the starting point for future environments, then require every new migration to use a unique 14-digit UTC timestamp such as `20260818153000_description.sql`.

Do not rename the historical files until production migration history has been exported and reconciled separately.

### High: historical files contain destructive or data-rewriting operations

The historical chain includes function/constraint drops, deletes, normalization deletes, and backfill updates. Several are legitimate application operations inside protected RPC functions, while others are one-time migration rewrites. They cannot be blindly replayed.

Particularly sensitive files include:

- `20260816_normalize_job_package_work_points.sql`
- `20260816_daily_report_cleanup.sql`
- `20260815_foreman_default_team_roles.sql`
- `20260816_daily_unit_authorization_status.sql`

**Safe resolution:** treat the verified baseline—not historical replay—as the bootstrap schema. Review each future migration for rollback, tenant scoping, and data preservation before it is applied.

### High: overlapping legacy table families remain in production

The baseline contains multiple generations of similarly purposed tables:

- Production units: `daily_production_items`, `daily_production_units`, `daily_report_units`, `report_units`
- Pricing: `price_book_items`, `unit_prices`
- Branding/settings: fields on `companies` plus `company_settings`

This is not proof that any table can be deleted. Existing application code, functions, or historical rows may still depend on each table.

**Safe resolution:** add read-only usage and row-count diagnostics first. Choose one canonical model per feature, migrate references and data with verification, and only remove a legacy table in a later reviewed migration.

### Medium: some historical DDL is only partially idempotent

Several policies, triggers, and functions are created without a universal `IF NOT EXISTS`, `OR REPLACE`, or paired drop. Re-running an individual file may fail even when its intended schema already exists.

**Safe resolution:** future migrations should be forward-only and safely guarded where appropriate. Never use “rerun the whole file” as a production recovery method.

### Confirmed: multi-tenant structures are present

The baseline includes `company_id` across the main commercial records and includes row-level security policies and protected functions. This is a strong foundation, but structural presence does not replace behavioral tenant-isolation testing.

**Next security verification:** run two-company tests for reads, writes, RPC calls, storage attachments, job packets, price books, daily reports, JSA records, storm assignments, and exports.

## Rules for all new database work

1. Use a unique 14-digit UTC timestamp for every migration.
2. Develop and review migrations on `chatgpt-dev`; never experiment on `main` or production.
3. Include explicit `company_id` scoping for tenant-owned records.
4. Enable and test RLS before granting authenticated access.
5. For `SECURITY DEFINER` functions, set a fixed `search_path`, verify the caller, resolve the caller's company server-side, and revoke execution from `public` and `anon`.
6. Avoid destructive DDL. When unavoidable, split data migration, verification, and deletion into separate releases.
7. Never place customer rows, passwords, service-role keys, database URLs, or API secrets in GitHub.
8. Capture a fresh schema-only baseline after reviewed production schema releases.

## Recommended next step

Build an automated two-company security test harness against a disposable Supabase environment. It should prove that Company A cannot read or mutate Company B data through tables, RPC functions, storage paths, filters, exports, or guessed UUIDs.

Real-world use: a contractor using LineCrew Pro can never see another contractor's contracts, pricing, jobs, daily production, safety records, crews, attachments, or storm data—even if someone manipulates the browser or knows another record ID.
