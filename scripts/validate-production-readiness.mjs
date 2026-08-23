import fs from 'node:fs';

const failures = [];
const assert = (condition, message) => { if (!condition) failures.push(message); };

const mustExist = [
  'index.html',
  'vercel.json',
  'scripts/validate-app.mjs',
  'supabase/functions/linecrew-assistant/index.ts',
  'supabase/functions/send-team-invitation/index.ts',
  'supabase/functions/complete-team-invitation-signup/index.ts',
  'supabase/migrations/20260818_owner_superintendent_roles.sql',
  'supabase/migrations/20260818_owner_superintendent_team_access.sql',
  'supabase/migrations/202608190100_owner_legacy_compatibility.sql',
  'supabase/migrations/202608190200_superintendent_legacy_compatibility.sql',
  'supabase/migrations/20260822220000_production_role_compatibility_drift_repair.sql',
  'supabase/migrations/20260822223611_close_post_fix_rpc_access_gaps.sql',
  'supabase/migrations/20260823004222_superintendent_customers_contracts_policies.sql',
  'supabase/migrations/20260823015316_one_click_company_invitations.sql',
  'supabase/migrations/20260823021011_automate_invited_foreman_signup.sql',
  'supabase/migrations/20260823023639_restrict_foremen_to_assigned_jobs.sql',
  'supabase/migrations/20260823024700_show_job_assignees_to_supervisors.sql',
  'supabase/migrations/20260823030000_company_employee_roster_assignment.sql',
  'supabase/migrations/20260823051008_allow_foreman_delete_own_draft_reports.sql',
  'supabase/migrations/20260823053000_add_company_man_hour_rate_target.sql',
  'number-input-polish.js',
  'scripts/generate-production-drift-repair.mjs',
  'scripts/verify-production-schema.sql'
];
for (const file of mustExist) assert(fs.existsSync(file), `Missing ${file}`);

const index = fs.readFileSync('index.html', 'utf8');
const vercel = JSON.parse(fs.readFileSync('vercel.json', 'utf8'));
const assistant = fs.readFileSync('supabase/functions/linecrew-assistant/index.ts', 'utf8');
const teamInvitation = fs.readFileSync('supabase/functions/send-team-invitation/index.ts', 'utf8');
const invitationSignup = fs.readFileSync('supabase/functions/complete-team-invitation-signup/index.ts', 'utf8');
const roleMigration = fs.readFileSync('supabase/migrations/20260818_owner_superintendent_roles.sql', 'utf8');
const accessMigration = fs.readFileSync('supabase/migrations/20260818_owner_superintendent_team_access.sql', 'utf8');
const ownerCompat = fs.readFileSync('supabase/migrations/202608190100_owner_legacy_compatibility.sql', 'utf8');
const superintendentCompat = fs.readFileSync('supabase/migrations/202608190200_superintendent_legacy_compatibility.sql', 'utf8');
const driftRepair = fs.readFileSync('supabase/migrations/20260822220000_production_role_compatibility_drift_repair.sql', 'utf8');
const rpcAccessRepair = fs.readFileSync('supabase/migrations/20260822223611_close_post_fix_rpc_access_gaps.sql', 'utf8');
const superintendentContractsPolicies = fs.readFileSync('supabase/migrations/20260823004222_superintendent_customers_contracts_policies.sql', 'utf8');
const companyInvitations = fs.readFileSync('supabase/migrations/20260823015316_one_click_company_invitations.sql', 'utf8');
const automaticInvitationSignup = fs.readFileSync('supabase/migrations/20260823021011_automate_invited_foreman_signup.sql', 'utf8');
const foremanJobAssignments = fs.readFileSync('supabase/migrations/20260823023639_restrict_foremen_to_assigned_jobs.sql', 'utf8');
const supervisorJobAssignees = fs.readFileSync('supabase/migrations/20260823024700_show_job_assignees_to_supervisors.sql', 'utf8');
const employeeRosterAssignment = fs.readFileSync('supabase/migrations/20260823030000_company_employee_roster_assignment.sql', 'utf8');
const foremanDraftDeletion = fs.readFileSync('supabase/migrations/20260823051008_allow_foreman_delete_own_draft_reports.sql', 'utf8');
const manHourRateTarget = fs.readFileSync('supabase/migrations/20260823053000_add_company_man_hour_rate_target.sql', 'utf8');
const numberInputPolish = fs.readFileSync('number-input-polish.js', 'utf8');
const expandedJsa = fs.readFileSync('expanded-jsa.js', 'utf8');
const timekeepingReport = fs.readFileSync('timekeeping-report-v2.js', 'utf8');
const timekeeping = fs.readFileSync('timekeeping.js', 'utf8');
const timekeepingRoster = fs.readFileSync('timekeeping-roster.js', 'utf8');

