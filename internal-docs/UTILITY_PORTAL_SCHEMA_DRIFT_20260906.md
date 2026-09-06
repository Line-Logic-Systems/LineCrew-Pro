# Utility Portal schema drift report

Generated 2026-09-06 by read-only catalog queries against production and test, after applying the standalone parity restoration for `linecrew_report_counts_toward_progress` to test. Production was not modified.

## Result

The schemas are **not at parity**. Production is materially ahead of test outside the Utility Portal work. Section 13 isolation and contractor-regression results are not valid until this unrelated drift is reconciled or explicitly justified.

## Post-review correction and dependency finding

The first column comparison keyed rows by ordinal position as well as table and
column name. That overstated column additions/removals when the same column
occupied a different position. The four entries originally labelled
“Other test-only entries” (`companies.week_start_day`,
`daily_report_jsas.client_submission_id`, `daily_report_jsas.details`, and
`job_packages.supersedes_package_id`) exist in both projects. Their ordinal
positions differ; they are not test-only work.

The object comparison also did not validate function dependencies. Test's
`enforce_linecrew_company_access()` can reference production-only functions at
runtime even though its own name/signature comparison succeeds. In particular,
`linecrew_privileged_mfa_satisfied()` and `linecrew_mfa_bootstrap_identity()`
are absent in test. Privileged gate execution can therefore fail with SQLSTATE
42883 before the intended authorization checks run.

Repository-history triage of the four apparent non-portal test-only functions:

- `set_my_timekeeping_crew(uuid[])` is obsolete. Migration
  `20260823030000_company_employee_roster_assignment.sql` deliberately drops it
  because crew assignment became a leadership roster action. The production
  readiness validator explicitly requires that drop. Do not preserve it.
- `get_job_leader_assignments()` is an older result signature; production has
  the superseding signature with assignment actor and timestamp. Do not preserve
  the test version.
- `get_price_book_items_for_user(uuid)` is an older pre-transfer-pricing
  signature; production has the superseding transfer-aware signature. Do not
  preserve the test version.
- `my_company_billing_summary()` is an older signature; production has the
  superseding result including `past_due_since`. Do not preserve the test
  version.

Decision: rebuild test from a fresh production schema-only snapshot, then replay
the Utility Portal migrations. Do not attempt to close this drift with a large
set of handwritten parity migrations. A destructive reset still requires an
explicit human approval immediately before execution.

“Expected test-only” below means an object introduced by the unpromoted Utility Portal migrations. It does not mean approved for production.

## Functions (names and signatures)

- Test count: 168
- Production count: 251
- Expected test-only portal entries: 15
- Other test-only entries: 4
- Production-only entries: 102
- Same-key definitions that differ: 0

### Expected test-only portal entries

- `is_utility_user() -> boolean`
- `linecrew_company_access_enabled(p_company_id uuid) -> boolean`
- `linecrew_enforce_job_contract_company_match() -> trigger`
- `utility_accept_invitation(p_token_hash text, p_full_name text) -> void`
- `utility_block_profile_insert() -> trigger`
- `utility_current_org_id() -> uuid`
- `utility_current_user_id() -> uuid`
- `utility_enforce_contract_company_match() -> trigger`
- `utility_get_job_progress(p_job_id uuid) -> TABLE(work_point_code text, work_point_description text, unit_code text, unit_description text, percent_complete numeric, authorized_install_quantity numeric, approved_install_quantity numeric, authorized_retirement_quantity numeric, approved_retirement_quantity numeric)`
- `utility_has_contract_access(p_contract_id uuid) -> boolean`
- `utility_has_job_access(p_job_id uuid) -> boolean`
- `utility_list_jobs() -> TABLE(job_id uuid, job_number text, job_name text, contractor_company_name text, contract_name text, job_status text, overall_approved_percent numeric, last_updated timestamp with time zone)`
- `utility_log_job_contract_visibility() -> trigger`
- `utility_log_view(p_job_id uuid, p_action text) -> void`
- `utility_me() -> TABLE(full_name text, organization_name text)`

### Other test-only entries

- `get_job_leader_assignments() -> TABLE(job_id uuid, member_id uuid, full_name text, member_role text)`
- `get_price_book_items_for_user(p_price_book_id uuid) -> TABLE(id uuid, company_id uuid, price_book_id uuid, item_code text, item_name text, description text, install_price numeric, retirement_price numeric, unit_of_measure text, category text, extra_data jsonb, active boolean, created_at timestamp with time zone, updated_at timestamp with time zone, actual_install_price numeric, actual_retirement_price numeric, adjusted_install_price numeric, adjusted_retirement_price numeric, has_adjustment boolean)`
- `my_company_billing_summary() -> TABLE(plan_code text, monthly_price_cents integer, currency text, status text, access_enabled boolean, provider text, trial_ends_at timestamp with time zone, current_period_end timestamp with time zone, cancel_at_period_end boolean, stripe_customer_linked boolean, stripe_subscription_linked boolean, included_crew_limit integer, rolling_peak_billable_crews integer, rolling_overage_crew_days integer, crew_overage_status text, recommended_plan_code text, company_name text, contact_email text)`
- `set_my_timekeeping_crew(p_employee_ids uuid[]) -> void`

### Production-only entries

