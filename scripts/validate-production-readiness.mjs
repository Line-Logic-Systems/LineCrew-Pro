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
  "set search_path to ''"
]) assert(pushNotificationPhase2.includes(marker), `Phase 2 push marker missing: ${marker}`);
assert(index.includes('id="gfNotificationDeliveryMode"'), 'GF notification preference must be selectable.');
assert(index.includes("sb.rpc('linecrew_set_my_gf_notification_preference'"), 'GF notification preference must be saved through its RPC.');
assert(index.includes('id="dailyReportReminderTime"'), 'Company settings must expose the Daily Report reminder time.');
assert(index.includes('id="jsaReminderTime"'), 'Company settings must expose the JSA reminder time.');
assert(
  /\[functions\.send-push-notification\]\s+verify_jwt = false/.test(supabaseConfig),
  'Push delivery must disable the legacy gateway verifier and authenticate both modes in the handler.'
);

assert(assistant.includes('client.auth.getUser()'), 'AI assistant must authenticate the caller.');
assert(assistant.includes('.select("company_id, role, active")'), 'AI assistant must load role and active status server-side.');
assert(assistant.includes('!["admin", "owner"].includes(role)'), 'AI assistant must reject every role except active Owner/Admin server-side.');
assert(assistant.includes('profile.active !== true'), 'AI assistant must reject suspended Admin profiles.');
assert(assistant.includes('.eq("company_id", companyId)'), 'AI assistant company data queries must be tenant-scoped.');
assert(!assistant.includes('Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")'), 'AI assistant should not use a service-role key for user-scoped reads.');
assert(assistant.includes('getPublishableKey()'), 'AI assistant must use the named publishable API-key environment.');
assert(assistant.includes('store: false'), 'AI responses must disable OpenAI application-state storage.');
assert(assistant.includes('history.slice(-10)'), 'AI assistant must bound conversational history.');
assert(!assistant.includes('"Access-Control-Allow-Origin": "*"'), 'AI assistant must not allow every browser origin.');
assert(assistant.includes('"https://app.linecrewpro.com"'), 'AI assistant must allow the production app origin.');
assert(assistant.includes('Deno.env.get("CORS_ALLOWED_ORIGINS")'), 'AI assistant must support explicit development-origin configuration.');
assert(assistant.includes('if (origin && !allowedOrigins.has(origin))'), 'AI assistant must reject unapproved browser origins before processing.');
assert(assistant.includes('request.method !== "POST"'), 'AI assistant must reject methods other than POST and OPTIONS.');
assert(assistant.includes('2026-09-01-admin-owner-recovery-v13'), 'AI assistant knowledge version marker must track the current workflow release.');
assert(assistant.includes('loadLiveCompanyContext('), 'AI assistant must load permission-scoped live company context.');
assert(assistant.includes('assistantModelConfig(requestPlan.route'), 'AI assistant must route complex questions to the reasoning model.');
assert(assistant.includes('safety_identifier: safetyIdentifier'), 'AI assistant requests must include a privacy-preserving safety identifier.');
assert(index.includes('screen_context:collectAssistantScreenContext()'), 'AI assistant must receive allowlisted current-screen context.');
assert(index.includes("sb.rpc('create_assistant_memory'"), 'Assistant Memory must require an explicit browser confirmation action.');
assert(index.includes('confirmAssistantFinalBillingReminders(jobId)'), 'Final billing must display matching advisory Assistant Memory reminders.');
assert(index.includes('id="assistantMemoryTile"'), 'Owner/Admin Dashboard must include visible Assistant Memory access.');
assert(index.includes("$('assistantMemoryTile').classList.toggle('hidden', !userCanUseAssistant())"), 'Assistant Memory Dashboard tile must remain Owner/Admin-only.');
assert(index.includes("['loginEmail','loginPassword'].forEach"), 'Sign-in fields must submit through the Sign In button when Enter is pressed.');
assert(index.includes("event.key === 'Enter' && !event.shiftKey && !event.isComposing"), 'Assistant must send on Enter while preserving Shift+Enter for a new line and IME composition.');
assert(index.includes('Enter to send · Shift+Enter for a new line'), 'Assistant must explain its keyboard shortcut.');
assert(index.includes('id="assistantResizeHandle"'), 'Assistant panel must provide an accessible drag-to-resize handle.');
assert(index.includes('window.innerWidth * 0.7'), 'Assistant resizing must remain capped below full-page width.');
assert(index.includes("$('assistantResizeHandle').addEventListener('pointerdown'"), 'Assistant resize handle must support pointer dragging.');
assert(index.includes("$('assistantResizeHandle').addEventListener('dblclick', resetAssistantPanelSize)"), 'Assistant resize handle must support returning to its default size.');
assert(assistant.includes('ADMIN OPERATIONS COACH'), 'AI assistant must include Admin operations-coach guidance.');
assert(assistant.includes('ROLE OPERATING MODEL'), 'AI assistant must describe the complete company role model.');
assert(assistant.includes('BILLING BATCHES AND JOB CLOSEOUT'), 'AI assistant must distinguish operational billing and closeout.');
assert(assistant.includes('LINECREW PRO SUBSCRIPTION BILLING'), 'AI assistant must explain company subscription billing separately.');
assert(assistant.includes('submitted_reports'), 'AI assistant context must include company-scoped review-queue signals.');
for (const marker of [
  'Save & Import Authorized Units',
  'email-bound, one-time link',
  'multiple Foremen/General Foremen',
  'Manage Foreman Crews',
  'Regular + OT',
  'The same form accepts an optional PDF, Excel or CSV Job Jacket / Utility Packet',
  'Supervisors review but do not edit a Foreman',
  'green at or above the exact target',
  'Offline JSA Mode',
  'the current offline workflow is JSA-only',
  'search by Work Point',
  'Start and Stop in 24-hour time plus Lunch',
  'full Crew Time table',
  'background push notifications',
  'My Admin Time Roster',
  'Payroll & Timesheet Export',
  'Pay Period History / Archived Timesheets',
  'Truck / Equipment Roster',
  'New training videos are being added'
]) assert(assistant.includes(marker), `AI assistant workflow knowledge is missing: ${marker}`);
assert(index.includes("function userCanUseAssistant(){ return ['owner','admin'].includes(currentUserRole()); }"), 'AI assistant launcher must be Owner/Admin-only.');
assert(!index.includes("['ai_assistant','AI Assistant']"), 'AI assistant must not be configurable as a Superintendent capability.');
for (const marker of [
  'Create Job & Review Jacket',
  'Create Account & Join Company',
  'Assign Another Foreman / Leader',
  'Manage Foreman Crews',
  'A confirmed packet becomes the active authorization baseline',
  'Red is below 95% of target',
  'Offline JSA Mode',
  'searches by Work Point',
  'Start and Stop in 24-hour time plus Lunch',
  'full Crew Time table',
  'background phone push notifications',
  'My Admin Time Roster',
  'Payroll & Timesheet Export',
  'Pay Period History / Archived Timesheets',
  'Truck / Equipment Roster',
  'New training videos are being added'
]) assert(index.includes(marker), `Built-in assistant fallback is missing current workflow help: ${marker}`);

assert(teamInvitation.includes('Deno.env.get("RESEND_API_KEY")'), 'Team invitation sender must use the server-side Resend secret.');
assert(teamInvitation.includes('client.auth.getUser()'), 'Team invitation sender must authenticate the caller.');
assert(teamInvitation.includes('.select("company_id, role, role_permissions, active")'), 'Team invitation sender must load company authorization server-side.');
assert(teamInvitation.includes('profile.active !== true'), 'Team invitation sender must reject suspended profiles.');
assert(teamInvitation.includes('permissions.team_management !== false'), 'Superintendent team invitations must respect the team-management capability.');
assert(teamInvitation.includes('.eq("id", profile.company_id)'), 'Team invitation company data must be derived from the caller profile.');
assert(teamInvitation.includes('crypto.getRandomValues(new Uint8Array(32))'), 'Team invitations must use cryptographically random one-time tokens.');
assert(teamInvitation.includes('crypto.subtle.digest("SHA-256"'), 'Team invitation storage must use token hashes, not raw tokens.');
assert(teamInvitation.includes('client.rpc("create_team_invitation"'), 'Team invitation sender must create an email-bound server record.');
assert(teamInvitation.includes('?invite=${encodeURIComponent(rawToken)}&email=${encodeURIComponent(recipient)}'), 'Team email must carry the one-time token and locked recipient email.');
assert(teamInvitation.includes('LineCrew Pro <invites@auth.linecrewpro.com>'), 'Team invitations must use the verified app sender.');
assert(teamInvitation.includes('reply_to: "support@linecrewpro.com"'), 'Team invitations need the company support reply-to address.');
assert(!teamInvitation.includes('SUPABASE_SERVICE_ROLE_KEY'), 'Team invitation sender must not bypass RLS with a service-role key.');
assert(teamInvitation.includes('getPublishableKey()'), 'Team invitation sender must use the named publishable API-key environment.');
assert(index.includes("sb.functions.invoke('send-team-invitation'"), 'Team invitation button must invoke the secured server sender.');

