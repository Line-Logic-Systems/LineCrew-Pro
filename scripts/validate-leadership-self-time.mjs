import fs from 'node:fs';

function read(path) {
  if (!fs.existsSync(path)) throw new Error(`Missing leadership self-time file: ${path}`);
  return fs.readFileSync(path, 'utf8');
}

function requireText(text, value, message) {
  if (!text.includes(value)) throw new Error(message);
}

const module = read('leadership-my-time.js');
const loader = read('expanded-jsa.js');
const shell = read('service-worker.js');
const report = read('timekeeping-report-v2.js');
const customExport = read('custom-time-export.js');
const payroll = read('timekeeping-payroll.js');
const timekeeping = read('timekeeping.js');
const foremanTools = read('foreman-field-tools.js');
const migration = read('supabase/migrations/20260828172839_leadership_self_time.sql');
const managedMigration = read('supabase/migrations/20260828203148_leadership_add_other_people.sql');
const adminRosterMigration = read('supabase/migrations/20260829084727_admin_time_roster_assignments.sql');

if (module.includes('if (elapsed <= 0) elapsed += 1440;')) {
  throw new Error('Equal start and stop times must not be converted into a 24-hour shift.');
}
if ((module.match(/if \(elapsed < 0\) elapsed \+= 1440;/g) || []).length < 2) {
  throw new Error('Both leadership time calculators must only roll genuinely overnight shifts.');
}

for (const role of ['gf','superintendent','admin','owner']) {
  requireText(module, `'${role}'`, `My Time UI is missing the ${role} role.`);
  requireText(migration, `'${role}'`, `My Time database authorization is missing the ${role} role.`);
}

for (const field of [
  'myTimeDate','myTimeStart','myTimeStop','myTimeLunch','myTimeChargeType',
  'myTimeJob','myTimeLabor','myTimePerDiem','myTimeEquipment','myTimeNotes'
]) requireText(module, field, `My Time UI is missing ${field}.`);

for (const field of ['myTimePeopleWrap','myTimePersonSelect','myTimeAddPersonBtn','myTimePersonList']) {
  requireText(module, field, `My Time add-employee UI is missing ${field}.`);
}
for (const field of ['myTimeAdminRosterRows','my-time-admin-start','my-time-admin-stop','my-time-admin-lunch','my-time-admin-charge']) {
  requireText(module, field, `Admin roster rows are missing ${field}.`);
}

requireText(module, "rpc('upsert_my_leadership_time'", 'My Time must save through the guarded RPC.');
requireText(module, "rpc('upsert_leadership_employee_time'", 'Admin/GF added employees must save through the guarded employee RPC.');
requireText(module, "['gf','admin']", 'Only Admin and General Foreman may add other employees.');
requireText(module, 'assigned_admin_id === profile().id', 'Admin My Time must auto-load only the signed-in Admin roster.');
requireText(module, 'const targetEmployeeId = activeEmployeeId', 'Admin roster time must save one selected person at a time.');
requireText(module, 'These fields and hours belong only to this person.', 'My Time must explain that each person has independent hours.');
requireText(module, 'saveAdminRow(row)', 'Each Admin roster row must save independently.');
requireText(module, 'captureAdminRows()', 'Admin roster drafts must survive adding or editing another person.');
requireText(module, 'Start (24 hr)', 'My Time Start must use the Foreman-style 24-hour entry.');
requireText(module, 'Stop (24 hr)', 'My Time Stop must use the Foreman-style 24-hour entry.');
requireText(module, "digits.padStart(4,'0')", 'My Time must accept compact military entries such as 600 and 1630.');
requireText(module, 'normalizeMilitaryInput', 'My Time must normalize 24-hour input before saving.');
requireText(module, 'titleElement.textContent !== peopleTitle', 'My Time observer updates must not rewrite unchanged labels and freeze the app.');
requireText(module, 'helpElement.textContent !== peopleHelp', 'My Time observer help text must be mutation-idempotent.');
requireText(module, 'Regular and overtime are calculated automatically', 'My Time must explain automatic weekly OT.');
requireText(module, 'Recent My Time', 'My Time must provide editable recent history.');
requireText(module, 'data-my-time-edit', 'Recent My Time entries must be editable.');
requireText(timekeeping, 'id="timekeepingReportCard"', 'The company Time Report needs a stable card id.');
requireText(module, "byId('timekeepingReportCard')", 'My Time must insert before the actual Time Report card.');
requireText(foremanTools, "#timekeepingReportCard h3", 'Role labels must not overwrite the My Time heading.');