- `activate_finalized_utility_packet_revision() -> trigger`
- `assign_job_package_revision() -> trigger`
- `company_decide_support_request(p_request_id uuid, p_approve boolean) -> void`
- `company_list_support_requests() -> TABLE(id uuid, reason text, status text, requested_at timestamp with time zone, requested_minutes integer, approved_at timestamp with time zone, expires_at timestamp with time zone, support_name text)`
- `company_revoke_support_access(p_request_id uuid) -> void`
- `company_support_audit_history() -> TABLE(event_type text, created_at timestamp with time zone, details jsonb, actor_name text)`
- `complete_assistant_memory(p_memory_id uuid) -> void`
- `create_assistant_memory(p_memory_type text, p_title text, p_instruction text, p_trigger_type text, p_job_id uuid) -> uuid`
- `create_billing_credit_batch(p_paid_batch_id uuid, p_reason text) -> uuid`
- `create_billing_export_batch(p_job_id uuid, p_date_from date, p_date_to date, p_include_redlines boolean, p_notes text) -> uuid`
- `create_billing_export_batch_v2(p_job_id uuid, p_date_from date, p_date_to date, p_include_redlines boolean, p_notes text, p_is_final boolean) -> uuid`
- `create_team_invitation(p_email text, p_token_hash text, p_expires_at timestamp with time zone) -> uuid`
- `delete_billing_export_attachment(p_attachment_id uuid) -> text`
- `delete_void_billing_export_batch(p_batch_id uuid) -> void`
- `enforce_draft_job_package_unit_mutation() -> trigger`
- `enforce_foreman_assigned_job() -> trigger`
- `finalize_job_package_spreadsheet_import(p_package_id uuid, p_rows jsonb, p_source_filename text) -> jsonb`
- `finalize_utility_packet_import_review(p_import_id uuid, p_rows jsonb) -> jsonb`
- `get_billing_export_attachments(p_batch_id uuid) -> TABLE(id uuid, storage_path text, original_filename text, mime_type text, file_size_bytes bigint, caption text, uploaded_by uuid, created_at timestamp with time zone)`
- `get_billing_export_batch_lines(p_batch_id uuid) -> TABLE(line_id uuid, batch_number text, job_number text, job_name text, customer_name text, utility_name text, report_date date, foreman_name text, crew_name text, work_point text, unit_code text, unit_name text, unit_description text, work_type text, quantity numeric, unit_price numeric, extended_value numeric, authorization_status text)`
- `get_billing_export_batches() -> TABLE(batch_id uuid, batch_number text, job_id uuid, job_number text, job_name text, date_from date, date_to date, include_redlines boolean, status text, authorized_line_count integer, redline_line_count integer, total_value numeric, notes text, created_by_name text, created_at timestamp with time zone, exported_at timestamp with time zone, submitted_at timestamp with time zone, paid_at timestamp with time zone, voided_at timestamp with time zone)`
- `get_billing_export_batches_v2() -> TABLE(batch_id uuid, batch_number text, job_id uuid, job_number text, job_name text, date_from date, date_to date, include_redlines boolean, status text, billing_type text, billing_sequence integer, authorized_line_count integer, redline_line_count integer, total_value numeric, notes text, created_by_name text, created_at timestamp with time zone, exported_at timestamp with time zone, submitted_at timestamp with time zone, paid_at timestamp with time zone, voided_at timestamp with time zone)`
- `get_billing_export_batches_v3() -> TABLE(batch_id uuid, batch_number text, job_id uuid, job_number text, job_name text, date_from date, date_to date, include_redlines boolean, status text, billing_type text, billing_sequence integer, authorized_line_count integer, redline_line_count integer, total_value numeric, notes text, utility_invoice_number text, payment_reference text, correction_reason text, final_override_reason text, parent_batch_id uuid, parent_batch_number text, attachment_count bigint, created_by_name text, created_at timestamp with time zone, exported_at timestamp with time zone, submitted_at timestamp with time zone, paid_at timestamp with time zone, voided_at timestamp with time zone)`
- `get_billing_export_batches_v4(p_archive_filter text) -> TABLE(batch_id uuid, batch_number text, job_id uuid, job_number text, job_name text, date_from date, date_to date, include_redlines boolean, status text, billing_type text, billing_sequence integer, authorized_line_count integer, redline_line_count integer, total_value numeric, notes text, utility_invoice_number text, payment_reference text, correction_reason text, final_override_reason text, parent_batch_id uuid, parent_batch_number text, attachment_count bigint, created_by_name text, created_at timestamp with time zone, exported_at timestamp with time zone, submitted_at timestamp with time zone, paid_at timestamp with time zone, voided_at timestamp with time zone, archived_at timestamp with time zone, archived_by_name text)`
- `get_complete_job_billing_export_details_v1(p_job_id uuid) -> jsonb`
- `get_completed_job_export_details_v1(p_job_id uuid) -> jsonb`
- `get_daily_report_unit_authorized_action(p_report_id uuid, p_price_book_item_id uuid, p_pole_location text) -> TABLE(preferred_work_type text, authorized_install_quantity numeric, authorized_transfer_quantity numeric, authorized_retirement_quantity numeric)`
- `get_daily_report_unit_catalog_visible(p_report_id uuid) -> TABLE(price_book_item_id uuid, item_code text, item_name text, description text, unit_of_measure text, category text, install_price numeric, retirement_price numeric, actual_install_price numeric, actual_retirement_price numeric, adjusted_install_price numeric, adjusted_retirement_price numeric, has_adjustment boolean, install_quantity numeric, retirement_quantity numeric, actual_line_value numeric, adjusted_line_value numeric, visible_line_value numeric)`
- `get_daily_report_unit_locations_v2(p_report_id uuid) -> TABLE(location_line_id uuid, price_book_item_id uuid, item_code text, item_name text, description text, unit_of_measure text, category text, pole_location text, install_price numeric, retirement_price numeric, actual_install_price numeric, actual_retirement_price numeric, adjusted_install_price numeric, adjusted_retirement_price numeric, has_adjustment boolean, install_quantity numeric, transfer_quantity numeric, retirement_quantity numeric, actual_line_value numeric, adjusted_line_value numeric, visible_line_value numeric, authorization_status text, authorization_note text)`
- `get_daily_report_unit_locations_visible_v2(p_report_id uuid) -> TABLE(location_line_id uuid, price_book_item_id uuid, item_code text, item_name text, description text, unit_of_measure text, category text, pole_location text, install_price numeric, retirement_price numeric, actual_install_price numeric, actual_retirement_price numeric, adjusted_install_price numeric, adjusted_retirement_price numeric, has_adjustment boolean, install_quantity numeric, transfer_quantity numeric, retirement_quantity numeric, actual_line_value numeric, adjusted_line_value numeric, visible_line_value numeric, authorization_status text, authorization_note text)`
- `get_job_assignment_history(p_job_id uuid) -> TABLE(action text, member_name text, actor_name text, event_at timestamp with time zone)`
- `get_job_closeout_history(p_job_id uuid) -> TABLE(id uuid, action text, reason text, blockers jsonb, actor_id uuid, actor_name text, actor_role text, occurred_at timestamp with time zone)`
- `get_job_leader_assignments() -> TABLE(job_id uuid, member_id uuid, full_name text, member_role text, assigned_by_name text, assigned_at timestamp with time zone)`
- `get_job_package_revision_delta_v2(p_package_id uuid) -> TABLE(work_point text, unit_code text, prior_install numeric, new_install numeric, install_change numeric, prior_transfer numeric, new_transfer numeric, transfer_change numeric, prior_remove numeric, new_remove numeric, remove_change numeric)`
- `get_job_package_work_points_v2(p_package_id uuid) -> TABLE(work_point_id uuid, work_point_code text, work_point_description text, authorized_unit_id uuid, unit_code text, unit_name text, unit_description text, authorized_install_quantity numeric, authorized_transfer_quantity numeric, authorized_retirement_quantity numeric, reported_install_quantity numeric, reported_transfer_quantity numeric, reported_retirement_quantity numeric, approved_install_quantity numeric, approved_transfer_quantity numeric, approved_retirement_quantity numeric, authorized_value numeric, reported_value numeric, approved_value numeric)`
- `get_pending_utility_packet_import_for_package(p_package_id uuid) -> TABLE(import_id uuid, provider_key text, format_key text, profile_version text, source_filename text, detected_work_order text, extraction_confidence numeric, extraction_summary jsonb)`
- `get_price_book_items_for_user(p_price_book_id uuid) -> TABLE(id uuid, company_id uuid, price_book_id uuid, item_code text, item_name text, description text, install_price numeric, transfer_price numeric, retirement_price numeric, unit_of_measure text, category text, extra_data jsonb, active boolean, created_at timestamp with time zone, updated_at timestamp with time zone, actual_install_price numeric, actual_transfer_price numeric, actual_retirement_price numeric, adjusted_install_price numeric, adjusted_transfer_price numeric, adjusted_retirement_price numeric, has_adjustment boolean)`
- `get_price_book_items_visible(p_price_book_id uuid) -> TABLE(id uuid, company_id uuid, price_book_id uuid, item_code text, item_name text, description text, install_price numeric, transfer_price numeric, retirement_price numeric, unit_of_measure text, category text, extra_data jsonb, active boolean, created_at timestamp with time zone, updated_at timestamp with time zone, actual_install_price numeric, actual_transfer_price numeric, actual_retirement_price numeric, adjusted_install_price numeric, adjusted_transfer_price numeric, adjusted_retirement_price numeric, has_adjustment boolean)`
- `import_price_book_items_atomic(p_price_book_id uuid, p_rows jsonb, p_update_existing boolean, p_source_filename text) -> jsonb`
- `linecrew_admin_replace_company_owner(current_owner_id uuid, replacement_admin_id uuid, former_owner_role text) -> void`
- `linecrew_can_manage_packet_unit_aliases() -> boolean`
- `linecrew_can_use_billing_exports_internal() -> boolean`
- `linecrew_delete_push_subscription(p_endpoint text) -> void`
- `linecrew_enqueue_billing_grace_warnings() -> integer`
- `linecrew_enqueue_due_push_reminders() -> integer`
- `linecrew_enqueue_push_notification(p_company_id uuid, p_recipient_id uuid, p_event_key text, p_event_type text, p_subject_id uuid, p_body text, p_url text, p_tag text) -> void`
- `linecrew_mfa_bootstrap_identity() -> TABLE(user_role text, is_support boolean, requires_mfa boolean, enforcement_active boolean, current_aal text)`
- `linecrew_my_gf_notification_preference() -> text`
- `linecrew_my_push_status() -> TABLE(subscription_count integer)`
- `linecrew_packet_unit_aliases_for_import(p_import_id uuid) -> TABLE(packet_code text, normalized_code text, target_item_code text, target_exists boolean, updated_at timestamp with time zone)`
- `linecrew_price_book_units_for_import(p_import_id uuid) -> TABLE(item_code text, item_name text, description text, install_price numeric, transfer_price numeric, retirement_price numeric)`
- `linecrew_privileged_mfa_satisfied() -> boolean`
- `linecrew_queue_completed_jsa_push() -> trigger`
- `linecrew_queue_daily_report_push() -> trigger`
- `linecrew_queue_uploaded_jsa_push() -> trigger`
- `linecrew_resolve_job_price_book(p_company_id uuid, p_job_id uuid, p_contract_id uuid) -> uuid`
- `linecrew_save_push_subscription(p_endpoint text, p_p256dh text, p_auth text, p_user_agent text) -> void`
- `linecrew_set_member_money_permissions(target_user_id uuid, can_see_actual boolean, can_see_field boolean) -> void`
- `linecrew_set_my_gf_notification_preference(p_mode text) -> text`
- `linecrew_set_packet_unit_alias(p_import_id uuid, p_packet_code text, p_target_item_code text) -> jsonb`
- `linecrew_transfer_company_owner(target_admin_id uuid) -> void`
- `linecrew_utility_packet_import_matches(p_import_id uuid) -> TABLE(row_id uuid, price_book_item_id uuid, canonical_unit_code text)`
- `my_company_billing_summary() -> TABLE(plan_code text, monthly_price_cents integer, currency text, status text, access_enabled boolean, provider text, trial_ends_at timestamp with time zone, current_period_end timestamp with time zone, cancel_at_period_end boolean, stripe_customer_linked boolean, stripe_subscription_linked boolean, included_crew_limit integer, rolling_peak_billable_crews integer, rolling_overage_crew_days integer, crew_overage_status text, recommended_plan_code text, company_name text, contact_email text, past_due_since timestamp with time zone)`
- `prevent_duplicate_daily_report() -> trigger`
- `prevent_non_draft_job_package_delete() -> trigger`
- `record_app_error(p_area text, p_error_code text, p_page text, p_message text) -> void`
- `register_billing_export_attachment(p_batch_id uuid, p_storage_path text, p_original_filename text, p_mime_type text, p_file_size_bytes bigint, p_caption text) -> uuid`
- `remove_assistant_memory(p_memory_id uuid) -> void`
- `resolve_utility_packet_price_item(p_import_id uuid, p_contractor_unit_code text, p_work_type text) -> uuid`
- `save_billing_export_batch_details(p_batch_id uuid, p_utility_invoice_number text, p_payment_reference text, p_notes text) -> void`
- `save_daily_report_unit_location_v2(p_report_id uuid, p_price_book_item_id uuid, p_pole_location text, p_install_quantity numeric, p_transfer_quantity numeric, p_retirement_quantity numeric) -> uuid`
- `save_job_package_authorized_unit_v2(p_work_point_id uuid, p_unit_code text, p_install_quantity numeric, p_transfer_quantity numeric, p_retirement_quantity numeric) -> uuid`
- `set_billing_export_batch_status(p_batch_id uuid, p_status text) -> void`
- `set_billing_export_batch_status_v2(p_batch_id uuid, p_status text, p_reason text) -> void`
- `set_company_notification_reminder_times(p_daily_report_reminder_time time without time zone, p_jsa_reminder_time time without time zone) -> TABLE(daily_report_reminder_time time without time zone, jsa_reminder_time time without time zone)`
- `set_daily_production_transfer_price_snapshot() -> trigger`
- `set_job_closeout(p_job_id uuid, p_close boolean, p_reason text) -> void`
- `set_void_billing_batch_archived(p_batch_id uuid, p_archived boolean) -> void`
- `submit_pilot_feedback(p_category text, p_rating integer, p_message text, p_page text, p_contact_ok boolean) -> uuid`
- `supersede_prior_job_package() -> trigger`
- `support_console_identity() -> TABLE(is_support boolean, company_id uuid, company_role text)`
- `support_get_diagnostics(p_request_id uuid) -> jsonb`
- `support_get_recent_errors(p_request_id uuid) -> TABLE(id bigint, area text, error_code text, page text, safe_message text, created_at timestamp with time zone)`
- `support_list_companies() -> TABLE(id uuid, name text, active_users bigint, last_activity timestamp with time zone, subscription_status text, subscription_expires_at timestamp with time zone, recent_errors bigint)`
- `support_list_my_requests() -> TABLE(id uuid, company_id uuid, company_name text, reason text, status text, requested_at timestamp with time zone, requested_minutes integer, approved_at timestamp with time zone, expires_at timestamp with time zone)`
- `support_list_pilot_command_center() -> TABLE(company_id uuid, company_name text, company_active boolean, subscription_status text, subscription_expires_at timestamp with time zone, company_created_at timestamp with time zone, active_users bigint, setup_completed integer, setup_total integer, setup_missing text[], open_feedback bigint, recent_errors bigint, latest_error_area text, latest_error_code text, pending_support_approvals bigint)`
- `support_list_pilot_feedback(p_limit integer) -> TABLE(id uuid, company_id uuid, company_name text, submitted_by uuid, submitted_name text, category text, rating smallint, message text, page text, contact_ok boolean, created_at timestamp with time zone, resolved_at timestamp with time zone)`
- `support_request_access(p_company_id uuid, p_reason text, p_minutes integer) -> uuid`
- `support_resolve_pilot_feedback(p_feedback_id uuid) -> void`
- `support_set_company_access(p_company_id uuid, p_status text, p_expires_at timestamp with time zone) -> void`
- `sync_daily_report_hours_from_timekeeping() -> trigger`
- `sync_foreman_timekeeping_employee() -> trigger`
- `timekeeping_report_rows_v2(p_from date, p_through date, p_employee uuid, p_job uuid) -> TABLE(employee_id uuid, daily_report_id uuid, job_id uuid, work_date date, crew_name text, regular_hours numeric, overtime_hours numeric, storm_work boolean, notes text, segment_source text, start_time time without time zone, stop_time time without time zone, lunch_minutes integer, per_diem boolean, equipment_used text, equipment_not_used boolean)`
- `timekeeping_report_rows_v3(p_from date, p_through date, p_employee uuid, p_job uuid) -> TABLE(entry_id uuid, employee_id uuid, daily_report_id uuid, job_id uuid, work_date date, crew_name text, regular_hours numeric, overtime_hours numeric, storm_work boolean, notes text, segment_source text, start_time time without time zone, stop_time time without time zone, lunch_minutes integer, per_diem boolean, equipment_used text, equipment_not_used boolean, entry_kind text, labor_code text)`
- `training_role_rank(p_role text) -> integer`
- `update_company_man_hour_rate(p_required_rate numeric) -> numeric`
- `update_my_profile_name(p_full_name text) -> TABLE(id uuid, full_name text, role text, company_id uuid)`
- `update_utility_packet_import_rows_bulk(p_import_id uuid, p_rows jsonb) -> jsonb`
- `upsert_leadership_employee_time(p_employee_id uuid, p_entry_id uuid, p_work_date date, p_start_time time without time zone, p_stop_time time without time zone, p_lunch_minutes integer, p_job_id uuid, p_labor_code text, p_per_diem boolean, p_equipment_used text, p_equipment_not_used boolean, p_notes text) -> TABLE(entry_id uuid, regular_hours numeric, overtime_hours numeric)`
- `upsert_my_leadership_time(p_entry_id uuid, p_work_date date, p_start_time time without time zone, p_stop_time time without time zone, p_lunch_minutes integer, p_job_id uuid, p_labor_code text, p_per_diem boolean, p_equipment_used text, p_equipment_not_used boolean, p_notes text) -> TABLE(entry_id uuid, regular_hours numeric, overtime_hours numeric)`
- `validate_timekeeping_employee_admin_assignment() -> trigger`
- `validate_timekeeping_employee_assignment() -> trigger`