for (const marker of [
  'userClient.auth.getUser()',
  'getPublishableKey()',
  'getSecretKey()',
  '.from("pilot_feedback")',
  'feedback.submitted_by !== userData.user.id',
  'to: ["support@linecrewpro.com"]',
  'Idempotency-Key',
  'Deno.env.get("RESEND_API_KEY")'
]) assert(pilotFeedbackNotifier.includes(marker), `Pilot feedback email security marker missing: ${marker}`);
assert(!/sb_secret_[A-Za-z0-9_-]+/i.test(pilotFeedbackNotifier), 'Pilot feedback notifier must not contain a literal secret key.');
assert(index.includes("sb.functions.invoke('notify-pilot-feedback'"), 'Pilot feedback must invoke the secured email notifier after the record is saved.');

for (const marker of [
  'getSecretKey()',
  'admin.auth.admin.createUser',
  'email_confirm: true',
  'team_invitation_token_hash: tokenHash',
  'crypto.subtle.digest("SHA-256"',
  'allowedOrigins.has(origin)',
  'password.length < 8',
  'persistSession: false'
]) assert(invitationSignup.includes(marker), `Invited signup security marker missing: ${marker}`);
assert(!/sb_secret_[A-Za-z0-9_-]+/i.test(invitationSignup), 'Invited signup function must not contain a literal secret key.');
for (const marker of ['SUPABASE_PUBLISHABLE_KEYS', 'SUPABASE_SECRET_KEYS', 'edge_functions_admin']) {
  assert(edgeApiKeys.includes(marker), `Edge API-key helper is missing ${marker}.`);
}
assert(!edgeApiKeys.includes('SUPABASE_ANON_KEY'), 'Edge API-key helper must not fall back to the legacy anon key.');
assert(!edgeApiKeys.includes('SUPABASE_SERVICE_ROLE_KEY'), 'Edge API-key helper must not fall back to the legacy service-role key.');
assert(!/sb_secret_[A-Za-z0-9_-]+/i.test(edgeApiKeys), 'Edge API-key helper must not contain a literal secret key.');

for (const marker of [
  'create table if not exists public.team_invitations',
  'alter table public.team_invitations enable row level security',
  'revoke all on table public.team_invitations from public, anon, authenticated',
  'create or replace function public.create_team_invitation',
  'create or replace function public.accept_team_invitation',
  "authenticated_email <> lower(invitation.email)",
  "'foreman'",
  'accepted_at = now()',
  'for update'
]) assert(companyInvitations.includes(marker), `One-click invitation security marker missing: ${marker}`);

for (const marker of [
  'create or replace function public.complete_team_invitation_signup()',
  "new.raw_user_meta_data ->> 'team_invitation_token_hash'",
  'lower(email) = lower(new.email)',
  "'foreman'",
  'accepted_at = now()',
  'after insert on auth.users',
  'revoke all on function public.complete_team_invitation_signup() from public, anon, authenticated'
]) assert(automaticInvitationSignup.includes(marker), `Automatic invitation signup marker missing: ${marker}`);

for (const marker of [
  'create table if not exists public.job_assignment_audit_events',
  'create policy jobs_role_scoped_select',
  'public.linecrew_foreman_has_job_assignment(id)',
  'create policy linecrew_superintendent_jobs_manage',
  'create policy job_leader_assignments_role_scoped_select',
  'assigned_by_name text',
  'create or replace function public.get_job_assignment_history',
  "case when coalesce(p_assigned, false) then 'assigned' else 'unassigned' end",
  'create or replace function public.enforce_foreman_assigned_job()',
  'daily_reports_foreman_assigned_job',
  'daily_report_jsas_foreman_assigned_job',
  'revoke all on table public.job_assignment_audit_events from anon, authenticated'
]) assert(foremanJobAssignments.includes(marker), `Foreman job-assignment security marker missing: ${marker}`);

for (const marker of [
  'drop policy if exists "company members read daily reports"',
  'drop policy if exists reports_company_select',
  'drop policy if exists linecrew_owner_daily_reports_select',
  'create policy daily_reports_role_scoped_select',
  "in ('owner', 'admin', 'gf')",
  "linecrew_has_capability('production_review')",
  "linecrew_has_capability('reporting')",
  "= 'foreman'",
  'foreman_id = (select auth.uid())',
  'created_by = (select auth.uid())',
  'current_user_has_active_profile()'
]) assert(dailyReportReadScope.includes(marker), `Daily Report read-scope security marker missing: ${marker}`);

for (const marker of [
  'create or replace function public.linecrew_mfa_bootstrap_identity()',
  'create or replace function public.linecrew_privileged_mfa_satisfied()',
  'create or replace function public.enforce_linecrew_company_access()',
  "auth.jwt() ->> 'aal'",
  "v_request_path = '/rpc/linecrew_mfa_bootstrap_identity'",
  "v_role in ('owner', 'admin')",
  "set pgrst.db_pre_request = 'public.enforce_linecrew_company_access'"
]) assert(privilegedMfaServer.includes(marker), `Server-enforced privileged MFA marker missing: ${marker}`);
for (const marker of [
  'linecrew_privileged_mfa_storage_select',
  'linecrew_privileged_mfa_storage_insert',
  'linecrew_privileged_mfa_storage_update',
  'linecrew_privileged_mfa_storage_delete'
]) assert(privilegedMfaFoundation.includes(marker), `Restrictive Storage MFA policy missing: ${marker}`);
assert(!privilegedMfaServer.includes('2026-08-31'), 'Privileged MFA must not depend on a fixed calendar deadline.');
assert(!index.includes('MFA_ENFORCEMENT_DATE'), 'The app must not postpone privileged MFA to a calendar deadline.');
assert(!index.includes('postponeMfaBtn'), 'The privileged MFA screen must not provide an application bypass.');

