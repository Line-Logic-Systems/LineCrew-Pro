import fs from 'node:fs';

const failures = [];
const assert = (condition, message) => { if (!condition) failures.push(message); };
const hasVersionedAsset = (source, assetName) => {
  const escapedName = assetName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return new RegExp(`${escapedName}\\?v=[A-Za-z0-9._-]+`).test(source);
};
const sourceBetween = (source, startMarker, endMarker) => {
  const start = source.indexOf(startMarker);
  if (start < 0) return '';
  const end = source.indexOf(endMarker, start + startMarker.length);
  return end > start ? source.slice(start, end) : '';
};

const mustExist = [
  'index.html',
  'support.html',
  'vercel.json',
  'scripts/validate-app.mjs',
  'supabase/functions/linecrew-assistant/index.ts',
  'scripts/validate-assistant-memory.mjs',
  'supabase/migrations/archive/20260830174354_assistant_memory_reminders.sql',
  'supabase/migrations/archive/20260830175934_index_assistant_memory_foreign_keys.sql',
  'supabase/functions/send-team-invitation/index.ts',
  'supabase/functions/notify-pilot-feedback/index.ts',
  'supabase/functions/complete-team-invitation-signup/index.ts',
  'supabase/functions/_shared/api-keys.ts',
  'supabase/functions/_shared/api-keys_test.ts',
  'supabase/functions/send-push-notification/index.ts',
  'supabase/migrations/20260903023149_push_subscriptions.sql',
  'supabase/migrations/archive/20260818_owner_superintendent_roles.sql',
  'supabase/migrations/archive/20260818_owner_superintendent_team_access.sql',
  'supabase/migrations/archive/202608190100_owner_legacy_compatibility.sql',
  'supabase/migrations/archive/202608190200_superintendent_legacy_compatibility.sql',
  'supabase/migrations/archive/20260822220000_production_role_compatibility_drift_repair.sql',
  'supabase/migrations/archive/20260822223611_close_post_fix_rpc_access_gaps.sql',
  'supabase/migrations/archive/20260823004222_superintendent_customers_contracts_policies.sql',
  'supabase/migrations/archive/20260823015316_one_click_company_invitations.sql',
  'supabase/migrations/archive/20260823021011_automate_invited_foreman_signup.sql',
  'supabase/migrations/archive/20260823023639_restrict_foremen_to_assigned_jobs.sql',
  'supabase/migrations/archive/20260823024700_show_job_assignees_to_supervisors.sql',
  'supabase/migrations/archive/20260823030000_company_employee_roster_assignment.sql',
  'supabase/migrations/archive/20260823051008_allow_foreman_delete_own_draft_reports.sql',
  'supabase/migrations/archive/20260823053000_add_company_man_hour_rate_target.sql',
  'supabase/migrations/archive/20260824060308_restrict_daily_report_reads_by_role.sql',
  'supabase/migrations/archive/20260824063000_enforce_privileged_mfa_server_side.sql',
  'supabase/migrations/archive/20260824190000_enforce_privileged_mfa_without_deadline.sql',
  'supabase/migrations/archive/20260824070000_append_only_job_closeout_history.sql',
  'supabase/migrations/archive/20260824071000_daily_report_scale_and_integrity.sql',
  'supabase/migrations/archive/20260825143000_harden_report_and_final_billing_controls.sql',
  'supabase/migrations/archive/20260825150000_close_direct_rest_authorization_gaps.sql',
  'supabase/migrations/archive/20260825151500_dynamic_backup_table_inventory.sql',
  'supabase/migrations/archive/20260825152000_restore_owner_job_rpc_access.sql',
  'number-input-polish.js',
  'foreman-field-tools.js',
  'leadership-my-time.js',
  'scripts/validate-leadership-self-time.mjs',
  'supabase/migrations/archive/20260828172839_leadership_self_time.sql',
  'supabase/migrations/archive/20260828173009_consolidate_leadership_self_time_policies.sql',
  'supabase/migrations/archive/20260826234242_foreman_remaining_job_units.sql',
  'supabase/migrations/archive/20260827120000_fix_remaining_units_job_scope.sql',
  'supabase/migrations/archive/20260901030000_job_jacket_end_to_end_integrity.sql',
  'supabase/migrations/archive/20260901031500_job_jacket_reimport_and_revision_delta.sql',
  'supabase/migrations/archive/20260901045812_optimize_job_packet_review_import.sql',
  'supabase/migrations/archive/20260901055156_admin_promotion_and_single_owner_governance.sql',
  'supabase/migrations/archive/20260901070000_member_money_visibility.sql',
  'supabase/migrations/archive/20260901071000_fix_member_money_permission_update.sql',
  'supabase/migrations/archive/20260901072000_preserve_field_role_money_permissions.sql',
  'supabase/migrations/archive/20260901073000_mask_detailed_field_money.sql',
  'supabase/migrations/archive/20260901074000_admin_owner_recovery.sql',
  'scripts/generate-production-drift-repair.mjs',
  'scripts/verify-production-schema.sql',
  'scripts/post-restore-security.sql',
  'scripts/verify-post-restore-security.sql',
  'scripts/test-post-restore-security-gate.sh',
  'scripts/verify-restored-managed-counts.mjs'
];
for (const file of mustExist) assert(fs.existsSync(file), `Missing ${file}`);