requireText(migration, 'alter column job_id drop not null', 'Overhead time must not require a fake job.');
requireText(migration, "entry_kind = 'leadership_self'", 'Leadership self-time rows must be explicitly typed.');
requireText(migration, 'timekeeping_entries_leadership_overhead_uidx', 'Duplicate overhead entries need a unique guard.');
requireText(migration, 'linked_profile_id = auth.uid()', 'The RPC must bind the payroll employee to the signed-in profile.');
requireText(migration, 'job.company_id = v_company_id and job.active is true', 'Job charges must be active and company-scoped.');
requireText(migration, 'private.recalculate_leadership_week', 'Leadership time must reuse company-week OT calculations.');
requireText(migration, "security invoker", 'The exposed My Time RPC/report must run with caller permissions.');
requireText(migration, "security definer\nset search_path = ''", 'The private weekly helper must pin an empty search path.');
requireText(migration, 'revoke all on function public.upsert_my_leadership_time', 'Anonymous/Public RPC execution must be revoked.');
requireText(migration, 'timekeeping_report_rows_v3', 'Payroll reports need the labor-code-aware report function.');
requireText(managedMigration, "v_role not in ('gf','admin')", 'The managed-time RPC must permit only GF and Admin.');
requireText(managedMigration, 'employee.company_id = v_company_id', 'Managed time must remain company-scoped.');
requireText(managedMigration, 'employee.active is true', 'Managed time must target only active employees.');
requireText(managedMigration, 'security invoker', 'Managed time must run with caller RLS permissions.');
requireText(managedMigration, 'revoke all on function public.upsert_leadership_employee_time', 'Managed time must not be executable by Public or anon.');
requireText(adminRosterMigration, 'add column if not exists assigned_admin_id', 'Personnel need a persistent Admin assignment.');
requireText(adminRosterMigration, "lower(coalesce(administrator.role, '')) = 'admin'", 'Admin assignments must target active same-company Admins.');
requireText(adminRosterMigration, 'timekeeping_employees_assigned_admin_idx', 'Admin roster lookup needs a covering index.');
requireText(adminRosterMigration, 'revoke all on function public.validate_timekeeping_employee_admin_assignment()', 'The assignment trigger function must not be directly executable.');
requireText(timekeeping, 'data-tk-admin', 'Personnel management must include an Assigned Admin control.');
requireText(timekeeping, "changes.assigned_admin_id=draft.assigned_admin_id||null", 'Personnel Admin assignments must persist through the batch-save action.');
requireText(timekeeping, "updateRosterDraft(select.dataset.tkAdmin,'assigned_admin_id',select.value)", 'Personnel Admin assignments must remain staged until the manager saves the batch.');
requireText(timekeeping, 'id="tkChargeFilter"', 'Time Report needs a Job/Overhead charge filter.');
requireText(timekeeping, 'id="tkLaborCodeFilter"', 'Time Report needs an overhead labor-code filter.');

requireText(loader, 'leadership-my-time.js?v=20260829d', 'The My Time module is not loaded.');
requireText(shell, '/leadership-my-time.js?v=20260829d', 'The My Time module is not in the offline app shell.');
requireText(report, "rpc('timekeeping_report_rows_v3'", 'The Time Report must include leadership self-time.');
requireText(customExport, "rpc('timekeeping_report_rows_v3'", 'Custom exports must include leadership self-time.');
requireText(report, 'r.labor_code', 'The Time Report must show overhead labor codes.');
requireText(customExport, 'row.labor_code', 'Custom exports must show overhead labor codes.');
requireText(payroll, 'r.labor_code', 'Payroll exports must show overhead labor codes.');
requireText(report, 'Overhead Charge Summary', 'The Time Report must group overhead hours by labor code.');
requireText(report, "byId('tkChargeFilter')", 'The Time Report must apply its charge filter.');
requireText(report, "byId('tkLaborCodeFilter')", 'The Time Report must apply its labor-code filter.');
requireText(customExport, "'Charge To'", 'Custom exports must identify Job versus Overhead charges.');
requireText(customExport, "'Overhead Labor Code'", 'Custom exports must include the overhead labor code explicitly.');

console.log('Leadership My Time guardrails passed.');