assert(index.includes("sb.rpc('linecrew_mfa_bootstrap_identity')"), 'The app must complete the narrow MFA bootstrap before other Data API requests.');
assert(index.indexOf("sb.rpc('linecrew_mfa_bootstrap_identity')") < index.indexOf("sb.rpc('is_my_profile_suspended')"), 'The MFA bootstrap must run before protected profile checks.');
assert(index.includes('let mfaEnforcementPromise = null;'), 'Privileged MFA enforcement must be single-flight.');
assert(index.includes('if(mfaEnforcementPromise) return mfaEnforcementPromise;'), 'Concurrent app loads must share the active MFA check.');
assert(index.includes('if(pendingMfaFactor){'), 'An MFA screen already in progress must not start another enrollment.');
assert(index.includes('...(data?.totp || [])'), 'Incomplete TOTP factors must be found even when listFactors omits the combined list.');
assert(index.includes('if(removed.error) throw removed.error;'), 'Incomplete-factor cleanup errors must stop enrollment instead of creating a duplicate factor.');
assert(support.includes("rpc('linecrew_mfa_bootstrap_identity')"), 'The support console must complete the narrow MFA bootstrap before protected support RPCs.');
for (const marker of [
  'post-restore-security.sql',
  'verify-post-restore-security.sql',
  'security-files.sha256',
  'sha256sum --check'
]) assert(independentBackup.includes(marker), `Independent backup is missing recovery-security marker: ${marker}`);
for (const [name, workflow] of [
  ['Independent backup', independentBackup],
  ['Daily company backup', dailyCompanyBackup]
]) {
  assert(!workflow.includes('actions/upload-artifact'), `${name} must not publish sensitive recovery data as a GitHub artifact.`);
  assert(workflow.includes('AZURE_STORAGE_CONNECTION_STRING'), `${name} must retain the off-platform Azure backup destination.`);
  assert(workflow.includes('az storage blob upload'), `${name} must upload its recovery package to Azure.`);
}
assert(disasterRestoreWorkflow.includes('bash scripts/test-post-restore-security-gate.sh'), 'The disposable restore workflow must run an actual pg_restore security-gate drill.');
assert(testPostRestoreSecurity.includes('pg_restore') && testPostRestoreSecurity.includes('pg_db_role_setting'), 'The recovery-security drill must prove pg_restore omits the role setting before restoring it.');
assert(fullDisasterRestoreWorkflow.includes('environment: recovery-drill'), 'The full recovery drill must use its protected GitHub environment.');
assert(fullDisasterRestoreWorkflow.includes("RESTORE_RECOVERY_DRILL"), 'The full recovery drill must require an explicit confirmation phrase.');
assert(fullDisasterRestoreWorkflow.includes("test \"$RECOVERY_PROJECT_REF\" != \"$PRODUCTION_PROJECT_REF\""), 'The full recovery drill must refuse the Production project.');
assert(fullDisasterRestoreWorkflow.includes("test \"$RECOVERY_PROJECT_REF\" != \"$NORMAL_TEST_PROJECT_REF\""), 'The full recovery drill must refuse the normal Test project.');
assert(fullDisasterRestoreWorkflow.includes("to_regclass('public.companies') is null"), 'The full recovery drill must refuse a previously used target.');
assert(fullDisasterRestoreWorkflow.includes('pg_restore --exit-on-error --no-owner') && !fullDisasterRestoreWorkflow.includes('pg_restore --exit-on-error --no-owner --no-acl'), 'The full recovery drill must restore ACLs and stop on restore errors.');
assert(!fullDisasterRestoreWorkflow.includes('drop schema if exists auth') && !fullDisasterRestoreWorkflow.includes('drop schema if exists storage'), 'The full recovery drill must not drop Supabase-managed Auth or Storage schemas.');
assert(!fullDisasterRestoreWorkflow.includes('drop schema if exists public'), 'The full recovery drill must preserve the hosted project public schema and its platform-owned defaults.');
assert(fullDisasterRestoreWorkflow.includes('linecrew-managed-objects.list'), 'The full recovery drill must restore LineCrew-specific Auth triggers and Storage policies.');
assert(fullDisasterRestoreWorkflow.includes('/ SCHEMA - public /') && fullDisasterRestoreWorkflow.includes('/ DEFAULT ACL /') && fullDisasterRestoreWorkflow.includes('public.list'), 'The full recovery drill must restore into the existing public schema while preserving platform-owned defaults.');
assert(fullDisasterRestoreWorkflow.includes('alter default privileges in schema public grant all on tables'), 'The full recovery drill must restore application-owner defaults for future public objects.');
assert((fullDisasterRestoreWorkflow.match(/docker run --rm --interactive/g) || []).length >= 5, 'Recovery SQL heredocs must keep Docker standard input open.');
assert(fullDisasterRestoreWorkflow.includes('post-restore-security.sql') && fullDisasterRestoreWorkflow.includes('verify-post-restore-security.sql'), 'The full recovery drill must restore and verify the global security gate.');
assert(restoreBackupStorage.includes('sha256') && restoreBackupStorage.includes("'x-upsert': 'true'"), 'The full recovery drill must restore and hash-verify Storage objects.');
assert(backupScript.includes('mimeType: item.metadata?.mimetype'), 'Independent backups must preserve each Storage object MIME type.');
assert(restoreBackupStorage.includes("['.pdf', 'application/pdf']") && restoreBackupStorage.includes("'content-type': contentType"), 'The full recovery drill must restore Storage objects with an allowed MIME type.');
assert(restoreBackupStorage.includes("['.mp4', 'video/mp4']"), 'The full recovery drill must recognize backed-up training videos.');
assert(restoreBackupStorage.includes('/storage/v1/upload/resumable') && restoreBackupStorage.includes('6 * 1024 * 1024'), 'Large Storage restores must use Supabase resumable uploads with 6 MB chunks.');
assert(restoreBackupStorage.includes("'tus-resumable': '1.0.0'") && restoreBackupStorage.includes("'upload-offset': String(offset)"), 'Large Storage restores must implement guarded TUS offsets.');
assert((restoreBackupStorage.match(/'x-upsert': 'true'/g) || []).length >= 3, 'Standard, resumable-create and resumable-chunk requests must all allow idempotent recovery overwrites.');
assert(restoreBackupStorage.includes('Recovery project Storage limit is too small'), 'Recovery must clearly identify an undersized project Storage limit.');
assert(verifyRestoredTableCounts.includes("Prefer: 'count=exact'"), 'The full recovery drill must compare restored public-table row counts.');
assert(verifyRestoredManagedCounts.includes("'auth.users'") && verifyRestoredManagedCounts.includes("'storage.objects'"), 'The full recovery drill must compare restored Auth and Storage row counts.');
assert(testDisasterRestore.includes("update('company_subscriptions'") && testDisasterRestore.includes('access_override: true'), 'Recovered tenant-isolation tests must activate the automatically generated company subscription.');
assert(testDisasterRestore.includes('removeGeneratedSubscription') && testDisasterRestore.includes("insert('company_subscriptions', snapshot.subscription)"), 'Recovered tenant-isolation tests must replace the generated subscription with the restored snapshot.');
assert(testDisasterRestore.includes("role: 'foreman'") && !testDisasterRestore.includes("role: 'admin'"), 'Recovered tenant-isolation tests must not trigger privileged MFA enforcement.');
assert(!independentBackup.includes('pg_dump --dbname="$SUPABASE_DB_URL" --format=custom --no-owner --no-acl'), 'Independent backups must preserve function ACLs.');
assert(!testPostRestoreSecurity.includes('--no-acl'), 'The recovery drill must restore and verify function ACLs.');
assert(postRestoreSecurity.includes("alter role authenticator\n  set pgrst.db_pre_request = 'public.enforce_linecrew_company_access'"), 'The recovery bootstrap must restore the PostgREST pre-request gate.');
assert(verifyPostRestoreSecurity.includes('pg_db_role_setting') && verifyPostRestoreSecurity.includes("public.enforce_linecrew_company_access"), 'The recovery verifier must inspect the live authenticator role setting.');
assert(verifyPostRestoreSecurity.includes("'authenticated'") && verifyPostRestoreSecurity.includes("'service_role'"), 'The recovery verifier must match the live API-role grants for the pre-request gate.');
assert(!verifyPostRestoreSecurity.includes("has_function_privilege(\n    'authenticator'"), 'The recovery verifier must not require the NOINHERIT authenticator role to execute the gate directly.');
assert(verifyPostRestoreSecurity.includes("has_function_privilege('anon', proc.oid, 'EXECUTE')"), 'The recovery verifier must reject anonymously executable SECURITY DEFINER functions.');
assert(verifyPostRestoreSecurity.includes("public.admin_update_user(uuid,text,boolean)"), 'The recovery verifier must keep the legacy role-escalation RPC closed after restore.');
assert(packetParser.includes('if (origin && !allowedOrigins.has(origin))'), 'Job-packet parsing must reject unapproved browser origins.');
assert(!packetParser.includes('"Access-Control-Allow-Origin": "*"'), 'Job-packet parsing must not allow every browser origin.');
assert(packetParser.includes('|| "gpt-5.4-mini"'), 'Job-packet parsing must default to the cost-controlled document model.');
assert(
  packetParser.includes('attempt === "primary" ? "low" : "medium"'),
  'Job-packet parsing must use low reasoning first and reserve medium reasoning for full-model fallback.'
);
assert(
  index.includes('async function splitPdfForPacketImport(file, pagesPerChunk = 3)') &&
    index.includes('retrySmaller:detail.retry_smaller === true') &&
    index.includes("retryMode:'smaller'"),
  'Job-packet parsing must retry only slow dense groups as single pages.'
);
assert(packetParser.includes('event: "packet_parse_completed"') && packetParser.includes('reasoning_tokens:'), 'Job-packet parsing must log token usage for cost monitoring.');
assert(packetParser.includes('Math.min(2, totalPages - pageOffset)'), 'Job-packet parsing must remain compatible with already-open two-page client sessions during rollout.');
assert(appPolish.includes("tile.setAttribute('role','link')") && appPolish.includes("tile.addEventListener('keydown'"), 'Dashboard tiles must support keyboard and screen-reader navigation.');
assert(index.includes('Create, review and report daily production'), 'The Production dashboard description must reflect the shipped workflow.');

for (const marker of [
  'create table if not exists public.job_closeout_history',
  "action in ('closed', 'override_closed', 'reopened')",
  'create policy server_only_no_direct_access',
  'create or replace function public.get_job_closeout_history',
  "v_role <> 'owner'",
  'Only the company Owner can approve closeout with unresolved billing or production.',
  "'override_closed'",
  "'reopened'",
  'grant execute on function public.get_job_closeout_history(uuid) to authenticated, service_role'
]) assert(jobCloseoutHistory.includes(marker), `Job closeout audit marker missing: ${marker}`);
for (const marker of [
  'enforce_active_job_for_daily_unit_mutation',
  'Units cannot be changed after the parent job is closed.',
  'prevent_duplicate_daily_report',
  'pg_advisory_xact_lock',
  'A Daily Report already exists for this Foreman, job, and work date.'
]) assert(dailyReportScaleIntegrity.includes(marker), `Daily Report integrity marker missing: ${marker}`);
assert(index.includes('let currentProductionServerLimit = 250;'), 'Production history must start with a bounded server-side report window.');
assert(index.includes(".range(fetched,through)"), 'Production history must fetch explicit server-side pages.');
assert(index.includes('Load 250 Older Reports'), 'Production history must provide deliberate load-more access.');
assert(index.includes("sb.rpc('get_job_closeout_history',{p_job_id:job.id})"), 'Completed Jobs must load permanent closeout history.');
assert(index.includes("Only the company Owner can authorize this override closeout."), 'The closeout UI must explain Owner-only unresolved-work approval.');
assert(index.includes("'Closeout History'"), 'Completed-job Excel exports must include closeout history.');

