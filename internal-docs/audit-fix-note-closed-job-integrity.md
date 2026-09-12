Claude audit findings addressed by migration 20260912005003:
- F32: block Daily Report submit/approve on closed jobs.
- F80: prevent direct leadership Daily Report updates on closed jobs.
- F23: stamp approver/reviewer metadata and timestamps on approval.

The migration was applied to production first through the Supabase migration API and then committed verbatim to Git. A dedicated CI guard checks the active-job gates, row locking, metadata stamps, anonymous revocations, and closed-job UPDATE policy.
