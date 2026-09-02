-- Add covering indexes for every currently unindexed public-schema foreign key.
-- These indexes do not change data or access rules; they improve joins and
-- parent-row updates/deletes as company data grows.

create index if not exists app_error_events_user_id_idx on public.app_error_events (user_id);
create index if not exists billing_export_attachments_billing_batch_id_idx on public.billing_export_attachments (billing_batch_id);
create index if not exists billing_export_attachments_uploaded_by_idx on public.billing_export_attachments (uploaded_by);
create index if not exists billing_export_batches_archived_by_idx on public.billing_export_batches (archived_by);
create index if not exists billing_export_batches_created_by_idx on public.billing_export_batches (created_by);
create index if not exists billing_export_batches_job_id_idx on public.billing_export_batches (job_id);
create index if not exists billing_export_batches_parent_batch_id_idx on public.billing_export_batches (parent_batch_id);
create index if not exists billing_export_batches_updated_by_idx on public.billing_export_batches (updated_by);
create index if not exists billing_export_lines_daily_report_id_idx on public.billing_export_lines (daily_report_id);
create index if not exists billing_export_lines_job_id_idx on public.billing_export_lines (job_id);
create index if not exists billing_export_lines_price_book_item_id_idx on public.billing_export_lines (price_book_item_id);
create index if not exists billing_export_lines_production_location_id_idx on public.billing_export_lines (production_location_id);
create index if not exists companies_created_by_idx on public.companies (created_by);
create index if not exists contract_field_settings_company_id_idx on public.contract_field_settings (company_id);
create index if not exists contract_field_settings_updated_by_idx on public.contract_field_settings (updated_by);
create index if not exists daily_production_items_created_by_idx on public.daily_production_items (created_by);
create index if not exists daily_production_unit_locations_created_by_idx on public.daily_production_unit_locations (created_by);
create index if not exists daily_production_units_created_by_idx on public.daily_production_units (created_by);
create index if not exists daily_report_attachments_uploaded_by_idx on public.daily_report_attachments (uploaded_by);
create index if not exists daily_report_audit_events_actor_id_idx on public.daily_report_audit_events (actor_id);
create index if not exists daily_report_jsas_created_by_idx on public.daily_report_jsas (created_by);
create index if not exists daily_reports_created_by_idx on public.daily_reports (created_by);
create index if not exists daily_reports_redline_override_by_idx on public.daily_reports (redline_override_by);
create index if not exists job_assignment_audit_events_actor_id_idx on public.job_assignment_audit_events (actor_id);
create index if not exists job_assignment_audit_events_job_id_idx on public.job_assignment_audit_events (job_id);
create index if not exists job_assignment_audit_events_member_id_idx on public.job_assignment_audit_events (member_id);
create index if not exists job_closeout_history_actor_id_idx on public.job_closeout_history (actor_id);
create index if not exists job_leader_assignments_assigned_by_idx on public.job_leader_assignments (assigned_by);
create index if not exists job_leader_assignments_member_id_idx on public.job_leader_assignments (member_id);
create index if not exists job_package_authorized_units_created_by_idx on public.job_package_authorized_units (created_by);
create index if not exists job_package_work_points_created_by_idx on public.job_package_work_points (created_by);
create index if not exists job_packages_created_by_idx on public.job_packages (created_by);
create index if not exists job_packages_supersedes_package_id_idx on public.job_packages (supersedes_package_id);
create index if not exists jobs_closed_by_idx on public.jobs (closed_by);
create index if not exists jobs_created_by_idx on public.jobs (created_by);
create index if not exists jobs_reopened_by_idx on public.jobs (reopened_by);
create index if not exists jsa_upload_attachments_uploaded_by_idx on public.jsa_upload_attachments (uploaded_by);
create index if not exists pilot_feedback_resolved_by_idx on public.pilot_feedback (resolved_by);
create index if not exists pilot_feedback_submitted_by_idx on public.pilot_feedback (submitted_by);
create index if not exists price_books_created_by_idx on public.price_books (created_by);
create index if not exists storm_mode_assignments_assigned_by_idx on public.storm_mode_assignments (assigned_by);
create index if not exists support_access_requests_approved_by_idx on public.support_access_requests (approved_by);
create index if not exists support_access_requests_revoked_by_idx on public.support_access_requests (revoked_by);
create index if not exists support_audit_events_actor_id_idx on public.support_audit_events (actor_id);
create index if not exists support_audit_events_request_id_idx on public.support_audit_events (request_id);
create index if not exists team_invitations_accepted_by_idx on public.team_invitations (accepted_by);
create index if not exists team_invitations_invited_by_idx on public.team_invitations (invited_by);
create index if not exists timekeeping_employees_assigned_by_idx on public.timekeeping_employees (assigned_by);
create index if not exists timekeeping_employees_assigned_foreman_id_idx on public.timekeeping_employees (assigned_foreman_id);
create index if not exists timekeeping_entries_employee_id_idx on public.timekeeping_entries (employee_id);
create index if not exists timekeeping_entry_history_daily_report_id_idx on public.timekeeping_entry_history (daily_report_id);
create index if not exists timekeeping_entry_history_employee_id_idx on public.timekeeping_entry_history (employee_id);
create index if not exists timekeeping_entry_history_job_id_idx on public.timekeeping_entry_history (job_id);
create index if not exists timekeeping_pay_period_audit_actor_id_idx on public.timekeeping_pay_period_audit (actor_id);
create index if not exists timekeeping_pay_periods_approved_by_idx on public.timekeeping_pay_periods (approved_by);
create index if not exists timekeeping_pay_periods_locked_by_idx on public.timekeeping_pay_periods (locked_by);
create index if not exists utility_packet_imports_created_by_idx on public.utility_packet_imports (created_by);
create index if not exists utility_packet_imports_reviewed_by_idx on public.utility_packet_imports (reviewed_by);
create index if not exists work_points_company_id_idx on public.work_points (company_id);
create index if not exists work_points_created_by_idx on public.work_points (created_by);

-- Refresh planner statistics after the new indexes are available.
analyze;
