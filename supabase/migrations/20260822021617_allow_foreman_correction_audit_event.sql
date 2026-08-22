alter table public.daily_report_audit_events drop constraint if exists daily_report_audit_events_event_type_check; alter table public.daily_report_audit_events add constraint daily_report_audit_events_event_type_check check (event_type = any (array['created'::text,'submitted'::text,'returned'::text,'approved'::text,'archived'::text,'restored'::text,'foreman_correction'::text]));

