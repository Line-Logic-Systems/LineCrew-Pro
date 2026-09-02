# Production migration baseline

## Current state

The repository migration history drifted from production because some SQL files
were applied manually in the Supabase SQL Editor. A file applied that way changes
the schema but does not add a row to `supabase_migrations.schema_migrations`.

Measured on 2026-09-02:

| Item | Count |
|---|---:|
| Historical repository migrations preserved in `supabase/migrations/archive/` | 166 |
| Active repository baseline migrations in `supabase/migrations/` | 1 |
| Migrations currently recorded in production | 132 |
| Production tables / functions / policies / triggers / indexes / enums | 92 / 259 / 128 / 34 / 398 / 10 |
| Test tables / functions / policies / triggers / indexes / enums before reconciliation | 77 / 172 / 88 / 18 / 250 / 10 |

The active baseline is
`supabase/migrations/20260902194315_baseline.sql`. It is a schema-only dump
of production project `ldgkyxuozbozgkvwzadg`. It includes the manually applied
packet-unit-alias indexes and contains no table data, `COPY`, data `INSERT`,
or `supabase_migrations` history.

The 166 former migration files remain in `archive/` for audit history. They
are not part of future `supabase db reset` or `supabase db push` runs.

## Verification already completed

- Independent Disaster Backup run 11 succeeded on 2026-08-30, including the
  logical database dump, repository archive, integrity check, and Azure copy.
- The baseline was generated with PostgreSQL 17 tooling.
- A clean local Supabase instance was started and rebuilt from only the active
  baseline with Supabase CLI 2.116.0.
- `supabase db reset` completed successfully.
- All repository regression validators passed after references to archived
  migrations were updated.
- The transition branch does not execute SQL against Production or Test.

## Remaining production history reconciliation

Do not execute the baseline against the existing production database: its
objects already exist. Reconcile only the migration metadata, in a separately
approved maintenance action.

1. Reconfirm a successful off-platform backup and Azure copy.
2. Export all current rows from
   `supabase_migrations.schema_migrations` and commit the export to the
   controlled recovery record. Do not include database credentials.
3. Capture read-only pre-change counts for schemas, tables, functions, policies,
   triggers, indexes, enums, and the current migration rows.
4. In one transaction, preserve the old rows in a timestamped archival table,
   replace the active migration-history rows with version `20260902194315`,
   and verify the inserted baseline row before commit.
5. Confirm every schema-object count is unchanged after commit. Roll back if any
   schema object differs.
6. Run the production verification SQL and Supabase security/performance
   advisors.

This operation changes migration metadata only. It must not create, alter, or
drop application objects or customer data.

## Test reconciliation

The current Test project does not match production. Applying the baseline on top
of its existing objects will conflict. Reconcile Test only through an explicitly
approved reset or a newly created empty Test project:

1. Export any Test data that must be retained.
2. Reset an empty Test database from the active baseline.
3. Compare the object inventory with production.
4. Run `test-two-company-isolation` and the full application verification
   suite against Test.
5. Update Test environment references only after those checks pass.

A Test reset is destructive to Test data and requires confirmation at action
time. It is not part of merging this repository baseline.

## Going forward

Create every schema change as a new timestamped file in
`supabase/migrations/` and apply it through the migration runner. Do not apply
migration files manually in the SQL Editor. If an emergency manual change is
unavoidable, repair the migration history immediately and document the event.