## Tables and columns

- Test count: 623
- Production count: 816
- Expected test-only portal entries: 47
- Other test-only entries: 4
- Production-only entries: 244
- Same-key definitions that differ: 1

### Expected test-only portal entries

- `customers.utility_organization_id [13]`
- `utility_activity_log.action [8]`
- `utility_activity_log.actor_user_id [4]`
- `utility_activity_log.company_id [5]`
- `utility_activity_log.contract_id [6]`
- `utility_activity_log.created_at [10]`
- `utility_activity_log.detail [9]`
- `utility_activity_log.id [1]`
- `utility_activity_log.job_id [7]`
- `utility_activity_log.utility_organization_id [2]`
- `utility_activity_log.utility_user_id [3]`
- `utility_contract_access.company_id [3]`
- `utility_contract_access.contract_id [4]`
- `utility_contract_access.expires_at [10]`
- `utility_contract_access.granted_at [7]`
- `utility_contract_access.granted_by [6]`
- `utility_contract_access.id [1]`
- `utility_contract_access.revoked_at [9]`
- `utility_contract_access.revoked_by [8]`
- `utility_contract_access.show_quantities [5]`
- `utility_contract_access.status [11]`
- `utility_contract_access.utility_organization_id [2]`
- `utility_organizations.active [3]`
- `utility_organizations.created_at [5]`
- `utility_organizations.created_by [4]`
- `utility_organizations.id [1]`
- `utility_organizations.name [2]`
- `utility_organizations.updated_at [6]`
- `utility_portal_feature_flags.company_id [2]`
- `utility_portal_feature_flags.created_at [5]`
- `utility_portal_feature_flags.created_by [4]`
- `utility_portal_feature_flags.enabled [3]`
- `utility_portal_feature_flags.id [1]`
- `utility_portal_feature_flags.updated_at [7]`
- `utility_portal_feature_flags.updated_by [6]`
- `utility_users.accepted_at [9]`
- `utility_users.created_at [11]`
- `utility_users.email [4]`
- `utility_users.full_name [5]`
- `utility_users.id [1]`
- `utility_users.invite_expires_at [8]`
- `utility_users.invite_token_hash [7]`
- `utility_users.last_sign_in_at [10]`
- `utility_users.status [6]`
- `utility_users.updated_at [12]`
- `utility_users.user_id [3]`
- `utility_users.utility_organization_id [2]`

### Other test-only entries

- `companies.week_start_day [21]`
- `daily_report_jsas.client_submission_id [22]`
- `daily_report_jsas.details [23]`
- `job_packages.supersedes_package_id [14]`

### Production-only entries

