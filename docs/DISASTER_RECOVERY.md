# LineCrew Pro Disaster Recovery

## Recovery objective

No single provider is the only copy of company data. A backup is not considered usable until its inventory and hashes pass verification, and recovery is exercised against a disposable project.

## Protection layers

### Daily company-data backup

`.github/workflows/daily-company-data-backup.yml` runs every day and can be started manually. It contains:

1. JSON exports of all 48 production application tables.
2. Every company upload in Supabase Storage.
3. A manifest with row counts, byte counts, and SHA-256 hashes for every table and object.

The large `training-videos` bucket is excluded from the daily package and included in the weekly backup. The package is retained in GitHub for 30 days and copied to the independent Azure backup container.

### Weekly full disaster backup

`.github/workflows/independent-backup.yml` runs on Sunday and contains:

1. The complete daily data set plus every Storage bucket, including training videos.
2. A PostgreSQL custom-format logical dump of the `auth`, `public`, and `storage` schemas.
3. A Git bundle containing the complete repository history and branches.
4. The integrity manifest and `pg_restore` archive inventory.

The package is retained in GitHub for 30 days and copied to Azure Blob Storage. Either destination can survive loss of Supabase; Azure also protects against loss of GitHub.

### Monthly disposable restore test

`.github/workflows/test-disaster-restore.yml` runs only in the protected `isolation-test` GitHub environment. It refuses to run if the target project reference equals production. The drill:

1. Creates synthetic users, two companies, a customer, and a private PDF.
2. Snapshots the first company's records and file hash.
3. Deletes that synthetic company and file.
4. Restores the records in dependency order and restores the file at its original path.
5. Signs users in, checks the restored content and SHA-256 hash, and confirms the second company cannot read either item.
6. Removes all drill data.

Production records and production files are never modified by this test.

## Required GitHub configuration

Repository secrets:

- `BACKUP_SUPABASE_URL`
- `BACKUP_SUPABASE_SERVICE_ROLE_KEY`
- `SUPABASE_DB_URL`
- `AZURE_BACKUP_CONNECTION_STRING`

`isolation-test` environment secrets:

- `SUPABASE_TEST_URL`
- `SUPABASE_TEST_ANON_KEY`
- `SUPABASE_TEST_SERVICE_ROLE_KEY`
- `SUPABASE_TEST_PROJECT_REF`
- `SUPABASE_PRODUCTION_PROJECT_REF`

Never commit credentials or database URLs.

## Integrity behavior

`scripts/backup-supabase.mjs` fails the workflow if any required table or included Storage bucket cannot be exported. `scripts/verify-backup.mjs` then reads every exported file and rejects missing files, count differences, byte differences, altered content, or SHA-256 mismatches. A partial green backup is therefore not possible.

## Restore runbook

1. Download the newest successful weekly package from Azure and compare it with the GitHub copy when both are available.
2. Extract the package and run `node scripts/verify-backup.mjs backup-output/<timestamp>` before importing anything.
3. Create a new, empty Supabase recovery project. Never restore over the damaged production project before validation.
4. Restore the PostgreSQL archive with a PostgreSQL 17 client. Review `linecrew-postgres.list`, then use `pg_restore --no-owner --no-acl --dbname <recovery-url> linecrew-postgres.dump`.
5. Upload files under `storage/<bucket>/` to the matching private buckets while preserving their complete paths.
6. Apply any repository migrations newer than the backup timestamp.
7. Verify login, company isolation, jobs, price books, daily reports, JSAs, attachments, billing exports, timekeeping, and audit history.
8. Change application environment variables only after recovery validation passes. Keep the former environment read-only until the recovery owner approves retirement.

## Operational response

Any failed scheduled backup or failed restore drill is a recovery incident. Investigate before the next scheduled run; do not treat a later green build as proof that the missed recovery point exists.
