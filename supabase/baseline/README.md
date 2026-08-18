# Supabase schema baseline

This directory holds the reviewed, schema-only snapshot needed to rebuild the LineCrew Pro `public` database schema.

## Why this exists

The repository's original migration history starts after several core tables were created in the live project. Those incremental migrations cannot recreate a new LineCrew Pro database by themselves. The generated baseline captures the missing starting point without copying contractor records.

## Safety rules

- Generate the baseline only through the `Capture Supabase schema baseline` GitHub Actions workflow.
- Store the database connection string only in the protected `SUPABASE_DB_URL` Actions secret.
- Never paste the connection string into an issue, pull request, commit, or chat.
- The workflow requests schema only and rejects `COPY public...` or `INSERT INTO public...` row-data statements.
- Review the generated SQL and `manifest.json` before merging.
- Never hand-edit the generated SQL. Fix the live schema or capture tooling and regenerate it.

## Capture process

1. An Admin runs the manual GitHub workflow, or merges a reviewed change to this capture documentation/tooling into `chatgpt-dev`.
2. Supabase CLI exports the live `public` schema without table data.
3. The validator checks the core tables, Row Level Security, policies, functions, and absence of row data.
4. GitHub opens a draft pull request into `chatgpt-dev` for review.

After creating or rotating the protected `SUPABASE_DB_URL` secret, use a reviewed documentation-only change here to safely trigger a fresh capture without changing application code.

## Recovery order

1. Create a clean Supabase project with the required extensions enabled.
2. Revoke broad target-project default privileges before restoring, as described in the Supabase restore documentation.
3. Apply `00000000000000_public_schema.sql`.
4. Recreate custom Storage configuration using the repository's idempotent attachment migration.
5. Apply only migrations created after the baseline capture date.
6. Run the multi-tenant security and account onboarding test plans before allowing production traffic.

The baseline deliberately excludes production table data, Auth users, passwords, tokens, and Storage objects.
