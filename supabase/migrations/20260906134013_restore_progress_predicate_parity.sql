-- Restore a production function omitted from test. This is schema parity only;
-- utility portal RPCs intentionally do not use this broader contractor predicate.
create or replace function public.linecrew_report_counts_toward_progress(
  p_status text,
  p_reviewed_at timestamptz,
  p_review_notes text,
  p_archived boolean
)
returns boolean
language sql
immutable
parallel safe
set search_path to ''
as $$
  select coalesce(p_archived, false) is false
    and (
      lower(coalesce(p_status, 'draft')) in ('submitted', 'approved')
      or (
        lower(coalesce(p_status, 'draft')) = 'draft'
        and p_reviewed_at is null
        and nullif(btrim(coalesce(p_review_notes, '')), '') is null
      )
    );
$$;

revoke all on function public.linecrew_report_counts_toward_progress(
  text, timestamptz, text, boolean
) from public, anon, authenticated;
grant execute on function public.linecrew_report_counts_toward_progress(
  text, timestamptz, text, boolean
) to service_role;