- `app_error_events.area [4]`
- `app_error_events.company_id [2]`
- `app_error_events.created_at [8]`
- `app_error_events.error_code [5]`
- `app_error_events.id [1]`
- `app_error_events.page [6]`
- `app_error_events.safe_message [7]`
- `app_error_events.user_id [3]`
- `assistant_memories.active [8]`
- `assistant_memories.company_id [2]`
- `assistant_memories.completed_at [13]`
- `assistant_memories.completed_by [12]`
- `assistant_memories.created_at [10]`
- `assistant_memories.created_by [9]`
- `assistant_memories.id [1]`
- `assistant_memories.instruction [6]`
- `assistant_memories.job_id [3]`
- `assistant_memories.memory_type [4]`
- `assistant_memories.removed_at [15]`
- `assistant_memories.removed_by [14]`
- `assistant_memories.title [5]`
- `assistant_memories.trigger_type [7]`
- `assistant_memories.updated_at [11]`
- `billing_export_attachments.billing_batch_id [3]`
- `billing_export_attachments.caption [8]`
- `billing_export_attachments.company_id [2]`
- `billing_export_attachments.created_at [10]`
- `billing_export_attachments.file_size_bytes [7]`
- `billing_export_attachments.id [1]`
- `billing_export_attachments.mime_type [6]`
- `billing_export_attachments.original_filename [5]`
- `billing_export_attachments.storage_path [4]`
- `billing_export_attachments.uploaded_by [9]`
- `billing_export_batches.archived_at [28]`
- `billing_export_batches.archived_by [29]`
- `billing_export_batches.authorized_line_count [9]`
- `billing_export_batches.batch_number [4]`
- `billing_export_batches.billing_sequence [20]`
- `billing_export_batches.billing_type [19]`
- `billing_export_batches.company_id [2]`
- `billing_export_batches.correction_reason [23]`
- `billing_export_batches.created_at [14]`
- `billing_export_batches.created_by [13]`
- `billing_export_batches.date_from [5]`
- `billing_export_batches.date_to [6]`
- `billing_export_batches.exported_at [15]`
- `billing_export_batches.final_override_reason [24]`
- `billing_export_batches.id [1]`
- `billing_export_batches.include_redlines [7]`
- `billing_export_batches.job_id [3]`
- `billing_export_batches.notes [12]`
- `billing_export_batches.paid_at [17]`
- `billing_export_batches.parent_batch_id [25]`
- `billing_export_batches.payment_reference [22]`
- `billing_export_batches.redline_line_count [10]`
- `billing_export_batches.status [8]`
- `billing_export_batches.submitted_at [16]`
- `billing_export_batches.total_value [11]`
- `billing_export_batches.updated_at [26]`
- `billing_export_batches.updated_by [27]`
- `billing_export_batches.utility_invoice_number [21]`
- `billing_export_batches.voided_at [18]`
- `billing_export_lines.active [20]`
- `billing_export_lines.authorization_status [19]`
- `billing_export_lines.billing_batch_id [3]`
- `billing_export_lines.company_id [2]`
- `billing_export_lines.created_at [21]`
- `billing_export_lines.crew_name [9]`
- `billing_export_lines.daily_report_id [5]`
- `billing_export_lines.extended_value [18]`
- `billing_export_lines.foreman_name [8]`
- `billing_export_lines.id [1]`
- `billing_export_lines.job_id [4]`
- `billing_export_lines.price_book_item_id [11]`
- `billing_export_lines.production_location_id [6]`
- `billing_export_lines.quantity [16]`
- `billing_export_lines.report_date [7]`
- `billing_export_lines.unit_code [12]`
- `billing_export_lines.unit_description [14]`
- `billing_export_lines.unit_name [13]`
- `billing_export_lines.unit_price [17]`
- `billing_export_lines.work_point [10]`
- `billing_export_lines.work_type [15]`
- `companies.daily_report_reminder_time [23]`
- `companies.jsa_reminder_time [24]`
- `companies.required_man_hour_rate [21]`
- `companies.week_start_day [22]`
- `daily_production_units.actual_transfer_price [24]`
- `daily_production_units.adjusted_transfer_price [25]`
- `daily_report_jsas.client_submission_id [23]`
- `daily_report_jsas.details [22]`
- `job_assignment_audit_events.action [6]`
- `job_assignment_audit_events.actor_id [5]`
- `job_assignment_audit_events.actor_name [9]`
- `job_assignment_audit_events.company_id [2]`
- `job_assignment_audit_events.created_at [10]`
- `job_assignment_audit_events.id [1]`
- `job_assignment_audit_events.job_id [3]`
- `job_assignment_audit_events.job_number [7]`
- `job_assignment_audit_events.member_id [4]`
- `job_assignment_audit_events.member_name [8]`
- `job_closeout_history.action [4]`
- `job_closeout_history.actor_id [7]`
- `job_closeout_history.actor_role [8]`
- `job_closeout_history.blockers [6]`
- `job_closeout_history.company_id [2]`
- `job_closeout_history.id [1]`
- `job_closeout_history.job_id [3]`
- `job_closeout_history.occurred_at [9]`
- `job_closeout_history.reason [5]`
- `job_packages.revision_number [14]`
- `job_packages.supersedes_package_id [15]`
- `jobs.closed_by [16]`
- `jobs.closeout_notes [15]`
- `jobs.closeout_status [14]`
- `jobs.reopened_at [17]`
- `jobs.reopened_by [18]`
- `pilot_feedback.category [4]`
- `pilot_feedback.company_id [2]`
- `pilot_feedback.contact_ok [8]`
- `pilot_feedback.created_at [9]`
- `pilot_feedback.id [1]`
- `pilot_feedback.message [6]`
- `pilot_feedback.page [7]`
- `pilot_feedback.rating [5]`
- `pilot_feedback.resolved_at [10]`
- `pilot_feedback.resolved_by [11]`
- `pilot_feedback.submitted_by [3]`
- `price_book_items.transfer_price [15]`
- `push_notification_outbox.attempt_count [15]`
- `push_notification_outbox.available_at [12]`
- `push_notification_outbox.body [8]`
- `push_notification_outbox.company_id [2]`
- `push_notification_outbox.created_at [17]`
- `push_notification_outbox.event_key [4]`
- `push_notification_outbox.event_type [5]`
- `push_notification_outbox.id [1]`
- `push_notification_outbox.last_error [16]`
- `push_notification_outbox.locked_at [13]`
- `push_notification_outbox.recipient_id [3]`
- `push_notification_outbox.sent_at [14]`
- `push_notification_outbox.status [11]`
- `push_notification_outbox.subject_id [6]`
- `push_notification_outbox.tag [10]`
- `push_notification_outbox.title [7]`
- `push_notification_outbox.updated_at [18]`
- `push_notification_outbox.url [9]`
- `push_notification_preferences.company_id [1]`
- `push_notification_preferences.created_at [4]`
- `push_notification_preferences.gf_delivery_mode [3]`
- `push_notification_preferences.updated_at [5]`
- `push_notification_preferences.user_id [2]`
- `push_subscriptions.auth [6]`
- `push_subscriptions.company_id [2]`
- `push_subscriptions.created_at [8]`
- `push_subscriptions.endpoint [4]`
- `push_subscriptions.failure_count [10]`
- `push_subscriptions.id [1]`
- `push_subscriptions.last_success_at [9]`
- `push_subscriptions.p256dh [5]`
- `push_subscriptions.user_agent [7]`
- `push_subscriptions.user_id [3]`
- `support_access_requests.approved_at [9]`
- `support_access_requests.approved_by [8]`
- `support_access_requests.company_id [3]`
- `support_access_requests.expires_at [10]`
- `support_access_requests.id [1]`
- `support_access_requests.reason [4]`
- `support_access_requests.requested_at [7]`
- `support_access_requests.requested_minutes [5]`
- `support_access_requests.revoked_at [12]`
- `support_access_requests.revoked_by [11]`
- `support_access_requests.status [6]`
- `support_access_requests.support_user_id [2]`
- `support_audit_events.actor_id [4]`
- `support_audit_events.company_id [3]`
- `support_audit_events.created_at [7]`
- `support_audit_events.details [6]`
- `support_audit_events.event_type [5]`
- `support_audit_events.id [1]`
- `support_audit_events.request_id [2]`
- `timekeeping_employees.admin_assigned_at [18]`
- `timekeeping_employees.admin_assigned_by [17]`
- `timekeeping_employees.assigned_admin_id [16]`
- `timekeeping_employees.assigned_at [13]`
- `timekeeping_employees.assigned_by [12]`
- `timekeeping_employees.default_equipment [14]`
- `timekeeping_employees.linked_profile_id [15]`
- `timekeeping_entries.entry_kind [22]`
- `timekeeping_entries.equipment_not_used [21]`
- `timekeeping_entries.equipment_used [20]`
- `timekeeping_entries.labor_code [23]`
- `timekeeping_entries.lunch_minutes [18]`
- `timekeeping_entries.per_diem [19]`
- `timekeeping_entries.start_time [16]`
- `timekeeping_entries.stop_time [17]`
- `timekeeping_entry_history.equipment_not_used [23]`
- `timekeeping_entry_history.equipment_used [22]`
- `timekeeping_entry_history.lunch_minutes [20]`
- `timekeeping_entry_history.per_diem [21]`
- `timekeeping_entry_history.start_time [18]`
- `timekeeping_entry_history.stop_time [19]`
- `timekeeping_equipment.active [5]`
- `timekeeping_equipment.company_id [2]`
- `timekeeping_equipment.created_at [7]`
- `timekeeping_equipment.created_by [6]`
- `timekeeping_equipment.description [4]`
- `timekeeping_equipment.id [1]`
- `timekeeping_equipment.unit_number [3]`
- `timekeeping_equipment.updated_at [8]`
- `training_progress.company_id [1]`
- `training_progress.completed_at [5]`
- `training_progress.last_position_seconds [6]`
- `training_progress.started_at [4]`
- `training_progress.updated_at [7]`
- `training_progress.user_id [2]`
- `training_progress.video_id [3]`
- `training_videos.active [10]`
- `training_videos.category [5]`
- `training_videos.created_at [11]`
- `training_videos.description [4]`
- `training_videos.duration_seconds [8]`
- `training_videos.id [1]`
- `training_videos.minimum_role [9]`
- `training_videos.slug [2]`
- `training_videos.sort_order [6]`
- `training_videos.storage_path [7]`
- `training_videos.title [3]`
- `training_videos.updated_at [12]`
- `user_dashboard_preferences.company_id [2]`
- `user_dashboard_preferences.tile_order [3]`
- `user_dashboard_preferences.updated_at [4]`
- `user_dashboard_preferences.user_id [1]`
- `utility_packet_unit_aliases.company_id [2]`
- `utility_packet_unit_aliases.contract_id [3]`
- `utility_packet_unit_aliases.created_at [10]`
- `utility_packet_unit_aliases.created_by [8]`
- `utility_packet_unit_aliases.id [1]`
- `utility_packet_unit_aliases.normalized_code [5]`
- `utility_packet_unit_aliases.normalized_target [7]`
- `utility_packet_unit_aliases.packet_code [4]`
- `utility_packet_unit_aliases.target_item_code [6]`
- `utility_packet_unit_aliases.updated_at [11]`
- `utility_packet_unit_aliases.updated_by [9]`