const vercelText = JSON.stringify(vercel);
for (const header of ['X-Content-Type-Options','X-Frame-Options','Referrer-Policy','X-Robots-Tag','Content-Security-Policy','Strict-Transport-Security']) {
  assert(vercelText.includes(header), `Missing production response header: ${header}`);
}
assert(vercelText.includes("frame-ancestors 'none'"), 'App must prevent framing/clickjacking.');
assert(vercelText.includes('noindex, nofollow'), 'Operational app should not be indexed by search engines.');

const publicSecretPatterns = [
  ['OpenAI secret key', /sk-(?:proj-)?[A-Za-z0-9_-]{20,}/],
  ['Supabase secret key', /sb_secret_[A-Za-z0-9_-]+/i],
  ['Supabase service role JWT marker', /service[_-]?role[^\n]{0,80}eyJ/i],
  ['Private key', /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/]
];
for (const [label, pattern] of publicSecretPatterns) assert(!pattern.test(index), `${label} appears in public index.html`);

assert(assistant.includes('client.auth.getUser()'), 'AI assistant must authenticate the caller.');
assert(assistant.includes('.select("company_id, role, active")'), 'AI assistant must load role and active status server-side.');
assert(assistant.includes('!["admin", "owner"].includes(role)'), 'AI assistant must reject every role except active Owner/Admin server-side.');
assert(assistant.includes('profile.active !== true'), 'AI assistant must reject suspended Admin profiles.');
assert(assistant.includes('.eq("company_id", companyId)'), 'AI assistant company data queries must be tenant-scoped.');
assert(!assistant.includes('Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")'), 'AI assistant should not use a service-role key for user-scoped reads.');
assert(assistant.includes('store: false'), 'AI responses must disable OpenAI application-state storage.');
assert(assistant.includes('history.slice(-10)'), 'AI assistant must bound conversational history.');
assert(index.includes("function userCanUseAssistant(){ return ['owner','admin'].includes(currentUserRole()); }"), 'AI assistant launcher must be Owner/Admin-only.');
assert(!index.includes("['ai_assistant','AI Assistant']"), 'AI assistant must not be configurable as a Superintendent capability.');

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
assert(index.includes("sb.functions.invoke('send-team-invitation'"), 'Team invitation button must invoke the secured server sender.');

