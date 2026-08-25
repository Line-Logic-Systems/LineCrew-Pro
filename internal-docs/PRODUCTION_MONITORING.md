# LineCrew Pro Production Monitoring

## Purpose

The production monitor detects an outage or broad application failure before a company has to report it. It is intentionally independent of the LineCrew Pro support dashboard so it continues operating when the application itself is unavailable.

## Checks

`.github/workflows/production-health-monitor.yml` runs every five minutes and can also be started manually. It verifies:

1. `linecrewpro.com` returns a successful response and the expected LineCrew Pro page marker.
2. `app.linecrewpro.com` returns a successful response and the expected LineCrew Pro page marker.
3. The production Supabase Auth service responds successfully.
4. The sanitized `app_error_events` count remains below 10 events in a rolling 15-minute window.

The database check requests only the error event `id` and an exact count. It does not read company records, user details, error messages, or uploaded files.

## Alert behavior

If any check fails, the workflow opens a GitHub issue named `[Recovery Alert] Production Health Monitor failed`. Additional failed checks add comments to the same open incident. A later successful run comments with the recovery run and closes the issue.

The monitor uses a repository service-role secret only inside GitHub Actions. The key is never written to logs, committed to the repository, or exposed to the browser application.

## Future expansion

When production traffic grows, add a Vercel Log Drain or dedicated error-monitoring provider for server-side traces and an approved Supabase log export for authentication-failure rate alerts. Those additions require separate ingestion credentials and retention decisions; the current monitor does not create that new external data copy.