### Changed definitions

- `timekeeping_entries.job_id [5]`

## Constraints

- Test count: 302
- Production count: 391
- Expected test-only portal entries: 31
- Other test-only entries: 0
- Production-only entries: 120
- Same-key definitions that differ: 1

### Expected test-only portal entries

- `customers :: customers_utility_organization_id_fkey`
- `utility_activity_log :: utility_activity_log_action_valid`
- `utility_activity_log :: utility_activity_log_actor_user_id_fkey`
- `utility_activity_log :: utility_activity_log_company_id_fkey`
- `utility_activity_log :: utility_activity_log_contract_id_fkey`
- `utility_activity_log :: utility_activity_log_detail_object`
- `utility_activity_log :: utility_activity_log_job_id_fkey`
- `utility_activity_log :: utility_activity_log_pkey`
- `utility_activity_log :: utility_activity_log_utility_organization_id_fkey`
- `utility_activity_log :: utility_activity_log_utility_user_id_fkey`
- `utility_contract_access :: utility_contract_access_company_id_fkey`
- `utility_contract_access :: utility_contract_access_contract_id_fkey`
- `utility_contract_access :: utility_contract_access_granted_by_fkey`
- `utility_contract_access :: utility_contract_access_pkey`
- `utility_contract_access :: utility_contract_access_revoked_by_fkey`
- `utility_contract_access :: utility_contract_access_status_valid`
- `utility_contract_access :: utility_contract_access_utility_organization_id_fkey`
- `utility_organizations :: utility_organizations_created_by_fkey`
- `utility_organizations :: utility_organizations_name_valid`
- `utility_organizations :: utility_organizations_pkey`
- `utility_portal_feature_flags :: utility_portal_feature_flags_company_id_fkey`
- `utility_portal_feature_flags :: utility_portal_feature_flags_created_by_fkey`
- `utility_portal_feature_flags :: utility_portal_feature_flags_pkey`
- `utility_portal_feature_flags :: utility_portal_feature_flags_updated_by_fkey`
- `utility_users :: utility_users_active_identity_valid`
- `utility_users :: utility_users_email_normalized`
- `utility_users :: utility_users_pkey`
- `utility_users :: utility_users_status_valid`
- `utility_users :: utility_users_token_hash_valid`
- `utility_users :: utility_users_user_id_fkey`
- `utility_users :: utility_users_utility_organization_id_fkey`

### Production-only entries

- `app_error_events :: app_error_events_company_id_fkey`
- `app_error_events :: app_error_events_pkey`
- `app_error_events :: app_error_events_user_id_fkey`
- `assistant_memories :: assistant_memories_company_id_fkey`
- `assistant_memories :: assistant_memories_completed_by_fkey`
- `assistant_memories :: assistant_memories_created_by_fkey`
- `assistant_memories :: assistant_memories_instruction_check`
- `assistant_memories :: assistant_memories_job_id_fkey`
- `assistant_memories :: assistant_memories_memory_type_check`
- `assistant_memories :: assistant_memories_pkey`
- `assistant_memories :: assistant_memories_removed_by_fkey`
- `assistant_memories :: assistant_memories_title_check`
- `assistant_memories :: assistant_memories_trigger_type_check`
- `assistant_memories :: assistant_memory_job_scope`
- `assistant_memories :: assistant_memory_terminal_state`
- `billing_export_attachments :: billing_export_attachments_billing_batch_id_fkey`
- `billing_export_attachments :: billing_export_attachments_company_id_fkey`
- `billing_export_attachments :: billing_export_attachments_pkey`
- `billing_export_attachments :: billing_export_attachments_storage_path_key`
- `billing_export_attachments :: billing_export_attachments_uploaded_by_fkey`
- `billing_export_batches :: billing_export_batches_archived_by_fkey`
- `billing_export_batches :: billing_export_batches_company_id_batch_number_key`
- `billing_export_batches :: billing_export_batches_company_id_fkey`
- `billing_export_batches :: billing_export_batches_created_by_fkey`
- `billing_export_batches :: billing_export_batches_job_id_fkey`
- `billing_export_batches :: billing_export_batches_parent_batch_id_fkey`
- `billing_export_batches :: billing_export_batches_pkey`
- `billing_export_batches :: billing_export_batches_status_check`
- `billing_export_batches :: billing_export_batches_type_check`
- `billing_export_batches :: billing_export_batches_updated_by_fkey`
- `billing_export_lines :: billing_export_lines_authorization_status_check`
- `billing_export_lines :: billing_export_lines_billing_batch_id_fkey`
- `billing_export_lines :: billing_export_lines_company_id_fkey`
- `billing_export_lines :: billing_export_lines_daily_report_id_fkey`
- `billing_export_lines :: billing_export_lines_job_id_fkey`
- `billing_export_lines :: billing_export_lines_pkey`
- `billing_export_lines :: billing_export_lines_price_book_item_id_fkey`
- `billing_export_lines :: billing_export_lines_production_location_id_fkey`
- `billing_export_lines :: billing_export_lines_quantity_check`
- `billing_export_lines :: billing_export_lines_work_type_check`
- `companies :: companies_required_man_hour_rate_valid`
- `job_assignment_audit_events :: job_assignment_audit_events_action_check`
- `job_assignment_audit_events :: job_assignment_audit_events_actor_id_fkey`
- `job_assignment_audit_events :: job_assignment_audit_events_company_id_fkey`
- `job_assignment_audit_events :: job_assignment_audit_events_job_id_fkey`
- `job_assignment_audit_events :: job_assignment_audit_events_member_id_fkey`
- `job_assignment_audit_events :: job_assignment_audit_events_pkey`
- `job_closeout_history :: job_closeout_history_action_check`
- `job_closeout_history :: job_closeout_history_actor_id_fkey`
- `job_closeout_history :: job_closeout_history_company_id_fkey`
- `job_closeout_history :: job_closeout_history_job_id_fkey`
- `job_closeout_history :: job_closeout_history_pkey`
- `jobs :: jobs_closed_by_fkey`
- `jobs :: jobs_reopened_by_fkey`
- `pilot_feedback :: pilot_feedback_category_supported`
- `pilot_feedback :: pilot_feedback_company_id_fkey`
- `pilot_feedback :: pilot_feedback_message_length`
- `pilot_feedback :: pilot_feedback_pkey`
- `pilot_feedback :: pilot_feedback_rating_supported`
- `pilot_feedback :: pilot_feedback_resolved_by_fkey`
- `pilot_feedback :: pilot_feedback_submitted_by_fkey`
- `price_book_items :: price_book_items_transfer_price_nonnegative`
- `push_notification_outbox :: push_notification_outbox_attempt_count_check`
- `push_notification_outbox :: push_notification_outbox_company_id_fkey`
- `push_notification_outbox :: push_notification_outbox_event_key_key`
- `push_notification_outbox :: push_notification_outbox_pkey`
- `push_notification_outbox :: push_notification_outbox_recipient_id_fkey`
- `push_notification_outbox :: push_notification_outbox_status_check`
- `push_notification_preferences :: push_notification_preferences_company_id_fkey`
- `push_notification_preferences :: push_notification_preferences_gf_delivery_mode_check`
- `push_notification_preferences :: push_notification_preferences_pkey`
- `push_notification_preferences :: push_notification_preferences_user_id_fkey`
- `push_subscriptions :: push_subscriptions_company_id_fkey`
- `push_subscriptions :: push_subscriptions_endpoint_unique`
- `push_subscriptions :: push_subscriptions_pkey`
- `push_subscriptions :: push_subscriptions_user_id_fkey`
- `support_access_requests :: support_access_requests_approved_by_fkey`
- `support_access_requests :: support_access_requests_company_id_fkey`
- `support_access_requests :: support_access_requests_pkey`
- `support_access_requests :: support_access_requests_reason_check`
- `support_access_requests :: support_access_requests_requested_minutes_check`
- `support_access_requests :: support_access_requests_revoked_by_fkey`
- `support_access_requests :: support_access_requests_status_check`
- `support_access_requests :: support_access_requests_support_user_id_fkey`
- `support_audit_events :: support_audit_events_actor_id_fkey`
- `support_audit_events :: support_audit_events_company_id_fkey`
- `support_audit_events :: support_audit_events_pkey`
- `support_audit_events :: support_audit_events_request_id_fkey`
- `timekeeping_employees :: timekeeping_employees_admin_assigned_by_fkey`
- `timekeeping_employees :: timekeeping_employees_assigned_admin_id_fkey`
- `timekeeping_employees :: timekeeping_employees_assigned_by_fkey`
- `timekeeping_employees :: timekeeping_employees_linked_profile_id_fkey`
- `timekeeping_entries :: timekeeping_entries_charge_check`
- `timekeeping_entries :: timekeeping_entries_entry_kind_check`
- `timekeeping_entries :: timekeeping_entries_lunch_minutes_check`
- `timekeeping_entry_history :: timekeeping_entry_history_lunch_minutes_check`
- `timekeeping_equipment :: timekeeping_equipment_company_id_fkey`
- `timekeeping_equipment :: timekeeping_equipment_company_id_unit_number_key`
- `timekeeping_equipment :: timekeeping_equipment_pkey`
- `training_progress :: training_progress_company_id_fkey`
- `training_progress :: training_progress_pkey`
- `training_progress :: training_progress_user_id_fkey`
- `training_progress :: training_progress_video_id_fkey`
- `training_videos :: training_video_role_supported`
- `training_videos :: training_videos_pkey`
- `training_videos :: training_videos_slug_key`
- `training_videos :: training_videos_storage_path_key`
- `user_dashboard_preferences :: user_dashboard_preferences_company_id_fkey`
- `user_dashboard_preferences :: user_dashboard_preferences_pkey`
- `user_dashboard_preferences :: user_dashboard_preferences_tile_limit`
- `user_dashboard_preferences :: user_dashboard_preferences_user_id_fkey`
- `utility_packet_unit_aliases :: utility_packet_unit_aliases_company_id_fkey`
- `utility_packet_unit_aliases :: utility_packet_unit_aliases_contract_id_fkey`
- `utility_packet_unit_aliases :: utility_packet_unit_aliases_created_by_fkey`
- `utility_packet_unit_aliases :: utility_packet_unit_aliases_normalized_check`
- `utility_packet_unit_aliases :: utility_packet_unit_aliases_packet_code_check`
- `utility_packet_unit_aliases :: utility_packet_unit_aliases_pkey`
- `utility_packet_unit_aliases :: utility_packet_unit_aliases_target_code_check`
- `utility_packet_unit_aliases :: utility_packet_unit_aliases_unique`
- `utility_packet_unit_aliases :: utility_packet_unit_aliases_updated_by_fkey`

