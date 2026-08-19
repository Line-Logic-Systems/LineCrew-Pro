# LineCrew Pro Disaster Recovery

## Goal
No single provider should be the only copy of LineCrew Pro.

## What the weekly backup contains
1. A Git bundle containing the complete repository history and branches.
2. JSON exports of LineCrew Pro application tables.
3. Copies of every object in Supabase Storage buckets, including JSA photos/PDFs.
4. A manifest with row/object counts and backup timestamp.

## Schedule
The GitHub workflow runs weekly on Sunday and can also be started manually. GitHub artifacts are retained for 30 days.

## Required GitHub Actions secrets
- `BACKUP_SUPABASE_URL`
- `BACKUP_SUPABASE_SERVICE_ROLE_KEY`

Never commit the service-role key to the repository.

## Important: independent off-provider copy
GitHub Actions artifacts protect against many accidental changes but are still hosted by GitHub. For true provider-loss protection, the packaged backup should also be copied to storage controlled outside GitHub/Supabase (for example Microsoft OneDrive/Azure, AWS S3, Backblaze B2, or a local encrypted drive). Add that destination before relying on this as the sole disaster-recovery system.

## Restore outline
### Code
Clone an empty repository and restore from `linecrew-pro-repository.bundle`:
`git clone linecrew-pro-repository.bundle LineCrew-Pro`

### Database
Create a new Supabase/Postgres environment, apply the migrations in `supabase/migrations`, then import exported application data in dependency order. Validate auth/profile relationships before enabling users.

### Storage
Create the required private buckets and upload the files from `storage/<bucket>/` preserving object paths. Reapply storage/RLS migrations before user access.

## Recovery testing
At least quarterly, restore a backup into a non-production environment and verify login, company isolation, jobs, price books, daily reports, JSA records, and JSA attachments.
