import fs from 'node:fs';

function read(path){
  if(!fs.existsSync(path)) throw new Error(`Missing required workflow file: ${path}`);
  return fs.readFileSync(path,'utf8');
}
function requireMatch(text, pattern, message){
  if(!pattern.test(text)) throw new Error(message);
}
function requireText(text, needle, message){
  if(!text.includes(needle)) throw new Error(message);
}

const payroll = read('timekeeping-payroll.js');
const history = read('timekeeping-pay-period-history.js');
const roster = read('timekeeping-roster.js');
const gfScope = read('gf-crew-scope.js');
const polish = read('app-polish.js');
const index = read('index.html');
const weeklyMigration = read('supabase/migrations/archive/20260826_weekly_ot_company_week_start_and_draft_cleanup.sql');
const adminEditMigration = read('supabase/migrations/archive/20260826070000_admin_timekeeping_edits.sql');
const gfMigration = read('supabase/migrations/archive/20260826090000_gf_foreman_scope_and_scoped_jsas.sql');
const hardeningMigration = read('supabase/migrations/archive/20260826101500_post_e2e_timekeeping_hardening.sql');

// Payroll rules exercised in the full field -> GF -> Admin test.
requireText(payroll, 'total>24', 'Payroll exception guard must only flag impossible >24-hour days.');
requireText(payroll, "type:'crew-hours'", 'Crew-hour mismatch exception must remain enabled.');
requireText(payroll, "rpc('timekeeping_set_period_status'", 'Pay-period state changes must stay behind the guarded RPC.');
requireText(payroll, 'Lock Pay Period', 'The final payroll action must remain labeled Lock Pay Period.');
requireText(payroll, 'Approved time automatically returns to Open', 'Approved-period edit behavior must remain visible to Admin.');

// Long-term payroll history must remain paged/filterable instead of loading years at once.
requireMatch(history, /25/, 'Pay-period history must retain bounded pagination.');
requireMatch(history, /year|date range|from|through/i, 'Pay-period history must retain historical date filtering.');
requireMatch(history, /next|previous/i, 'Pay-period history must retain pagination controls.');

// Weekly OT must be employee-specific and company-week aware in the database.
requireText(weeklyMigration, 'week_start_day', 'Company-configurable week start must remain in weekly OT logic.');
requireText(weeklyMigration, '40', 'Weekly OT threshold regression: expected 40-hour threshold.');
requireText(adminEditMigration, 'recalculate_timekeeping_employee_week', 'Admin edits must recalculate the employee week.');

// Equipment/personnel roster persistence and Foreman assignment path.
requireText(roster, "rpc('admin_import_timekeeping_roster'", 'Roster imports must remain server-validated.');
requireText(roster, 'assigned_foreman_id', 'Foreman crew assignments must remain part of roster loading.');

// GF scope must apply to both approvals and JSAs, with deliberate all-crews coverage.
requireText(gfScope, 'get_gf_crew_assignment_roster', 'GF crew assignment roster integration is missing.');
requireMatch(gfScope, /show all crews|showall|show_all/i, 'GF all-crews coverage control is missing.');
requireText(gfMigration, 'get_company_jsas_scoped', 'Scoped JSA database function is missing.');
requireText(gfMigration, 'gf_foreman_assignments', 'GF-to-Foreman assignment storage is missing.');

// JSA leadership viewer/history must remain available from Safety Reporting.
requireMatch(index, /Safety Reporting/i, 'Safety Reporting workspace is missing.');
requireMatch(index, /Print \/ Save PDF|Print.*PDF/i, 'Completed JSA Print/PDF action is missing.');

// Team search regression: controls are installed once, never inserted by the global observer.
requireText(polish, 'installTeamToolsOnce', 'Safe Team search installer is missing.');
const observerMatch = polish.match(/new MutationObserver\(\(\)=>\{([\s\S]*?)\}\)/);
if(observerMatch && observerMatch[1].includes('installTeamToolsOnce')){
  throw new Error('Team search must not insert DOM nodes from the global MutationObserver; this can freeze sign-in.');
}
requireText(polish, 'hookTeamLoader', 'Team filters must reapply from the Team loader hook.');

// Database hardening added after the live end-to-end test.
requireText(hardeningMigration, 'current_user_has_active_profile', 'Pay-period reads must require an active profile.');
requireText(hardeningMigration, 'revoke all on table public.timekeeping_pay_periods from anon', 'Anonymous pay-period table access must remain revoked.');
requireText(hardeningMigration, 'gf_foreman_assignments_foreman_id_idx', 'GF assignment scale index is missing.');
requireText(hardeningMigration, 'timekeeping_edit_audit_employee_id_idx', 'Time-edit audit scale index is missing.');

console.log('End-to-end regression guardrails passed.');