### Changed definitions

- `utility_packet_import_rows :: utility_packet_import_rows_type_check`

## Indexes

- Test count: 159
- Production count: 298
- Expected test-only portal entries: 17
- Other test-only entries: 3
- Production-only entries: 159
- Same-key definitions that differ: 0

### Expected test-only portal entries

- `public.customers :: customers_utility_organization_id_idx`
- `public.utility_activity_log :: utility_activity_log_company_created_idx`
- `public.utility_activity_log :: utility_activity_log_job_id_idx`
- `public.utility_activity_log :: utility_activity_log_org_created_idx`
- `public.utility_activity_log :: utility_activity_log_pkey`
- `public.utility_contract_access :: utility_contract_access_active_uidx`
- `public.utility_contract_access :: utility_contract_access_company_id_idx`
- `public.utility_contract_access :: utility_contract_access_contract_id_idx`
- `public.utility_contract_access :: utility_contract_access_org_id_idx`
- `public.utility_contract_access :: utility_contract_access_pkey`
- `public.utility_organizations :: utility_organizations_pkey`
- `public.utility_portal_feature_flags :: utility_portal_feature_flags_company_uidx`
- `public.utility_portal_feature_flags :: utility_portal_feature_flags_global_uidx`
- `public.utility_portal_feature_flags :: utility_portal_feature_flags_pkey`
- `public.utility_users :: utility_users_org_email_uidx`
- `public.utility_users :: utility_users_pkey`
- `public.utility_users :: utility_users_user_id_uidx`

### Other test-only entries

- `public.daily_reports :: idx_reports_company`
- `public.daily_reports :: idx_reports_foreman`
- `public.daily_reports :: idx_reports_job`

### Production-only entries

