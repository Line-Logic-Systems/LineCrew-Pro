-- Security advisor hardening for the trigger helper. The function only touches
-- NEW row fields, so an empty search_path is safe and prevents object-shadowing.
alter function public.set_daily_report_date() set search_path = '';