for (const marker of [
  'Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")',
  'admin.auth.admin.createUser',
  'email_confirm: true',
  'team_invitation_token_hash: tokenHash',
  'crypto.subtle.digest("SHA-256"',
  'allowedOrigins.has(origin)',
  'password.length < 8',
  'persistSession: false'
]) assert(invitationSignup.includes(marker), `Invited signup security marker missing: ${marker}`);
assert(!/sb_secret_[A-Za-z0-9_-]+/i.test(invitationSignup), 'Invited signup function must not contain a literal secret key.');

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
assert(expandedJsa.includes("load('timekeeping-report-v2.js?v=20260823a'"), 'Timekeeping report fix must use a fresh cache-busting version.');
assert(timekeeping.includes('if(select.dataset.lcEmployeeOptions===html)return;'), 'Crew employee selectors must not rewrite unchanged options.');
assert(timekeeping.includes("const extra=role()==='foreman'"), 'Base crew options must match Foreman extra-crew labels.');
assert(timekeepingRoster.includes('if(select.dataset.lcEmployeeOptions===html)return;'), 'Roster overlay must share the stable crew-option signature.');
assert(timekeeping.includes('window.saveDailyReportCrewTime=async(reportId)'), 'Daily Report crew time must expose an awaited Timekeeping save.');
assert(index.includes('await window.saveDailyReportCrewTime(savedReportId);'), 'Daily Report save must await Timekeeping before opening unit entry.');
assert(!timekeeping.includes('setTimeout(() => persistCrewTime'), 'Crew time must not rely on a delayed save race.');
assert(index.includes('if(requestId !== teamLoadRequest) return;'), 'Team rendering must ignore stale overlapping refreshes.');
assert(timekeeping.includes('+ Add Extra Man'), 'Foreman Crew Time must provide an explicit extra-man action.');
assert(timekeeping.includes('tk-crew-group'), 'Leadership employee roster must group crew members by Foreman.');
assert(timekeepingRoster.includes('My Assigned Crew'), 'Foreman Crew Time options must identify assigned crew members first.');
assert(index.includes('window.openLineCrewTimekeeping({ focusRoster:true })'), 'Team must provide an obvious Manage Foreman Crews path.');
assert(timekeeping.includes("employees.filter(e=>e.active&&e.assigned_foreman_id===viewerId).forEach"), 'Foreman Daily Reports must directly preload assigned crew members.');
assert(!timekeepingRoster.includes('addButton.click();'), 'Assigned crew preload must not depend on overlay click timing.');
assert(expandedJsa.includes("load('timekeeping.js?v=20260823g'"), 'Direct Foreman crew preload must use a fresh cache version.');
assert(timekeepingRoster.includes('await autoLoadAssignedCrew();'), 'Foreman roster selectors must wait for assigned crew data before rebuilding employee options.');
assert(expandedJsa.includes("load('number-input-polish.js?v=20260823a'"), 'Global numeric input polish must be cache-versioned and loaded.');
assert(numberInputPolish.includes("input.defaultValue === '0'"), 'Only numeric fields designed with a zero default may restore an empty value to zero.');
assert(numberInputPolish.includes('input.select();'), 'Clicking a displayed zero must select it for immediate replacement.');
assert(index.includes('await saveDailyUnitBatch({ closeAfterSave:true })'), 'Done Adding Units must await the pending unit save before closing.');
assert(index.includes("doneButton.textContent = 'Saving & Finishing...'"), 'Done Adding Units must show an in-progress save state.');
assert(index.includes('if(currentDailySavedUnits.length === 0)'), 'Done Adding Units must not close an empty unit report.');
assert(expandedJsa.includes("load('app-polish.js?v=20260823b'"), 'Done Adding Units workflow must load the current app polish asset.');
assert(index.includes('<h3>Saved Units</h3>'), 'Edit Draft must show persisted units before the blank Add More Units rows.');
assert(index.includes("doneButton.textContent = 'Done Adding Units';"), 'The Done Adding Units button must reset whenever its editor opens or closes.');
assert(index.includes('<option value="transfer">Transfer</option>'), 'Daily unit production must offer Transfer as an explicit work type.');
assert(index.includes('row.actionInput.value = inferredWorkType;'), 'Selecting a priced unit must automatically choose its inferred work type.');
assert(index.includes("if(suffix === 'R') return 'retirement';"), 'R-suffix units must default to removal when pricing alone is ambiguous.');
assert(index.includes("if(suffix === 'T') return 'transfer';"), 'T-suffix units must default to transfer when pricing alone is ambiguous.');
assert(index.includes("savedWorkType === 'transfer'"), 'Saved T-unit quantities must be labeled as Transferred rather than Installed.');
assert(index.includes("if(role === 'gf') return false;"), 'GF review access must not imply permission to edit a Foreman draft.');
assert(index.includes('DRAFT — WAITING FOR FOREMAN'), 'GF draft cards must clearly explain that they are awaiting Foreman submission.');
assert(index.includes("doneButton.textContent = canEditDraft ? 'Done Adding Units' : 'Back to Reports';"), 'The unit editor must switch to a read-only reviewer exit for GF users.');
assert(index.includes("$('dailyUnitEntryControls').classList.toggle('hidden', !canEditDraft);"), 'Daily unit entry controls must be hidden from read-only reviewers.');
assert(index.includes("if(reportStatus === 'draft' && canEditDraft)"), 'Edit and Submit controls must render only for users allowed to edit that draft.');
assert(index.includes("[report?.created_by, report?.foreman_id]"), 'Returned Foreman drafts must recognize both the report creator and assigned Foreman ownership fields.');
assert(index.includes("created_by,\n      work_date"), 'Production report loading must include the creator used to restore returned-draft editing.');
assert(expandedJsa.includes('id,job_id,foreman_id,created_by,work_date,status'), 'The returned-report correction loader must preserve Foreman ownership fields for unit editing.');
assert(index.includes('expanded-jsa.js?v=20260823d'), 'The returned-report correction fix must use a cache-busted script version.');

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
assert(index.includes('dailyReportValueSummaryMarkup(report, valueSummary)'), 'Production cards must calculate run rates from each report’s own hours.');
assert(index.includes("'<br>Actual MH Run Rate: <strong>'"), 'Supervision report cards must show the actual man-hour run rate when actual pricing is permitted.');
assert(index.includes("'<br>Field MH Run Rate: <strong>'"), 'Supervision report cards must show the field man-hour run rate.');
for (const marker of [
  "v_role = 'foreman' and report.foreman_id = auth.uid()",
  'delete from public.timekeeping_entries entry',
  "lower(coalesce(report.status, 'draft')) = 'draft'",
  'revoke all on function public.delete_draft_daily_report(uuid) from public, anon'
]) assert(foremanDraftDeletion.includes(marker), `Foreman draft-deletion marker missing: ${marker}`);
assert(index.includes("currentUserRole() === 'foreman' && report.foreman_id === currentProfile.id"), 'Foremen must see Delete Draft only on their own reports.');