- `public.app_error_events :: app_error_events_company_created_idx`
- `public.app_error_events :: app_error_events_pkey`
- `public.app_error_events :: app_error_events_user_id_idx`
- `public.assistant_memories :: assistant_memories_company_active_trigger_idx`
- `public.assistant_memories :: assistant_memories_completed_by_idx`
- `public.assistant_memories :: assistant_memories_created_by_idx`
- `public.assistant_memories :: assistant_memories_job_active_idx`
- `public.assistant_memories :: assistant_memories_pkey`
- `public.assistant_memories :: assistant_memories_removed_by_idx`
- `public.audit_log :: audit_log_company_id_idx`
- `public.audit_log :: audit_log_user_id_idx`
- `public.billing_events :: billing_events_company_id_idx`
- `public.billing_export_attachments :: billing_export_attachments_batch_idx`
- `public.billing_export_attachments :: billing_export_attachments_billing_batch_id_idx`
- `public.billing_export_attachments :: billing_export_attachments_pkey`
- `public.billing_export_attachments :: billing_export_attachments_storage_path_key`
- `public.billing_export_attachments :: billing_export_attachments_uploaded_by_idx`
- `public.billing_export_batches :: billing_export_batches_archived_by_idx`
- `public.billing_export_batches :: billing_export_batches_company_archive_idx`
- `public.billing_export_batches :: billing_export_batches_company_created_idx`
- `public.billing_export_batches :: billing_export_batches_company_id_batch_number_key`
- `public.billing_export_batches :: billing_export_batches_created_by_idx`
- `public.billing_export_batches :: billing_export_batches_job_id_idx`
- `public.billing_export_batches :: billing_export_batches_parent_batch_id_idx`
- `public.billing_export_batches :: billing_export_batches_pkey`
- `public.billing_export_batches :: billing_export_batches_updated_by_idx`
- `public.billing_export_lines :: billing_export_lines_active_source_action_uidx`
- `public.billing_export_lines :: billing_export_lines_batch_idx`
- `public.billing_export_lines :: billing_export_lines_daily_report_id_idx`
- `public.billing_export_lines :: billing_export_lines_job_id_idx`
- `public.billing_export_lines :: billing_export_lines_pkey`
- `public.billing_export_lines :: billing_export_lines_price_book_item_id_idx`
- `public.billing_export_lines :: billing_export_lines_production_location_id_idx`
- `public.companies :: companies_created_by_idx`
- `public.contract_field_settings :: contract_field_settings_company_id_idx`
- `public.contract_field_settings :: contract_field_settings_updated_by_idx`
- `public.crews :: crews_company_id_idx`
- `public.crews :: crews_foreman_id_idx`
- `public.daily_production_items :: daily_production_items_created_by_idx`
- `public.daily_production_unit_locations :: daily_production_unit_locations_created_by_idx`
- `public.daily_production_unit_locations :: daily_production_unit_locations_daily_production_unit_id_idx`
- `public.daily_production_unit_locations :: daily_production_unit_locations_price_book_item_id_idx`
- `public.daily_production_units :: daily_production_units_contract_id_idx`
- `public.daily_production_units :: daily_production_units_created_by_idx`
- `public.daily_production_units :: daily_production_units_job_id_idx`
- `public.daily_production_units :: daily_production_units_price_book_id_idx`
- `public.daily_production_units :: daily_production_units_price_book_item_id_idx`
- `public.daily_report_attachments :: daily_report_attachments_daily_report_id_idx`
- `public.daily_report_attachments :: daily_report_attachments_uploaded_by_idx`
- `public.daily_report_audit_events :: daily_report_audit_events_actor_id_idx`
- `public.daily_report_jsas :: daily_report_jsas_created_by_idx`
- `public.daily_report_jsas :: daily_report_jsas_job_id_idx`
- `public.daily_reports :: daily_reports_approved_by_idx`
- `public.daily_reports :: daily_reports_created_by_idx`
- `public.daily_reports :: daily_reports_crew_id_idx`
- `public.daily_reports :: daily_reports_price_book_id_idx`
- `public.daily_reports :: daily_reports_redline_override_by_idx`
- `public.daily_reports :: daily_reports_reviewed_by_idx`
- `public.employees :: employees_company_id_idx`
- `public.employees :: employees_crew_id_idx`
- `public.gf_foreman_assignments :: gf_foreman_assignments_created_by_idx`
- `public.gf_foreman_assignments :: gf_foreman_assignments_foreman_id_idx`
- `public.gf_foreman_assignments :: gf_foreman_assignments_gf_id_idx`
- `public.job_assignment_audit_events :: job_assignment_audit_company_job_idx`
- `public.job_assignment_audit_events :: job_assignment_audit_company_member_idx`
- `public.job_assignment_audit_events :: job_assignment_audit_events_actor_id_idx`
- `public.job_assignment_audit_events :: job_assignment_audit_events_job_id_idx`
- `public.job_assignment_audit_events :: job_assignment_audit_events_member_id_idx`
- `public.job_assignment_audit_events :: job_assignment_audit_events_pkey`
- `public.job_closeout_history :: job_closeout_history_actor_id_idx`
- `public.job_closeout_history :: job_closeout_history_company_time_idx`
- `public.job_closeout_history :: job_closeout_history_job_time_idx`
- `public.job_closeout_history :: job_closeout_history_pkey`
- `public.job_leader_assignments :: job_leader_assignments_assigned_by_idx`
- `public.job_leader_assignments :: job_leader_assignments_member_id_idx`
- `public.job_package_authorized_units :: job_package_authorized_units_created_by_idx`
- `public.job_package_authorized_units :: job_package_authorized_units_job_package_id_idx`
- `public.job_package_authorized_units :: job_package_authorized_units_price_book_item_id_idx`
- `public.job_package_work_points :: job_package_work_points_created_by_idx`
- `public.job_package_work_points :: job_package_work_points_job_id_idx`
- `public.job_package_work_points :: job_package_work_points_package_canonical_key_idx`
- `public.job_packages :: job_packages_contract_id_idx`
- `public.job_packages :: job_packages_created_by_idx`
- `public.job_packages :: job_packages_job_id_idx`
- `public.job_packages :: job_packages_supersedes_package_id_idx`
- `public.jobs :: jobs_closed_by_idx`
- `public.jobs :: jobs_created_by_idx`
- `public.jobs :: jobs_reopened_by_idx`
- `public.jsa_upload_attachments :: jsa_upload_attachments_uploaded_by_idx`
- `public.pilot_feedback :: pilot_feedback_company_created_idx`
- `public.pilot_feedback :: pilot_feedback_pkey`
- `public.pilot_feedback :: pilot_feedback_resolved_by_idx`
- `public.pilot_feedback :: pilot_feedback_submitted_by_idx`
- `public.pilot_feedback :: pilot_feedback_unresolved_idx`
- `public.platform_owner_audit_events :: platform_owner_audit_events_actor_user_id_idx`
- `public.platform_owners :: platform_owners_created_by_idx`
- `public.price_book_items :: price_book_items_book_code_unique`
- `public.price_books :: price_books_created_by_idx`
- `public.profiles :: profiles_one_owner_per_company_idx`
- `public.push_notification_outbox :: push_notification_outbox_event_key_key`
- `public.push_notification_outbox :: push_notification_outbox_pending_idx`
- `public.push_notification_outbox :: push_notification_outbox_pkey`
- `public.push_notification_preferences :: push_notification_preferences_pkey`
- `public.push_subscriptions :: push_subscriptions_company_idx`
- `public.push_subscriptions :: push_subscriptions_endpoint_unique`
- `public.push_subscriptions :: push_subscriptions_pkey`
- `public.push_subscriptions :: push_subscriptions_user_idx`
- `public.storm_mode_assignments :: storm_mode_assignments_assigned_by_idx`
- `public.support_access_requests :: support_access_requests_approved_by_idx`
- `public.support_access_requests :: support_access_requests_company_status_idx`
- `public.support_access_requests :: support_access_requests_operator_idx`
- `public.support_access_requests :: support_access_requests_pkey`
- `public.support_access_requests :: support_access_requests_revoked_by_idx`
- `public.support_audit_events :: support_audit_events_actor_id_idx`
- `public.support_audit_events :: support_audit_events_company_created_idx`
- `public.support_audit_events :: support_audit_events_pkey`
- `public.support_audit_events :: support_audit_events_request_id_idx`
- `public.team_invitations :: team_invitations_accepted_by_idx`
- `public.team_invitations :: team_invitations_invited_by_idx`
- `public.timekeeping_edit_audit :: timekeeping_edit_audit_daily_report_id_idx`
- `public.timekeeping_edit_audit :: timekeeping_edit_audit_edited_by_idx`
- `public.timekeeping_edit_audit :: timekeeping_edit_audit_employee_id_idx`
- `public.timekeeping_employees :: timekeeping_employees_admin_assigned_by_idx`
- `public.timekeeping_employees :: timekeeping_employees_assigned_admin_id_idx`
- `public.timekeeping_employees :: timekeeping_employees_assigned_admin_idx`
- `public.timekeeping_employees :: timekeeping_employees_assigned_by_idx`
- `public.timekeeping_employees :: timekeeping_employees_assigned_foreman_id_idx`
- `public.timekeeping_employees :: timekeeping_employees_company_linked_profile_uidx`
- `public.timekeeping_employees :: timekeeping_employees_linked_profile_uidx`
- `public.timekeeping_entries :: timekeeping_entries_employee_id_idx`
- `public.timekeeping_entries :: timekeeping_entries_kind_company_date_idx`
- `public.timekeeping_entries :: timekeeping_entries_leadership_overhead_uidx`
- `public.timekeeping_entry_history :: timekeeping_entry_history_daily_report_id_idx`
- `public.timekeeping_entry_history :: timekeeping_entry_history_employee_id_idx`
- `public.timekeeping_entry_history :: timekeeping_entry_history_job_id_idx`
- `public.timekeeping_equipment :: timekeeping_equipment_company_active_idx`
- `public.timekeeping_equipment :: timekeeping_equipment_company_id_unit_number_key`
- `public.timekeeping_equipment :: timekeeping_equipment_pkey`
- `public.timekeeping_pay_period_audit :: timekeeping_pay_period_audit_actor_id_idx`
- `public.timekeeping_pay_periods :: timekeeping_pay_periods_approved_by_idx`
- `public.timekeeping_pay_periods :: timekeeping_pay_periods_locked_by_idx`
- `public.training_progress :: training_progress_company_id_idx`
- `public.training_progress :: training_progress_pkey`
- `public.training_progress :: training_progress_video_id_idx`
- `public.training_videos :: training_videos_pkey`
- `public.training_videos :: training_videos_slug_key`
- `public.training_videos :: training_videos_storage_path_key`
- `public.user_dashboard_preferences :: user_dashboard_preferences_company_idx`
- `public.user_dashboard_preferences :: user_dashboard_preferences_pkey`
- `public.utility_packet_imports :: utility_packet_imports_created_by_idx`
- `public.utility_packet_imports :: utility_packet_imports_reviewed_by_idx`
- `public.utility_packet_unit_aliases :: utility_packet_unit_aliases_contract_id_idx`
- `public.utility_packet_unit_aliases :: utility_packet_unit_aliases_created_by_idx`
- `public.utility_packet_unit_aliases :: utility_packet_unit_aliases_lookup`
- `public.utility_packet_unit_aliases :: utility_packet_unit_aliases_pkey`
- `public.utility_packet_unit_aliases :: utility_packet_unit_aliases_unique`
- `public.utility_packet_unit_aliases :: utility_packet_unit_aliases_updated_by_idx`
- `public.work_points :: work_points_company_id_idx`
- `public.work_points :: work_points_created_by_idx`

## Triggers

- Test count: 18
- Production count: 32
- Expected test-only portal entries: 4
- Other test-only entries: 1
- Production-only entries: 19
- Same-key definitions that differ: 0

### Expected test-only portal entries

- `public.jobs :: utility_job_contract_visibility_audit`
- `public.profiles :: utility_identity_blocks_profile_id_update`
- `public.profiles :: utility_identity_blocks_profile_insert`
- `public.utility_contract_access :: utility_contract_access_company_match`

### Other test-only entries

- `public.jobs :: linecrew_job_contract_company_match`

### Production-only entries