const index = fs.readFileSync('index.html', 'utf8');
const support = fs.readFileSync('support.html', 'utf8');
const vercel = JSON.parse(fs.readFileSync('vercel.json', 'utf8'));
const assistant = fs.readFileSync('supabase/functions/linecrew-assistant/index.ts', 'utf8');
const teamInvitation = fs.readFileSync('supabase/functions/send-team-invitation/index.ts', 'utf8');
const pilotFeedbackNotifier = fs.readFileSync('supabase/functions/notify-pilot-feedback/index.ts', 'utf8');
const invitationSignup = fs.readFileSync('supabase/functions/complete-team-invitation-signup/index.ts', 'utf8');
const edgeApiKeys = fs.readFileSync('supabase/functions/_shared/api-keys.ts', 'utf8');
const pushNotifier = fs.readFileSync('supabase/functions/send-push-notification/index.ts', 'utf8');
const pushSubscriptions = fs.readFileSync('supabase/migrations/20260903023149_push_subscriptions.sql', 'utf8');
const pushNotificationPhase2 = fs.readFileSync('supabase/migrations/20260903150000_push_notification_phase_2.sql', 'utf8');
const supabaseConfig = fs.readFileSync('supabase/config.toml', 'utf8');
const roleMigration = fs.readFileSync('supabase/migrations/archive/20260818_owner_superintendent_roles.sql', 'utf8');
const ownerCompat = fs.readFileSync('supabase/migrations/archive/202608190100_owner_legacy_compatibility.sql', 'utf8');
const superintendentCompat = fs.readFileSync('supabase/migrations/archive/202608190200_superintendent_legacy_compatibility.sql', 'utf8');
const driftRepair = fs.readFileSync('supabase/migrations/archive/20260822220000_production_role_compatibility_drift_repair.sql', 'utf8');
const rpcAccessRepair = fs.readFileSync('supabase/migrations/archive/20260822223611_close_post_fix_rpc_access_gaps.sql', 'utf8');
const superintendentContractsPolicies = fs.readFileSync('supabase/migrations/archive/20260823004222_superintendent_customers_contracts_policies.sql', 'utf8');
const companyInvitations = fs.readFileSync('supabase/migrations/archive/20260823015316_one_click_company_invitations.sql', 'utf8');
const automaticInvitationSignup = fs.readFileSync('supabase/migrations/archive/20260823021011_automate_invited_foreman_signup.sql', 'utf8');
const foremanJobAssignments = fs.readFileSync('supabase/migrations/archive/20260823023639_restrict_foremen_to_assigned_jobs.sql', 'utf8');
const supervisorJobAssignees = fs.readFileSync('supabase/migrations/archive/20260823024700_show_job_assignees_to_supervisors.sql', 'utf8');
const employeeRosterAssignment = fs.readFileSync('supabase/migrations/archive/20260823030000_company_employee_roster_assignment.sql', 'utf8');
const foremanDraftDeletion = fs.readFileSync('supabase/migrations/archive/20260823051008_allow_foreman_delete_own_draft_reports.sql', 'utf8');
const manHourRateTarget = fs.readFileSync('supabase/migrations/archive/20260823053000_add_company_man_hour_rate_target.sql', 'utf8');
const dailyReportReadScope = fs.readFileSync('supabase/migrations/archive/20260824060308_restrict_daily_report_reads_by_role.sql', 'utf8');
const privilegedMfaFoundation = fs.readFileSync('supabase/migrations/archive/20260824063000_enforce_privileged_mfa_server_side.sql', 'utf8');
const privilegedMfaServer = fs.readFileSync('supabase/migrations/archive/20260824190000_enforce_privileged_mfa_without_deadline.sql', 'utf8');
const jobCloseoutHistory = fs.readFileSync('supabase/migrations/archive/20260824070000_append_only_job_closeout_history.sql', 'utf8');
const dailyReportScaleIntegrity = fs.readFileSync('supabase/migrations/archive/20260824071000_daily_report_scale_and_integrity.sql', 'utf8');
const reportAndFinalBillingHardening = fs.readFileSync('supabase/migrations/archive/20260825143000_harden_report_and_final_billing_controls.sql', 'utf8');
const directRestHardening = fs.readFileSync('supabase/migrations/archive/20260825150000_close_direct_rest_authorization_gaps.sql', 'utf8');
const dynamicBackupInventory = fs.readFileSync('supabase/migrations/archive/20260825151500_dynamic_backup_table_inventory.sql', 'utf8');
const ownerJobAccess = fs.readFileSync('supabase/migrations/archive/20260825152000_restore_owner_job_rpc_access.sql', 'utf8');
const backupScript = fs.readFileSync('scripts/backup-supabase.mjs', 'utf8');
const numberInputPolish = fs.readFileSync('number-input-polish.js', 'utf8');
const appPolish = fs.readFileSync('app-polish.js', 'utf8');
const packetParser = fs.readFileSync('supabase/functions/parse-utility-job-packet/index.ts', 'utf8');
const expandedJsa = fs.readFileSync('expanded-jsa.js', 'utf8');
const serviceWorker = fs.readFileSync('service-worker.js', 'utf8');
const timekeepingReport = fs.readFileSync('timekeeping-report-v2.js', 'utf8');
const timekeeping = fs.readFileSync('timekeeping.js', 'utf8');
const timekeepingInput = fs.readFileSync('timekeeping-input-v2.js', 'utf8');
const timekeepingRoster = fs.readFileSync('timekeeping-roster.js', 'utf8');
const foremanFieldTools = fs.readFileSync('foreman-field-tools.js', 'utf8');
const remainingUnitsMigration = fs.readFileSync('supabase/migrations/archive/20260827120000_fix_remaining_units_job_scope.sql', 'utf8');
const jobJacketIntegrity = fs.readFileSync('supabase/migrations/archive/20260901030000_job_jacket_end_to_end_integrity.sql', 'utf8');
const jobJacketReimport = fs.readFileSync('supabase/migrations/archive/20260901031500_job_jacket_reimport_and_revision_delta.sql', 'utf8');
const packetTimeoutFix = fs.readFileSync('supabase/migrations/archive/20260901045812_optimize_job_packet_review_import.sql', 'utf8');
const roleGovernance = fs.readFileSync('supabase/migrations/archive/20260901055156_admin_promotion_and_single_owner_governance.sql', 'utf8');
const moneyVisibility = fs.readFileSync('supabase/migrations/archive/20260901070000_member_money_visibility.sql', 'utf8');
const moneyVisibilityUpdateFix = fs.readFileSync('supabase/migrations/archive/20260901071000_fix_member_money_permission_update.sql', 'utf8');
const fieldRoleMoneyPermissions = fs.readFileSync('supabase/migrations/archive/20260901072000_preserve_field_role_money_permissions.sql', 'utf8');
const detailedFieldMoney = fs.readFileSync('supabase/migrations/archive/20260901073000_mask_detailed_field_money.sql', 'utf8');
const adminOwnerRecovery = fs.readFileSync('supabase/migrations/archive/20260901074000_admin_owner_recovery.sql', 'utf8');
const independentBackup = fs.readFileSync('.github/workflows/independent-backup.yml', 'utf8');
const dailyCompanyBackup = fs.readFileSync('.github/workflows/daily-company-data-backup.yml', 'utf8');
const disasterRestoreWorkflow = fs.readFileSync('.github/workflows/test-disaster-restore.yml', 'utf8');
const fullDisasterRestoreWorkflow = fs.readFileSync('.github/workflows/full-disaster-recovery-drill.yml', 'utf8');
const postRestoreSecurity = fs.readFileSync('scripts/post-restore-security.sql', 'utf8');
const verifyPostRestoreSecurity = fs.readFileSync('scripts/verify-post-restore-security.sql', 'utf8');
const verifyProductionSchema = fs.readFileSync('scripts/verify-production-schema.sql', 'utf8');
const testPostRestoreSecurity = fs.readFileSync('scripts/test-post-restore-security-gate.sh', 'utf8');
const restoreBackupStorage = fs.readFileSync('scripts/restore-backup-storage.mjs', 'utf8');
const verifyRestoredTableCounts = fs.readFileSync('scripts/verify-restored-table-counts.mjs', 'utf8');
const verifyRestoredManagedCounts = fs.readFileSync('scripts/verify-restored-managed-counts.mjs', 'utf8');
const testDisasterRestore = fs.readFileSync('scripts/test-disaster-restore.mjs', 'utf8');

