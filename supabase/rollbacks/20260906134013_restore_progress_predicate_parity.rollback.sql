-- Reverse order: 182620, 134013, 071452, 070834, 064624, 064002, 060001, 055947, 055940.
drop function if exists public.linecrew_report_counts_toward_progress(
  text, timestamptz, text, boolean
);