- `public.daily_production_unit_locations :: enforce_active_job_daily_unit_locations`
- `public.daily_production_units :: enforce_active_job_daily_production_units`
- `public.daily_production_units :: set_daily_production_transfer_price_snapshot`
- `public.daily_report_jsas :: daily_report_jsas_foreman_assigned_job`
- `public.daily_report_jsas :: linecrew_completed_jsa_push`
- `public.daily_reports :: daily_reports_foreman_assigned_job`
- `public.daily_reports :: linecrew_daily_report_push`
- `public.daily_reports :: prevent_duplicate_daily_report`
- `public.job_package_authorized_units :: enforce_draft_job_package_authorized_unit_mutation`
- `public.job_package_work_points :: enforce_draft_job_package_work_point_mutation`
- `public.job_packages :: assign_job_package_revision_trigger`
- `public.job_packages :: prevent_non_draft_job_package_delete`
- `public.job_packages :: supersede_prior_job_package_trigger`
- `public.jsa_upload_attachments :: linecrew_uploaded_jsa_push`
- `public.profiles :: sync_foreman_timekeeping_employee_trigger`
- `public.timekeeping_employees :: validate_timekeeping_employee_admin_assignment`
- `public.timekeeping_employees :: validate_timekeeping_employee_assignment`
- `public.timekeeping_entries :: trg_sync_daily_report_hours_from_timekeeping`
- `public.utility_packet_imports :: activate_finalized_utility_packet_revision_trigger`

## RLS policies

- Test count: 87
- Production count: 111
- Expected test-only portal entries: 8
- Other test-only entries: 34
- Production-only entries: 66
- Same-key definitions that differ: 10

### Expected test-only portal entries

- `public.utility_activity_log :: utility_activity_log_contractor_read`
- `public.utility_contract_access :: utility_contract_access_contractor_read`
- `public.utility_organizations :: utility_organizations_contractor_read`
- `public.utility_portal_feature_flags :: utility_portal_flags_platform_owner_delete`
- `public.utility_portal_feature_flags :: utility_portal_flags_platform_owner_insert`
- `public.utility_portal_feature_flags :: utility_portal_flags_platform_owner_select`
- `public.utility_portal_feature_flags :: utility_portal_flags_platform_owner_update`
- `public.utility_users :: utility_users_contractor_read`

### Other test-only entries

- `public.audit_log :: audit_admin_select`
- `public.companies :: company_admin_update`
- `public.company_settings :: settings_admin_update`
- `public.contracts :: Admins can delete contracts`
- `public.contracts :: Admins can insert contracts`
- `public.contracts :: Admins can update contracts`
- `public.contracts :: Company members can view contracts`
- `public.crews :: crews_admin_gf_insert`
- `public.crews :: crews_admin_gf_update`
- `public.customers :: Admins can delete customers`
- `public.customers :: Admins can insert customers`
- `public.customers :: Admins can update customers`
- `public.customers :: Company members can view customers`
- `public.daily_production_items :: Admins can delete production items`
- `public.daily_reports :: company members read daily reports`
- `public.daily_reports :: reports_admin_gf_delete`
- `public.daily_reports :: reports_admin_gf_update`
- `public.daily_reports :: reports_company_select`
- `public.employees :: employees_admin_gf_manage`
- `public.job_leader_assignments :: job_leader_assignments_same_company_select`
- `public.jobs :: jobs_admin_gf_manage`
- `public.jobs :: jobs_same_company_select`
- `public.price_book_items :: Admins can delete price book items`
- `public.price_book_items :: Admins can insert price book items`
- `public.price_book_items :: Admins can update price book items`
- `public.price_books :: price_books_admin_manage`
- `public.profiles :: profiles_admin_update`
- `public.report_units :: report_units_admin_gf_delete`
- `public.report_units :: report_units_admin_gf_update`
- `public.timekeeping_employees :: timekeeping_employees_manage_leaders`
- `public.timekeeping_employees :: timekeeping_employees_select_company`
- `public.timekeeping_entries :: timekeeping_entries_insert_company`
- `public.timekeeping_entries :: timekeeping_entries_update_company`
- `public.unit_prices :: unit_prices_admin_manage`

### Production-only entries

- `public.app_error_events :: server_only_no_direct_access`
- `public.assistant_memories :: assistant_memories_owner_admin_select`
- `public.audit_log :: audit_leadership_select`
- `public.billing_export_attachments :: server_only_no_direct_access`
- `public.billing_export_batches :: server_only_no_direct_access`
- `public.billing_export_lines :: server_only_no_direct_access`
- `public.companies :: company_leadership_update`
- `public.company_settings :: settings_leadership_update`
- `public.contracts :: contracts_company_select`
- `public.contracts :: contracts_leadership_delete`
- `public.contracts :: contracts_leadership_insert`
- `public.contracts :: contracts_leadership_update`
- `public.crews :: crews_leadership_insert`
- `public.crews :: crews_leadership_update`
- `public.crews :: crews_owner_delete`
- `public.customers :: customers_company_select`
- `public.customers :: customers_leadership_delete`
- `public.customers :: customers_leadership_insert`
- `public.customers :: customers_leadership_update`
- `public.daily_production_items :: production_items_leadership_delete`
- `public.daily_reports :: daily_reports_leadership_delete`
- `public.daily_reports :: daily_reports_leadership_update`
- `public.daily_reports :: daily_reports_role_scoped_select`
- `public.employees :: employees_leadership_delete`
- `public.employees :: employees_leadership_insert`
- `public.employees :: employees_leadership_update`
- `public.job_assignment_audit_events :: server_only_no_direct_access`
- `public.job_closeout_history :: server_only_no_direct_access`
- `public.job_leader_assignments :: job_leader_assignments_role_scoped_select`
- `public.jobs :: jobs_leadership_delete`
- `public.jobs :: jobs_leadership_insert`
- `public.jobs :: jobs_leadership_update`
- `public.jobs :: jobs_role_scoped_select`
- `public.pilot_feedback :: server_only_no_direct_access`
- `public.platform_support_users :: server_only_no_direct_access`
- `public.price_book_items :: price_book_items_leadership_delete`
- `public.price_book_items :: price_book_items_leadership_insert`
- `public.price_book_items :: price_book_items_leadership_update`
- `public.price_books :: price_books_leadership_delete`
- `public.price_books :: price_books_leadership_insert`
- `public.price_books :: price_books_leadership_update`
- `public.report_units :: report_units_leadership_delete`
- `public.report_units :: report_units_leadership_update`
- `public.support_access_requests :: server_only_no_direct_access`
- `public.support_audit_events :: server_only_no_direct_access`
- `public.team_invitations :: server_only_no_direct_access`
- `public.timekeeping_employees :: timekeeping_employees_leadership_delete`
- `public.timekeeping_employees :: timekeeping_employees_leadership_insert`
- `public.timekeeping_employees :: timekeeping_employees_leadership_update`
- `public.timekeeping_employees :: timekeeping_employees_role_scoped_select`
- `public.timekeeping_entries :: timekeeping_entries_role_scoped_insert`
- `public.timekeeping_entries :: timekeeping_entries_role_scoped_update`
- `public.timekeeping_equipment :: timekeeping_equipment_admin_delete`
- `public.timekeeping_equipment :: timekeeping_equipment_admin_insert`
- `public.timekeeping_equipment :: timekeeping_equipment_admin_update`
- `public.timekeeping_equipment :: timekeeping_equipment_company_select`
- `public.training_progress :: training_progress_read_own_company`
- `public.training_progress :: training_progress_update_own`
- `public.training_progress :: training_progress_write_own`
- `public.training_videos :: training_videos_subscriber_read`
- `public.unit_prices :: unit_prices_leadership_delete`
- `public.unit_prices :: unit_prices_leadership_insert`
- `public.unit_prices :: unit_prices_leadership_update`
- `public.user_dashboard_preferences :: user_dashboard_preferences_insert_own`
- `public.user_dashboard_preferences :: user_dashboard_preferences_select_own`
- `public.user_dashboard_preferences :: user_dashboard_preferences_update_own`

### Changed definitions

- `public.companies :: company_same_company_select`
- `public.daily_report_jsas :: daily_report_jsas_role_scoped_select`
- `public.daily_reports :: reports_foreman_insert`
- `public.jsa_upload_attachments :: jsa attachment role scoped read`
- `public.profiles :: profiles_same_company_select`
- `public.timekeeping_entries :: timekeeping_entries_delete_company`
- `public.timekeeping_entries :: timekeeping_entries_select_company`
- `public.timekeeping_entry_history :: timekeeping_entry_history_select_company`
- `public.timekeeping_pay_period_audit :: timekeeping_pay_period_audit_select_company`
- `public.timekeeping_pay_periods :: timekeeping_pay_periods_select_company`

## Classification and required action

1. The Utility Portal tables, helpers, RPCs, policies, indexes, and triggers are expected test-only differences while the feature remains unpromoted.
2. The restored `linecrew_report_counts_toward_progress` signature now matches production. Its body is intentionally not used by Utility Portal RPCs.
3. Every production-only entry, every non-portal test-only entry, and every changed same-key definition remains unresolved drift. These require parity migrations or an explicit written justification before Section 13 testing.
4. The quantity-only Utility Portal progress rewrite is complete locally but has not been applied or runtime-tested against the drifted test project.
5. `my_company_subscription_access()` has an existing ACL/caller inconsistency outside Utility Portal scope. The production baseline grants it only to `service_role`, while the current test project and three repository callers assume authenticated execution. The entitlement-extraction migration deliberately uses `CREATE OR REPLACE` without changing the existing ACL. Resolving the dead production Pilot-checklist caller and drift-dependent billing tests requires a separate billing change before the test schema is rebuilt.