for (const marker of [
  'customers_leadership_insert',
  'customers_leadership_update',
  'customers_leadership_delete',
  'contracts_leadership_insert',
  'contracts_leadership_update',
  'contracts_leadership_delete',
  'customer_contract_management_policy_count',
  'customer_contract_management_policies_safe'
]) assert(verifyProductionSchema.includes(marker), `Production schema verifier is stale or missing: ${marker}`);

const vercelText = JSON.stringify(vercel);
for (const header of ['X-Content-Type-Options','X-Frame-Options','Referrer-Policy','X-Robots-Tag','Content-Security-Policy','Strict-Transport-Security']) {
  assert(vercelText.includes(header), `Missing production response header: ${header}`);
}
assert(vercelText.includes("frame-ancestors 'none'"), 'App must prevent framing/clickjacking.');
assert(vercelText.includes('noindex, nofollow'), 'Operational app should not be indexed by search engines.');
assert(
  vercel.headers
    .filter(rule => rule.headers?.some(header => header.key === 'Content-Security-Policy'))
    .every(rule => rule.headers.find(header => header.key === 'Content-Security-Policy').value.includes("connect-src 'self' https://cdn.jsdelivr.net")),
  'Every app CSP must allow the service worker to cache the pinned Supabase runtime from jsDelivr.'
);