for (const role of ['foreman', 'gf', 'superintendent', 'admin', 'owner']) assert(roleMigration.includes(`'${role}'`), `Role migration is missing ${role}.`);
assert(roleMigration.includes('drop constraint if exists profiles_role_supported'), 'Role migration must replace the legacy three-role constraint.');
assert(roleMigration.includes('linecrew_claim_initial_owner'), 'Role migration must provide a safe initial Owner claim path.');
assert(roleMigration.includes('linecrew_set_member_role'), 'Role migration must centralize role changes.');
assert(roleMigration.includes('Only an Owner can manage Owner or Admin roles'), 'Admins must not be able to manage Owners or peer Admins.');
assert(roleMigration.includes('Assign another Owner before removing the last Owner'), 'The last Owner must be protected from removal.');
assert(roleMigration.includes('A Superintendent can manage General Foreman and Foreman roles only'), 'Superintendent delegated role management must stop above GF/Foreman.');
assert(roleMigration.includes("role_permissions ->> 'role_management'"), 'Superintendent role-management capability must be enforced server-side.');
assert(roleMigration.includes('linecrew_set_superintendent_permissions'), 'Superintendent permission overrides must be server-enforced.');
assert(roleMigration.includes("jsonb_typeof(item.value) <> 'boolean'"), 'Superintendent overrides must accept boolean values only.');
assert(roleMigration.includes('actor.active is not true'), 'Role-management RPCs must reject suspended leadership profiles.');
assert(roleMigration.includes('and p.active is true'), 'Capability checks must reject suspended profiles.');

assert(accessMigration.includes('set_company_member_active'), 'Team access changes need a secured hierarchy RPC.');
assert(accessMigration.includes("target_role in ('owner','admin')"), 'Admins must not suspend Owners or peer Admins.');
assert(accessMigration.includes("target_role not in ('foreman','gf')"), 'Superintendents must not suspend peers or higher roles.');
assert(accessMigration.includes('Assign another active Owner before suspending the last Owner'), 'The final active Owner must be protected from suspension.');

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
assert(expandedJsa.includes("load('app-polish.js?v=20260823b')"), 'app-polish.js must use the current cache-busting version.');

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
  "sb.functions.invoke(\n      'complete-team-invitation-signup'",
  'sb.auth.signInWithPassword({ email, password })',
  "$('loginCard').classList.toggle('hidden', invited)",
  "$('signupEmail').readOnly = invited",
  "await sb.auth.signOut({ scope:'local' })",
  'async function startApp()',
  "$('createCompanyCard').classList.toggle('hidden', invited)",
  "$('joinCompanyCard').classList.toggle('hidden', invited)",
  'id="newPriceBookImportFile"',
  'Save Price Book &amp; Continue',
  'await handlePriceBookImportFile(selectedImportFile)',
  'Review the unit-pricing preview'
]) assert(index.includes(marker), `Onboarding workflow marker missing: ${marker}`);

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
console.log('- First-run Price Book upload workflow present');
console.log('- Foreman job visibility is assignment-scoped with manager and timestamp audit history');
console.log('- Supervisor job-progress cards list every assigned Foreman / Job Leader');
console.log('- Field employees are leadership-assigned; Foremen can add extra active crew only on assigned jobs');
console.log('- Timekeeping reports use a single-flight guard to prevent repeated Run Report loops');
console.log('- Crew selectors avoid observer feedback loops on the Foreman Production screen');