for (const marker of [
  'create or replace function public.get_job_leader_assignments()',
  "linecrew_has_capability('jobs')",
  "linecrew_has_capability('reporting')",
  'assigned_by_name text',
  'revoke all on function public.get_job_leader_assignments()',
  'grant execute on function public.get_job_leader_assignments()'
]) assert(supervisorJobAssignees.includes(marker), `Supervisor job-assignee visibility marker missing: ${marker}`);

for (const marker of [
  'create or replace function public.validate_timekeeping_employee_assignment()',
  "v_actor_role not in ('owner', 'admin', 'gf')",
  "lower(coalesce(foreman.role, '')) = 'foreman'",
  'create policy timekeeping_employees_role_scoped_select',
  "lower(coalesce((select public.my_role()), '')) = 'foreman' and active is true",
  'create policy timekeeping_entries_role_scoped_insert',
  'public.linecrew_foreman_has_job_assignment(timekeeping_entries.job_id)',
  'drop function if exists public.set_my_timekeeping_crew(uuid[])'
]) assert(employeeRosterAssignment.includes(marker), `Employee-roster assignment marker missing: ${marker}`);
assert(timekeepingReport.includes('if(reportRunInFlight) return reportRunInFlight;'), 'Timekeeping reports must prevent overlapping report runs.');
assert(timekeepingReport.includes('finally{reportRunInFlight=null;}'), 'Timekeeping report lock must always release after completion.');
assert(hasVersionedAsset(expandedJsa, 'timekeeping-report-v2.js'), 'Timekeeping report fix must use a cache-busting version.');
assert(timekeeping.includes('if(select.dataset.lcEmployeeOptions===html)return;'), 'Crew employee selectors must not rewrite unchanged options.');
assert(timekeeping.includes("const extra=role()==='foreman'"), 'Base crew options must match Foreman extra-crew labels.');
assert(timekeepingRoster.includes('if(select.dataset.lcEmployeeOptions===html)return;'), 'Roster overlay must share the stable crew-option signature.');
assert(timekeeping.includes('window.saveDailyReportCrewTime=async(reportId)'), 'Daily Report crew time must expose an awaited Timekeeping save.');
assert(index.includes('await window.saveDailyReportCrewTime(savedReportId);'), 'Daily Report save must await Timekeeping before opening unit entry.');
assert(!timekeeping.includes('setTimeout(() => persistCrewTime'), 'Crew time must not rely on a delayed save race.');
assert(index.includes('if(requestId !== teamLoadRequest) return;'), 'Team rendering must ignore stale overlapping refreshes.');
assert(timekeeping.includes('+ Add Extra Man'), 'Foreman Crew Time must provide an explicit extra-man action.');
assert(timekeeping.includes('tk-crew-group'), 'Leadership employee roster must group crew members by Foreman.');
assert(timekeeping.includes('id="tkSaveAssignmentsBtn"'), 'Personnel assignments must provide one explicit batch-save action.');
assert(timekeeping.includes('const rosterAssignmentDrafts = new Map();'), 'Personnel assignments must remain staged while several employees are selected.');
assert(timekeeping.includes("select.onchange = () => updateRosterDraft"), 'Personnel assignment changes must not immediately reload and collapse the roster.');
assert(timekeeping.includes('renderRoster(openGroups);'), 'Personnel assignment save must restore the groups that the manager had open.');
assert(timekeeping.includes('id="tkCompleteRoster"'), 'Owner/Admin Timekeeping must provide a consolidated company roster.');
assert(timekeeping.includes('Complete Company Roster — ${activePeople.length} people / ${activeEquipment.length} equipment'), 'The consolidated roster must summarize active people and equipment.');
assert(timekeeping.includes('Unassigned Crew Members')&&timekeeping.includes('Unassigned Equipment'), 'The consolidated roster must make unassigned personnel and equipment obvious.');
assert(timekeeping.includes("const canViewCompleteRoster = () => ['admin','owner'].includes(role())"), 'The complete company roster must remain Owner/Admin-only.');
assert(timekeeping.includes(".select('id,full_name,email,role,active')")&&timekeeping.includes('profileOnlyPeople'), 'The complete company roster must include Team login accounts without duplicating linked employees.');
assert(timekeepingInput.includes('await window.LineCrewRefreshCompleteRoster?.();'), 'Equipment changes must refresh the consolidated company roster.');
assert(timekeeping.includes('id="tkCompleteRosterSearch"')&&timekeeping.includes('id="tkCompleteRosterAssignment"')&&timekeeping.includes('id="tkCompleteRosterForeman"'), 'The complete company roster must support search, assignment, and Foreman/crew filters.');
assert(timekeeping.includes('Export Filtered Excel')&&timekeeping.includes('filteredCompleteRosterRecords()'), 'Complete roster export must honor the active filters.');
assert(timekeeping.includes("XLSX.utils.book_append_sheet(workbook,sheet,'People')")&&timekeeping.includes("XLSX.utils.book_append_sheet(workbook,sheet,'Equipment')"), 'Complete roster Excel export must separate People and Equipment sheets.');
assert(timekeeping.includes('safeRosterExportCell'), 'Complete roster exports must neutralize spreadsheet formulas.');
assert(timekeeping.includes("<strong>Timekeeping / Roster</strong>")&&timekeeping.includes('<h2>Timekeeping / Roster</h2>'), 'The dashboard tile and page heading must identify the combined Timekeeping / Roster workspace.');
assert(foremanFieldTools.includes("isForeman ? 'Crew Time' : 'Timekeeping / Roster'"), 'Leadership must see Timekeeping / Roster while Foremen retain the simpler Crew Time label.');
assert(index.includes("timekeeping:{label:'Timekeeping / Roster'}"), 'Assistant navigation must use the Timekeeping / Roster label.');
const completeRosterFilterStart = timekeeping.indexOf('function filteredCompleteRosterRecords(){');
const completeRosterFilterEnd = timekeeping.indexOf('\n  function applyCompleteRosterFilters()', completeRosterFilterStart);
assert(completeRosterFilterStart >= 0 && completeRosterFilterEnd > completeRosterFilterStart, 'Complete roster filter function could not be isolated for regression testing.');
const completeRosterFilterFixture = new Function(
  'completeRosterFilters',
  'completeRosterPeople',
  'completeRosterEquipment',
  `${timekeeping.slice(completeRosterFilterStart, completeRosterFilterEnd)}; return filteredCompleteRosterRecords();`
);
const fixturePeople = [
  {id:'p1',searchText:'alpha lineman foreman one',status:'active',assignment:'assigned',foremanFilter:'f1'},
  {id:'p2',searchText:'beta operator unassigned',status:'inactive',assignment:'unassigned',foremanFilter:'unassigned'}
];
const fixtureEquipment = [
  {id:'e1',searchText:'truck 100 alpha foreman one',status:'active',assignment:'assigned',foremanFilter:'f1'},
  {id:'e2',searchText:'trailer 200 unassigned',status:'active',assignment:'unassigned',foremanFilter:'unassigned'}
];
let filteredRosterFixture = completeRosterFilterFixture({query:'alpha',kind:'all',status:'all',assignment:'all',foreman:'all'}, fixturePeople, fixtureEquipment);
assert(filteredRosterFixture.people.map(row=>row.id).join(',')==='p1'&&filteredRosterFixture.equipment.map(row=>row.id).join(',')==='e1', 'Complete roster search must filter both People and Equipment.');
filteredRosterFixture = completeRosterFilterFixture({query:'',kind:'people',status:'inactive',assignment:'unassigned',foreman:'unassigned'}, fixturePeople, fixtureEquipment);
assert(filteredRosterFixture.people.map(row=>row.id).join(',')==='p2'&&filteredRosterFixture.equipment.length===0, 'Complete roster People filters must combine kind, status, assignment, and crew.');
filteredRosterFixture = completeRosterFilterFixture({query:'',kind:'equipment',status:'active',assignment:'unassigned',foreman:'unassigned'}, fixturePeople, fixtureEquipment);
assert(filteredRosterFixture.people.length===0&&filteredRosterFixture.equipment.map(row=>row.id).join(',')==='e2', 'Complete roster Equipment filters must combine kind, status, assignment, and crew.');
assert(timekeepingRoster.includes('My Assigned Crew'), 'Foreman Crew Time options must identify assigned crew members first.');
assert(index.includes('window.openLineCrewTimekeeping({ focusRoster:true })'), 'Team must provide an obvious Manage Foreman Crews path.');
assert(timekeeping.includes("const own=employees.find(e=>e.active&&e.linked_profile_id===viewerId)||null;"), 'Foreman Daily Reports must identify the logged-in Foreman employee directly.');
assert(timekeeping.includes("if(own)addCrewRow(ownSaved||{employee_id:own.id});"), 'Foreman Daily Reports must render the logged-in Foreman first when reopening a report.');
assert(timekeeping.includes("employees.filter(e=>e.active&&e.assigned_foreman_id===viewerId&&(!own||e.id!==own.id)).forEach"), 'Foreman Daily Reports must preload assigned crew underneath the Foreman without duplication.');
assert(!timekeepingRoster.includes('addButton.click();'), 'Assigned crew preload must not depend on overlay click timing.');
assert(hasVersionedAsset(expandedJsa, 'timekeeping.js'), 'Direct Foreman crew preload must use a cache version.');
assert(timekeepingRoster.includes('await autoLoadAssignedCrew();'), 'Foreman roster selectors must wait for assigned crew data before rebuilding employee options.');
assert(foremanFieldTools.includes("title.textContent = titleText"), 'Foreman Timekeeping tile must relabel itself as Crew Time.');
assert(foremanFieldTools.includes("rpc('get_remaining_job_units_for_field'"), 'Remaining Units must load through the scoped database function.');
assert(foremanFieldTools.includes('Saved Draft') && foremanFieldTools.includes('Awaiting GF') && foremanFieldTools.includes('Approved') && foremanFieldTools.includes('Remaining'), 'Remaining Units must separate draft, submitted, approved and remaining quantities.');
assert(foremanFieldTools.includes("role() !== 'foreman'"), 'Remaining Units dashboard access must remain Foreman-only in the client.');
assert(expandedJsa.includes("foreman-field-tools.js?v=20260901a"), 'Foreman field tools must load as a versioned application asset.');
assert(serviceWorker.includes("/foreman-field-tools.js?v=20260901a"), 'Offline app shell must cache the Foreman field tools asset.');
assert(foremanFieldTools.includes('@media(max-width:720px)') && foremanFieldTools.includes('.remaining-units-tools{grid-template-columns:1fr}'), 'Remaining Units must collapse its controls for phone screens.');
assert(foremanFieldTools.includes('-webkit-line-clamp:2') && foremanFieldTools.includes('remaining-unit-toggle'), 'Remaining Unit descriptions must stay compact and expand on demand.');
assert(foremanFieldTools.includes('aria-expanded="false"') && foremanFieldTools.includes("toggle.setAttribute('aria-expanded'"), 'Remaining Unit description expansion must remain keyboard and screen-reader accessible.');
assert(foremanFieldTools.includes('Search Work Point') && !foremanFieldTools.includes('Search Work Point or Unit'), 'Remaining Units search must be dedicated to work points.');
assert(foremanFieldTools.includes('workPointMatches(row.work_point_code, search)') && foremanFieldTools.includes("replace(/^0+(?=\\d)/, '')"), 'Work Point search must ignore leading zeroes without matching unrelated unit fields.');
assert(remainingUnitsMigration.includes("public.linecrew_foreman_has_job_assignment(job.id)"), 'Remaining Units must enforce assigned-job access server-side for Foremen.');
assert(remainingUnitsMigration.includes("package.company_id = v_company_id") && remainingUnitsMigration.includes("report.company_id = location.company_id"), 'Remaining Units must scope package and production data to the authenticated company.');
assert(remainingUnitsMigration.includes('join public.daily_production_units line') && remainingUnitsMigration.includes('line.job_id = p_job_id'), 'Remaining Units usage must be scoped through the production line job.');
assert(remainingUnitsMigration.includes('join public.daily_reports report') && remainingUnitsMigration.includes('report.job_id = p_job_id'), 'Remaining Units usage must be scoped through the owning report job.');
assert(!remainingUnitsMigration.includes('left join public.daily_production_unit_locations') && !remainingUnitsMigration.includes('left join public.daily_reports report'), 'Invalid or different-job production rows must not survive as NULL draft reports.');
assert(remainingUnitsMigration.includes('report.archived is not true') && remainingUnitsMigration.includes("<> 'rejected'"), 'Archived and rejected reports must not reserve Remaining Units.');
assert(remainingUnitsMigration.includes("report.reviewed_at is null") && remainingUnitsMigration.includes("report.review_notes"), 'Returned report quantities must be released until resubmission.');
assert(remainingUnitsMigration.includes("revoke all on function public.get_remaining_job_units_for_field(uuid)") && remainingUnitsMigration.includes("from public, anon"), 'Remaining Units must deny anonymous function execution.');
assert(!remainingUnitsMigration.includes('install_price') && !remainingUnitsMigration.includes('retirement_price'), 'Remaining Units must not expose contract pricing.');
assert(hasVersionedAsset(expandedJsa, 'number-input-polish.js'), 'Global numeric input polish must be cache-versioned and loaded.');
assert(numberInputPolish.includes("input.defaultValue === '0'"), 'Only numeric fields designed with a zero default may restore an empty value to zero.');
assert(numberInputPolish.includes('input.select();'), 'Clicking a displayed zero must select it for immediate replacement.');
assert(index.includes('await saveDailyUnitBatch({ closeAfterSave:true })'), 'Done Adding Units must await the pending unit save before closing.');
assert(index.includes("doneButton.textContent = 'Saving & Finishing...'"), 'Done Adding Units must show an in-progress save state.');
assert(index.includes('if(currentDailySavedUnits.length === 0)'), 'Done Adding Units must not close an empty unit report.');
assert(hasVersionedAsset(expandedJsa, 'app-polish.js'), 'Done Adding Units workflow must load a cache-versioned app polish asset.');
assert(index.includes('<h3>Saved Units</h3>'), 'Edit Draft must show persisted units before the blank Add More Units rows.');
assert(index.includes("doneButton.textContent = 'Done Adding Units';"), 'The Done Adding Units button must reset whenever its editor opens or closes.');
assert(index.includes('<option value="transfer">Transfer</option>'), 'Daily unit production must offer Transfer as an explicit work type.');
assert(index.includes('row.actionInput.value = inferredWorkType;'), 'Selecting a priced unit must automatically choose its inferred work type.');
assert(index.includes("if(Number(item?.transfer_quantity || 0) > 0) return 'transfer';"), 'Saved transfer quantities must preserve their explicit work type.');
assert(index.includes('class="daily-transfer-quantity"'), 'Saved units must expose a separate Transferred quantity.');
assert(index.includes("'save_daily_report_unit_location_v2'"), 'Daily production must save explicit transfer quantities through the v2 RPC.');
assert(index.includes("if(role !== 'foreman') return false;"), 'Leadership review access must not imply permission to edit a Foreman draft.');
assert(index.includes('DRAFT — WAITING FOR FOREMAN'), 'GF draft cards must clearly explain that they are awaiting Foreman submission.');
assert(index.includes("doneButton.textContent = canEditDraft ? 'Done Adding Units' : 'Back to Reports';"), 'The unit editor must switch to a read-only reviewer exit for GF users.');
assert(index.includes("$('dailyUnitEntryControls').classList.toggle('hidden', !canEditDraft);"), 'Daily unit entry controls must be hidden from read-only reviewers.');
assert(index.includes("if(reportStatus === 'draft' && canEditDraft)"), 'Edit and Submit controls must render only for users allowed to edit that draft.');
assert(index.includes("[report?.created_by, report?.foreman_id]"), 'Returned Foreman drafts must recognize both the report creator and assigned Foreman ownership fields.');
assert(/const reportSelect = `[^`]*\bcreated_by,\s*work_date,/m.test(index) && index.includes(".select(reportSelect,{count:fetched===0?'exact':undefined})"), 'Production report loading must include the creator used to restore returned-draft editing.');
assert(expandedJsa.includes('id,job_id,foreman_id,created_by,work_date,status'), 'The returned-report correction loader must preserve Foreman ownership fields for unit editing.');
assert(hasVersionedAsset(index, 'expanded-jsa.js'), 'The current workflow release must use a cache-busted script version.');
assert(index.includes("Importing the package's authorized units lets LineCrew Pro distinguish") && index.includes('normal authorized production from redlines, reconcile Pending Job Units'), 'Job-package setup must explain why authorized-unit import matters.');
assert(index.includes('id="jobPackageInlineImportMount"'), 'Job-package setup must include the inline packet-upload area.');
assert(index.includes('Save Package &amp; Preview File'), 'Job-package save must name the inline file-preview workflow.');
assert(index.includes("$('jobPackageInlineImportMount').appendChild($('jobPackageImportForm'))"), 'Adding a utility package must place file selection and mapping inside the same package box.');
assert(index.includes("return alert('Choose the Excel or CSV job packet file in this box.')"), 'Saving a utility package must require the inline packet file.');
for (const marker of [
  'linecrew_resolve_job_price_book',
  'public.linecrew_can_manage_job_packages()',
  'create or replace function public.resolve_utility_packet_price_item',
  'create or replace function public.finalize_utility_packet_import',
  'create or replace function public.finalize_job_package_spreadsheet_import',
  'public.linecrew_foreman_has_job_assignment(job.id)',
  'else coalesce(report.price_book_id, v_price_book_id)',
  "report.price_book_id is null",
  "package.id <> new.id",
  "package.status = 'active'",
  'linecrew_report_counts_toward_progress',
  "nullif(btrim(coalesce(p_review_notes, '')), '') is null",
  'create or replace function public.get_remaining_job_units_for_field',
  'create or replace function public.get_job_progress_dashboard',
  'from public, anon, authenticated'
]) assert(jobJacketIntegrity.includes(marker), `Job Jacket end-to-end integrity marker missing: ${marker}`);
assert(
  index.includes("sb.rpc('finalize_job_package_spreadsheet_import'") &&
    index.includes("if(importedStatus !== 'active')"),
  'Spreadsheet jacket UI must use the atomic finalizer and confirm activation before claiming success.'
);
assert(
  index.includes("'finalize_utility_packet_import_review'") &&
    index.includes('{ p_import_id:importId, p_rows:reviewRows }') &&
    index.includes('Packet saved for review') &&
    index.includes('Open Saved Review'),
  'PDF jacket review must bulk-save rows and preserve a resumable draft after a review timeout.'
);
for (const marker of [
  'linecrew_utility_packet_import_matches',
  'create_and_stage_utility_packet_import',
  "'resumed', true",
  'source_keys as materialized',
  'update_utility_packet_import_rows_bulk',
  'finalize_utility_packet_import_review',
  'jsonb_to_recordset(p_rows)',
  'Review between 1 and 4,000 packet rows at a time.',
  'job_package_work_points_package_canonical_key_idx',
  'public.normalize_work_point_key(work_point_code)',
  'with matches as materialized',
  'on conflict (work_point_id, price_book_item_id) do update',
  "package.status = 'draft'",
  'from public, anon, authenticated'
]) assert(packetTimeoutFix.includes(marker), `Packet timeout/atomic import marker missing: ${marker}`);
for (const marker of [
  'delete from public.job_package_authorized_units',
  'delete from public.job_package_work_points',
  "package.status = 'draft'",
  'Upload a new job-jacket revision; only a draft package can be imported.',
  'revoke all on function public.import_job_package_units(uuid, jsonb, text)',
  'from public, anon, authenticated',
  'create trigger enforce_draft_job_package_work_point_mutation',
  'create trigger enforce_draft_job_package_authorized_unit_mutation',
  'create trigger prevent_non_draft_job_package_delete',
  'Active job-jacket revisions are read-only. Upload a new revision.',
  'if auth.uid() is null then',
  'create or replace function public.get_job_package_revision_delta_v2',
  'public.normalize_work_point_key(point.work_point_code)',
  'authorized.authorized_transfer_quantity',
  'transfer_change numeric'
]) assert(jobJacketReimport.includes(marker), `Job Jacket replacement/revision marker missing: ${marker}`);
assert(
  index.includes("sb.rpc('get_job_package_revision_delta_v2'") &&
    index.includes("escapeHtml(change.prior_transfer)+' → '+escapeHtml(change.new_transfer)"),
  'Revision comparison must use canonical work points and display transfer changes.'
);
assert(
  index.includes("$('jobPackageImportTools').classList.toggle('hidden', !canManagePackage || !isDraft)") &&
    index.includes("String(currentOpenJobPackage?.status || 'draft').toLowerCase() === 'draft'"),
  'Active jacket baselines must be read-only and corrected through a new revision.'
);
assert(
  index.includes("String(jobPackage.status || 'draft').toLowerCase() === 'draft'") &&
    index.includes("deleteButton.textContent = 'Delete Draft Package'"),
  'Only draft jacket revisions may expose a destructive delete action.'
);
assert(
  index.includes('function jobPackageRevisionLabel(jobPackage)') &&
    (index.match(/jobPackageRevisionLabel\(/g) || []).length >= 6,
  'Job history, billing exports and PDF records must share one revision label.'
);
assert(
  index.includes('expanded-jsa.js?v=20260901a') &&
    serviceWorker.includes('/expanded-jsa.js?v=20260901a') &&
    serviceWorker.includes("linecrew-pro-shell-v61") &&
    expandedJsa.includes("role-workspace-polish.js?v=20260903b") &&
    serviceWorker.includes("/role-workspace-polish.js?v=20260903b"),
  'Returned-report metadata fix must be delivered through a fresh offline app-shell cache.'
);

for (const marker of [
  'required_man_hour_rate numeric(12,2)',
  'create or replace function public.update_company_man_hour_rate',
  "v_role not in ('owner', 'admin')",
  "set search_path = ''",
  'revoke all on function public.update_company_man_hour_rate(numeric) from anon',
  'grant execute on function public.update_company_man_hour_rate(numeric) to authenticated'
]) assert(manHourRateTarget.includes(marker), `MH rate target security marker missing: ${marker}`);
assert(index.includes('function manHourTargetStatus(rate)'), 'Supervision MH rate target status helper is missing.');
assert(index.includes("ratio < 0.95"), 'MH rate red threshold must be below 95% of target.');
assert(index.includes("ratio < 1"), 'MH rate yellow threshold must stop below the exact target.');
assert(index.includes("const foremanEntryWorkspace = role === 'foreman'"), 'Only Foremen may receive the Create Daily Report field-entry action.');
assert(index.includes("if(role !== 'foreman') return false"), 'Leadership must not receive Foreman draft-editing controls.');
assert(index.includes("? 'Job Setup & Management'"), 'Owner/Admin Jobs must be labeled as a management workspace.');
assert(index.includes("' supervisor-compact-report'"), 'Supervisor Production reports must use compact rows for large report volumes.');
assert(index.includes('jobName + \' · \' + foreman'), 'Compact supervisor rows must identify both the job and Foreman.');
assert(hasVersionedAsset(expandedJsa, 'role-workspace-polish.js'), 'Role workspace management labels must use a cache version.');
assert(index.includes('dailyReportValueSummaryMarkup(report, valueSummary)'), 'Production cards must calculate run rates from each report’s own hours.');
assert(index.includes("'<br>Actual MH Run Rate: <strong>'"), 'Supervision report cards must show the actual man-hour run rate when actual pricing is permitted.');
assert(index.includes('function userCanSeeFieldMoney()'), 'Field-money visibility helper is missing.');
assert(index.includes("'<br>Field MH Run Rate: ' + manHourRateNumberMarkup(fieldRunRate)"), 'Production report cards must color only the field man-hour rate number.');
for (const marker of [
  'linecrew_set_member_money_permissions',
  "'actual_pricing', can_see_actual",
  "'field_pricing', can_see_field",
  "v_can_see_actual := public.linecrew_has_capability('actual_pricing')",
  "v_can_see_field := public.linecrew_has_capability('field_pricing')",
  'profile.company_id = actor.company_id'
]) assert(moneyVisibility.includes(marker), `Money visibility security marker missing: ${marker}`);
for (const marker of [
  'v_actor_company_id',
  'profile.company_id = v_actor_company_id',
  'get diagnostics v_updated = row_count',
  'if v_updated <> 1 then'
]) assert(moneyVisibilityUpdateFix.includes(marker), `Money visibility update marker missing: ${marker}`);
for (const marker of [
  "new.role in ('foreman','gf')",
  "'actual_pricing', new.role_permissions -> 'actual_pricing'",
  "'field_pricing', new.role_permissions -> 'field_pricing'",
  "new.role in ('admin','owner')"
]) assert(fieldRoleMoneyPermissions.includes(marker), `Field-role money permission marker missing: ${marker}`);
for (const marker of [
  'get_price_book_items_visible',
  'get_daily_report_unit_catalog_visible',
  'get_daily_report_unit_locations_visible_v2',
  "linecrew_has_capability('field_pricing')",
  'then item.adjusted_line_value else null end'
]) assert(detailedFieldMoney.includes(marker), `Detailed Field Money mask missing: ${marker}`);
for (const marker of ['Money Visibility','Actual Money','Field Money']) {
  assert(index.includes(marker), `Team money visibility UI marker missing: ${marker}`);
}
assert(/\.daily-review-counts\s+\.authorized,\s*\.daily-review-counts\s+\.pending,\s*\.daily-review-counts\s+\.redline\s*\{[^}]*color\s*:\s*inherit\s*;/m.test(index), 'Authorization, Pending Packet and Redline summary counts must remain neutral.');
assert(!index.includes('mh-rate-target'), 'Man-hour target status must not render as a separate colored badge.');
assert(timekeeping.includes('window.manHourRateNumberMarkup(value)'), 'Production totals must color only the Field MH Run Rate value.');
for (const marker of [
  "label:'Below Target'",
  "label:'Below Target — Within 5%'",
  "label:'At Target'",
  "label:'Above Target'",
  "'Target Not Set'",
  'mh-rate-status-text'
]) assert(index.includes(marker), `Expanded MH rate status is missing: ${marker}`);
for (const marker of [
  "v_role = 'foreman' and report.foreman_id = auth.uid()",
  'delete from public.timekeeping_entries entry',
  "lower(coalesce(report.status, 'draft')) = 'draft'",
  'revoke all on function public.delete_draft_daily_report(uuid) from public, anon'
]) assert(foremanDraftDeletion.includes(marker), `Foreman draft-deletion marker missing: ${marker}`);
assert(index.includes("currentUserRole() === 'foreman' && report.foreman_id === currentProfile.id"), 'Foremen must see Delete Draft only on their own reports.');
for (const marker of [
  'auth.uid() = v_report_creator',
  'report.submitted_at is null',
  'get_daily_report_unit_locations_v2',
  "'TRANSFER'::text",
  "b.status not in ('void', 'draft')",
  'Only the Company Owner can override unresolved Final Bill blockers.'
]) assert(reportAndFinalBillingHardening.includes(marker), `Report/final-billing hardening is missing: ${marker}`);
assert(!reportAndFinalBillingHardening.includes('right(upper'), 'Transfer reconciliation must not infer transfers from a unit-code suffix.');
for (const marker of [
  'price_book_items_actual_pricing_select',
  'unit_prices_actual_pricing_select',
  'daily_report_units_actual_pricing_select',
  'revoke update, delete on public.jobs from authenticated',
  "linecrew_has_capability('job_packages')",
  'linecrew_foreman_has_job_assignment(package.job_id)'
]) assert(directRestHardening.includes(marker), `Direct REST/RPC hardening is missing: ${marker}`);
assert(dynamicBackupInventory.includes('backup_public_table_inventory'), 'Backups need a server-generated public-table inventory.');
assert(dynamicBackupInventory.includes('to service_role'), 'Only service_role may enumerate the backup table inventory.');
assert(backupScript.includes("/rest/v1/rpc/backup_public_table_inventory"), 'The backup job must request its table inventory from the database.');
assert(!backupScript.includes("'app_error_events', 'audit_log'"), 'The backup job must not rely on a hardcoded table list.');
assert(ownerJobAccess.includes("not in ('owner', 'admin', 'gf')"), 'Owner must retain update_job access after direct REST writes are revoked.');
assert(ownerJobAccess.includes("not in ('owner', 'admin')"), 'Owner must retain delete_job access after direct REST writes are revoked.');

for (const role of ['foreman', 'gf', 'superintendent', 'admin', 'owner']) assert(roleMigration.includes(`'${role}'`), `Role migration is missing ${role}.`);
assert(roleMigration.includes('drop constraint if exists profiles_role_supported'), 'Role migration must replace the legacy three-role constraint.');
assert(roleMigration.includes('linecrew_claim_initial_owner'), 'Role migration must provide a safe initial Owner claim path.');
assert(roleMigration.includes('linecrew_set_member_role'), 'Role migration must centralize role changes.');
assert(roleMigration.includes('A Superintendent can manage General Foreman and Foreman roles only'), 'Superintendent delegated role management must stop above GF/Foreman.');
assert(roleMigration.includes("role_permissions ->> 'role_management'"), 'Superintendent role-management capability must be enforced server-side.');
assert(roleMigration.includes('linecrew_set_superintendent_permissions'), 'Superintendent permission overrides must be server-enforced.');
assert(roleMigration.includes("jsonb_typeof(item.value) <> 'boolean'"), 'Superintendent overrides must accept boolean values only.');
assert(roleMigration.includes('actor.active is not true'), 'Role-management RPCs must reject suspended leadership profiles.');
assert(roleMigration.includes('and p.active is true'), 'Capability checks must reject suspended profiles.');
for (const marker of [
  'profiles_one_owner_per_company_idx',
  "requested_role not in ('foreman','gf','superintendent','admin')",
  'Admins may promote a Foreman, General Foreman, or Superintendent to Admin.',
  'Only the Owner can change an existing Admin.',
  'linecrew_transfer_company_owner',
  'company_ownership_transferred',
  "Restore this team member''s access before changing their role.",
  "'role_permissions', target.role_permissions",
  'Your role or access changed while the access update was starting.',
  "set search_path = ''",
  'for update'
]) assert(roleGovernance.includes(marker), `Current Owner/Admin governance is missing: ${marker}`);
assert(!roleGovernance.includes("requested_role not in ('foreman','gf','superintendent','admin','owner')"), 'Generic role management must not assign Owner.');
for (const marker of [
  'linecrew_admin_replace_company_owner',
  "requested_former_role not in ('foreman','gf','superintendent','admin')",
  "auth.jwt() ->> 'aal'",
  "lower(coalesce(actor.role, '')) <> 'admin'",
  "lower(coalesce(current_owner.role, '')) <> 'owner'",
  "lower(coalesce(replacement.role, '')) <> 'admin'",
  "and company_id = actor_company_id",
  "select count(*)",
  "company_ownership_recovered_by_admin",
  "set search_path = ''",
  'for update',
  'from public, anon, authenticated',
  'to authenticated'
]) assert(adminOwnerRecovery.includes(marker), `Admin Owner recovery is missing: ${marker}`);
assert(
  adminOwnerRecovery.indexOf("set role = requested_former_role") < adminOwnerRecovery.indexOf("set role = 'owner'"),
  'Admin Owner recovery must demote the previous Owner before promoting the replacement to satisfy the single-Owner index.'
);
const setMemberRoleGovernance = sourceBetween(
  roleGovernance,
  'create or replace function public.linecrew_set_member_role(',
  'create or replace function public.linecrew_transfer_company_owner('
);
const targetActiveGuard = setMemberRoleGovernance.indexOf('if target.active is not true then');
const roleUpdate = setMemberRoleGovernance.indexOf('update public.profiles');
assert(
  targetActiveGuard >= 0 && roleUpdate > targetActiveGuard,
  'The member-role RPC must reject every suspended target before updating their profile.'
);

const teamRoleOptions = sourceBetween(
  index,
  'function roleOptionsForMember(member){',
  'function canTransferOwnershipTo(member){'
);
const adminRoleOptions = sourceBetween(
  teamRoleOptions,
  "if(actor === 'admin'){",
  "if(actor === 'superintendent'"
);
assert(
  teamRoleOptions.indexOf('if(member.active === false) return [];') >= 0 &&
    teamRoleOptions.indexOf('if(member.active === false) return [];') < teamRoleOptions.indexOf("if(actor === 'admin'){"),
  'Team role controls must reject suspended members before evaluating Admin options.'
);
assert(
  adminRoleOptions.includes("if(['owner','admin'].includes(target)) return [];") &&
    adminRoleOptions.includes("return [['foreman','Foreman'],['gf','General Foreman'],['superintendent','Superintendent'],['admin','Admin']];") &&
    !adminRoleOptions.includes("['owner','Owner']"),
  'The Admin branch must manage active lower roles through Admin without exposing Owner or peer-Admin controls.'
);

const transferOwnershipHandler = sourceBetween(
  index,
  'async function transferCompanyOwnership(member,button){',
  'function canChangeMemberAccess(member){'
);
const adminOwnerRecoveryHandler = sourceBetween(
  index,
  'async function replaceCompanyOwnerAsAdmin(owner,replacement,formerRole,button,replacementSelect,roleSelect){',
  'function canChangeMemberAccess(member){'
);
const claimOwnerHandler = sourceBetween(
  index,
  'async function claimInitialOwner(button){',
  'let teamLoadRequest = 0;'
);
const updateRoleHandler = sourceBetween(
  index,
  'async function updateTeamMemberRole(member,nextRole,button,roleSelect){',
  'async function changeTeamMemberAccess(member){'
);
const teamRenderer = sourceBetween(
  index,
  'async function loadTeamMembers(){',
  "$('manageFieldEmployeesBtn').onclick"
);
for (const [handler, pendingLabel, restoreMarker, message] of [
  [transferOwnershipHandler, "button.textContent = 'Transferring...'", 'button.textContent = priorText;', 'ownership transfer'],
  [adminOwnerRecoveryHandler, "button.textContent = 'Recovering Ownership...'", 'replacementSelect.disabled = false;', 'Admin ownership recovery'],
  [claimOwnerHandler, "button.textContent = 'Assigning Owner...'", 'button.textContent = priorText;', 'initial Owner claim'],
  [updateRoleHandler, "button.textContent = 'Saving...'", 'roleSelect.disabled = false;', 'member role save']
]) {
  assert(
    handler.includes('button?.disabled') &&
      handler.includes('button.disabled = true') &&
      handler.includes(pendingLabel) &&
      handler.includes('button.disabled = false') &&
      handler.includes(restoreMarker),
    `The ${message} UI must prevent duplicate requests and restore controls after an error.`
  );
}
assert(
  updateRoleHandler.includes('roleSelect.disabled = true;') &&
    teamRenderer.includes('button.onclick = ()=>claimInitialOwner(button);') &&
    teamRenderer.includes('save.onclick=()=>updateTeamMemberRole(member,roleSelect.value,save,roleSelect);') &&
    teamRenderer.includes('transfer.onclick=()=>transferCompanyOwnership(member,transfer);') &&
    teamRenderer.includes('renderAdminOwnershipRecovery(member,members,card);'),
  'Team role controls must pass their rendered buttons/select into the single-flight handlers.'
);
assert(transferOwnershipHandler.includes("'linecrew_transfer_company_owner'"), 'Team UI must use the explicit ownership-transfer RPC.');
assert(adminOwnerRecoveryHandler.includes("'linecrew_admin_replace_company_owner'"), 'Team UI must use the MFA-protected Admin ownership-recovery RPC.');
assert(assistant.includes('May promote an active Foreman, General Foreman or Superintendent to Admin'), 'Live Assistant role guidance must explain Admin promotion safely.');
assert(assistant.includes('Ownership Recovery'), 'Live Assistant role guidance must explain Admin ownership recovery.');

assert(roleGovernance.includes('set_company_member_active'), 'Current team access changes need the governance-serialized hierarchy RPC.');
assert(roleGovernance.includes("target_role in ('owner','admin')"), 'Admins must not suspend Owners or peer Admins.');
assert(roleGovernance.includes("target_role not in ('foreman','gf')"), 'Superintendents must not suspend peers or higher roles.');
assert(roleGovernance.includes('Transfer ownership before suspending the company Owner.'), 'The single Owner must be protected from suspension.');

assert(ownerCompat.includes("'owner'"), 'Legacy secured RPCs must recognize Owner.');
assert(superintendentCompat.includes('linecrew_has_capability'), 'Legacy Superintendent RPC compatibility must be capability-gated.');
for (const cap of ['jobs','job_packages','production_review','reporting','storm_mode','safety_records','actual_pricing','price_books','company_settings','team_management']) {
  assert(superintendentCompat.includes(`'${cap}'`), `Superintendent compatibility is missing ${cap}.`);
}
assert(superintendentCompat.includes("v_role = 'superintendent' and public.linecrew_has_capability('actual_pricing')"), 'Actual pricing visibility must remain independently gated for Superintendents.');
assert(!ownerCompat.includes('create or replace function public.get_daily_report_unit_locations'), 'Owner legacy migration must not replace the evolved unit-location TABLE return type.');
assert(!superintendentCompat.includes('create or replace function public.get_daily_report_unit_locations'), 'Superintendent legacy migration must not replace the evolved unit-location TABLE return type.');
assert(!superintendentCompat.includes('actual_contract_pricing'), 'Legacy compatibility must use the canonical actual_pricing capability key.');

for (const marker of [
  'drop function if exists public.get_daily_report_unit_locations(uuid)',
  'authorization_status text',
  "linecrew_has_capability('actual_pricing')",
  'create or replace function public.update_my_profile_name',
  'revoke all on function public.admin_update_user(uuid,text,boolean)',
  'revoke all on function public.review_daily_report(uuid,boolean,text)',
  'drop policy if exists profiles_admin_update',
  'linecrew_owner_contracts_manage',
  'linecrew_owner_daily_reports_select',
  "notify pgrst, 'reload schema'"
]) assert(driftRepair.includes(marker), `Production drift repair is missing: ${marker}`);
assert(!driftRepair.includes('actual_contract_pricing'), 'Production drift repair must not use the obsolete actual_contract_pricing key.');
for (const marker of [
  'create or replace function public.get_contract_field_settings()',
  "linecrew_has_capability('customers_contracts')",
  'create or replace function public.get_daily_report_jsa',
  "linecrew_has_capability('safety_records')",
  'p.active is true',
  'revoke all on function public.get_contract_field_settings() from public, anon, authenticated',
  'revoke all on function public.get_daily_report_jsa(uuid) from public, anon, authenticated'
]) assert(rpcAccessRepair.includes(marker), `Post-fix RPC access repair is missing: ${marker}`);
assert(hasVersionedAsset(expandedJsa, 'app-polish.js'), 'app-polish.js must use a cache-busting version.');

for (const marker of [
  'linecrew_superintendent_customers_manage',
  'linecrew_superintendent_contracts_manage',
  "public.my_role() = 'superintendent'",
  "linecrew_has_capability('customers_contracts')",
  'company_id = public.my_company_id()',
  'with check',
  "roles = array['authenticated']::name[]"
]) assert(superintendentContractsPolicies.includes(marker), `Superintendent Customers & Contracts policies are missing: ${marker}`);

for (const marker of [
  "['owner','admin'].includes(currentUserRole())",
  "role === 'superintendent'",
  "linecrew_set_member_role",
  "linecrew_set_superintendent_permissions",
  "linecrew_claim_initial_owner",
  "linecrew_transfer_company_owner",
  "userCanManageCustomersContracts()",
  "userCanManagePriceBooks()",
  "userCanManageJobPackages()",
  "userCanReviewProduction()",
  "userCanUseReporting()",
  "userCanManageStormMode()",
  "userCanUseAssistant()"
]) assert(index.includes(marker), `Role-aware frontend marker missing: ${marker}`);

for (const marker of [
  'id="emailTeamInviteBtn"',
  'Invitation sent from invites@auth.linecrewpro.com.',
  'Create Account & Join Company',
  'id="signupPasswordConfirm"',
  "password !== passwordConfirmation",
  /sb\.functions\.invoke\(\s*['"]complete-team-invitation-signup['"]/,
  'sb.auth.signInWithPassword({ email, password })',
  "$('loginCard').classList.toggle('hidden', invited)",
  "$('signupEmail').readOnly = invited",
  "await sb.auth.signOut({ scope:'local' })",
  'async function startApp()',
  "$('createCompanyCard').classList.toggle('hidden', invited)",
  "$('joinCompanyCard').classList.toggle('hidden', invited)",
  'id="newPriceBookImportFile"',
  'id="newPriceBookFileCheck"',
  'Save Unit Pricing &amp; Continue',
  'spreadsheet rows were found.',
  'await handlePriceBookImportFile(selectedImportFile)',
  'Review the preview'
]) assert(marker instanceof RegExp ? marker.test(index) : index.includes(marker), `Onboarding workflow marker missing: ${marker}`);

assert(expandedJsa.includes("loginButton.textContent = 'Signing In...'"), 'Sign-in must prevent duplicate submissions while authentication is running.');
assert(expandedJsa.includes("sb.auth.signInWithPassword({ email, password })"), 'The single-flight sign-in guard must authenticate through Supabase.');
assert(expandedJsa.includes('const resetLoginFormState = () => {'), 'Auth UI must provide a shared login-state reset routine.');
assert(expandedJsa.includes("event === 'SIGNED_OUT'"), 'The auth listener must reset the login UI after sign-out.');
assert(index.match(/window\.resetLineCrewLoginFormState\?\.\(\);/g)?.length >= 2, 'Explicit and event-driven sign-out paths must both reset the login UI.');
const guardedLoginHandler = expandedJsa.slice(
  expandedJsa.indexOf('loginButton.onclick = async () => {'),
  expandedJsa.indexOf('const productionTile', expandedJsa.indexOf('loginButton.onclick = async () => {'))
);
assert(!guardedLoginHandler.includes('loadApp('), 'The guarded sign-in handler must let the SIGNED_IN listener load the app exactly once.');

for (const marker of [
  'Foremen can only see and report against jobs assigned to them.',
  'assignment.assigned_by_name',
  'formatAuditTimestamp(assignment.assigned_at)',
  "sb.rpc('get_job_assignment_history'",
  'View Assignment History'
]) assert(index.includes(marker), `Job-assignment audit UI marker missing: ${marker}`);

for (const marker of [
  'Assigned Foremen / Job Leaders:</strong>',
  "assignedNames.join(', ')",
  "'Unassigned'",
  'Assign Another Foreman / Leader'
]) assert(index.includes(marker), `Job-progress assignee marker missing: ${marker}`);

if (failures.length) {
  console.error('Production readiness validation failed:');
  failures.forEach(failure => console.error(`- ${failure}`));
  process.exit(1);
}

console.log('Production readiness validation passed.');
console.log('- Vercel security headers and secret checks passed');
console.log('- Active Owner/Admin-only AI authorization present');
console.log('- Owner/Admin/Superintendent hierarchy protections present');
console.log('- Suspended leadership profiles cannot use role/capability management');
console.log('- Tracked Owner compatibility migration present');
console.log('- Tracked capability-aware Superintendent compatibility migration present');
console.log('- Forward production drift repair and post-deploy verification present');
console.log('- Contracts and JSA RPC access gaps are tracked and capability-gated');
console.log('- Superintendent Customers & Contracts table writes are company-scoped and capability-gated');
console.log('- Actual pricing remains independently gated');
console.log('- Team, job, package, reporting, storm and assistant UI capability wiring present');
console.log('- Email-bound, one-time Resend team invitations bypass company creation and code entry');
console.log('- Guided Contract to Unit Pricing upload workflow present');
console.log('- Foreman job visibility is assignment-scoped with manager and timestamp audit history');
console.log('- Supervisor job-progress cards list every assigned Foreman / Job Leader');
console.log('- Field employees are leadership-assigned; Foremen can add extra active crew only on assigned jobs');
console.log('- Timekeeping reports use a single-flight guard to prevent repeated Run Report loops');
console.log('- Crew selectors avoid observer feedback loops on the Foreman Production screen');
