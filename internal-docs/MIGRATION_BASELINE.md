# Reconciling `supabase/migrations` with production

## The problem

The migration folder and the production database do not agree. Measured on
2026-09-01 against project `ldgkyxuozbozgkvwzadg`:

| | |
|---|---|
| Migration files in `supabase/migrations` | 161 |
| Migrations recorded applied in production | 130 |
| In the repository, never recorded as applied | 40 |
| Applied in production, no repository file at all | 9 |
| Relative order of the shared ones | differs |

The 40 unrecorded files include foundational ones — `job_package_foundation`,
`daily_report_audit_history`, `enforce_privileged_mfa_server_side`. The 9
orphans include `capability_whitelist_fix`,
`lock_security_definer_to_authenticated` and `security_cleanup_aug20`.

Repository filenames also drift from the recorded versions: the file
`20260901055156_admin_promotion_and_single_owner_governance.sql` was recorded
as version `20260901061256`.

## Why it matters

**You cannot rebuild production from this folder.** Two consequences:

1. **Disaster recovery is weaker than it appears.** The backups cover data. The
   schema path does not reproduce, so a restore into a schema built from these
   files would not match production.
2. **The Test project cannot mirror production.** Which means
   `test-two-company-isolation` — the strongest security check in CI — runs
   against a schema that may differ from the one customers use.

Nothing is broken in production today. The risk is entirely about rebuilding.

## The fix: squash to a baseline

Reconciling 49 individual discrepancies by hand is laborious and error-prone.
The standard remedy is to declare production's current schema the new starting
point.

### 1. Verify a recent backup first

Confirm a successful `Independent Disaster Backup` run and that its Azure copy
exists, per release rule 8. Do not start without one.

### 2. Dump production's schema

Using the Supabase CLI, authenticated with the same access token used by the
Edge Function deploy workflow. Confirm the exact flags with
`supabase db dump --help` before running — they change between CLI versions.

```
supabase db dump --project-ref ldgkyxuozbozgkvwzadg -f baseline.sql
```

This must be **schema only**, not data. Check the output before proceeding:
it should contain `create table` / `create function` / `create policy`
statements and no `insert into` of customer rows.

### 3. Stage the baseline

- Move all 161 existing files to `supabase/migrations/archive/`. Keep them —
  they are the historical record, and several document why a thing was done.
- Add the dump as a single `<timestamp>_baseline.sql` in `supabase/migrations/`.

### 4. Record it as already applied

Production already has this schema, so the baseline must be marked applied
rather than executed against it. Insert its version into
`supabase_migrations.schema_migrations` on **production**, then apply the
baseline normally to the **Test** project so the two finally match.

### 5. Verify

- `scripts/verify-production-schema.sql` — the existing read-only post-deploy
  check must still pass against production
- Compare function and policy counts between production and Test; they should
  now agree
- Run `test-two-company-isolation` against Test and confirm it still passes
- Supabase advisors should report zero ERROR-level findings

### 6. From then on

New migrations go through one path only — a file in `supabase/migrations`,
applied through the same runner every time. The mismatch above came from
mixing hand-applied dashboard SQL with committed files; that is the habit to
retire, not the tooling.

## What this does not need

No application downtime, no data migration, and no change to any running
function. The database is untouched except for one row recorded in
`schema_migrations`.