const publicSecretPatterns = [
  ['OpenAI secret key', /sk-(?:proj-)?[A-Za-z0-9_-]{20,}/],
  ['Supabase secret key', /sb_secret_[A-Za-z0-9_-]+/i],
  ['Supabase service role JWT marker', /service[_-]?role[^\n]{0,80}eyJ/i],
  ['Private key', /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/]
];
for (const [label, pattern] of publicSecretPatterns) assert(!pattern.test(index), `${label} appears in public index.html`);

for (const marker of [
  'alter table public.push_subscriptions enable row level security',
  'revoke all on public.push_subscriptions from public, anon, authenticated',
  'grant select, update, delete on public.push_subscriptions to service_role',
  'security definer',
  "set search_path to ''",
  'linecrew_save_push_subscription',
  'linecrew_delete_push_subscription',
  'linecrew_my_push_status',
  'on conflict (endpoint) do update',
  'subscription.user_id = v_user_id',
  'grant execute on function public.linecrew_my_push_status() to authenticated'
]) assert(pushSubscriptions.includes(marker), `Push subscription security marker missing: ${marker}`);
for (const marker of [
  'npm:web-push@3.6.7',
  'Deno.env.get("CORS_ALLOWED_ORIGINS")',
  'if (origin && !allowedOrigins.has(origin))',
  'mode === "test"',
  '.eq("user_id", userData.user.id)',
  'request.headers.get("x-push-cron-secret")',
  'status === 404 || status === 410',
  'nextFailureCount > 10',
  'last_success_at: new Date().toISOString()',
  'event: "push_delivery_completed"'
]) assert(pushNotifier.includes(marker), `Push delivery marker missing: ${marker}`);
assert(!pushNotifier.includes('console.log(subscription'), 'Push delivery logs must not expose subscription endpoints or keys.');
for (const marker of [
  'body.dispatch_queued === true',
  'linecrew_enqueue_due_push_reminders',
  'linecrew_enqueue_billing_grace_warnings',
  '.from("push_notification_outbox")',
  'status: "processing"',
  'event: "push_queue_dispatch_completed"'
]) assert(pushNotifier.includes(marker), `Push queue delivery marker missing: ${marker}`);
for (const marker of [
  'alter table public.push_notification_preferences enable row level security',
  'revoke all on public.push_notification_preferences from public, anon, authenticated',
  "default 'submitted_and_reminders'",
  'linecrew_set_my_gf_notification_preference',
  'linecrew_my_gf_notification_preference',
  'linecrew_queue_daily_report_push',
  'linecrew_queue_completed_jsa_push',
  'linecrew_queue_uploaded_jsa_push',
  'linecrew_enqueue_due_push_reminders',
  "assignment.foreman_id = new.foreman_id",
  "assignment.foreman_id = new.created_by",
  "'linecrew-push-dispatch'",
  "where secret.name = 'linecrew_push_cron_secret'",
  "set search_path to