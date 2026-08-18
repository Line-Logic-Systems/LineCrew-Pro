# Two-company isolation test

This manual GitHub Actions test creates two temporary contractor companies in a **disposable Supabase project**, signs in as an Admin from each company, and verifies that tenant isolation works in both directions.

It checks:

- each Admin can read their own company, profile, customer, Price Book, job and daily report;
- neither Admin can read the other company's records, even by using the exact record UUID;
- a same-company insert succeeds;
- a forged insert using the other company's `company_id` is rejected;
- cross-company update and delete attempts affect zero rows;
- disabling a profile immediately blocks its tenant data access;
- all temporary records and Auth users are removed after the test.

## Safety requirements

Never run this against production. The workflow requires a dedicated GitHub environment named `isolation-test`, a separate Supabase project reference, and the typed confirmation `DISPOSABLE_ONLY`. The service-role key is used only by GitHub Actions to seed and clean up temporary test data; it must never be added to browser code.

## One-time setup

1. Create a disposable Supabase project used only for automated security tests.
2. Load `supabase/baseline/00000000000000_public_schema.sql` into that project's SQL Editor. Do not replay the historical migration directory; its timestamp prefixes are not uniquely ordered.
3. In the GitHub repository, open **Settings → Environments**, create an environment named `isolation-test`, and add these environment secrets:
   - `SUPABASE_TEST_URL`
   - `SUPABASE_TEST_ANON_KEY`
   - `SUPABASE_TEST_SERVICE_ROLE_KEY`
   - `SUPABASE_TEST_PROJECT_REF`
   - `SUPABASE_PRODUCTION_PROJECT_REF`
4. Keep the disposable test project empty of real contractor information.

## Run the test

1. Open **Actions → Test two-company isolation**.
2. Choose **Run workflow** and select `chatgpt-dev`.
3. Enter `DISPOSABLE_ONLY` in the confirmation field.
4. Run the workflow and confirm the job ends in green with the `PASS` message.

Real-world meaning: if Contractor A somehow learns Contractor B's customer, job or report UUID, Supabase still returns no row and refuses attempted changes. The browser UI is not the security boundary; RLS is.
