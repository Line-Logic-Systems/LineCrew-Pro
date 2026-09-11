import fs from 'node:fs';
import vm from 'node:vm';

const moduleSource = fs.readFileSync('jobs-core.js','utf8');
const index = fs.readFileSync('index.html','utf8');
const sandbox = { window:{} };
vm.runInNewContext(moduleSource, sandbox, { filename:'jobs-core.js' });
const core = sandbox.window.LineCrewJobsCore;
if (!core || typeof core.jobAssignmentPanelViewModel !== 'function') {
  throw new Error('Jobs core must expose jobAssignmentPanelViewModel().');
}
if (typeof core.jobAssignmentRowViewModel !== 'function') {
  throw new Error('Jobs core must expose jobAssignmentRowViewModel().');
}

const assignments = [
  { member_id:'m1', full_name:'Foreman One', member_role:'foreman' },
  { member_id:'m2', full_name:'GF Two', member_role:'gf' }
];
const leaders = [
  { member_id:'m1', full_name:'Foreman One', member_role:'foreman' },
  { member_id:'m2', full_name:'GF Two', member_role:'gf' },
  { member_id:'m3', full_name:'Foreman Three', member_role:'foreman' }
];
const populated = core.jobAssignmentPanelViewModel(assignments, leaders);
if (populated.assignments !== assignments) throw new Error('Assignment panel must preserve the current assignment list.');
if (populated.available.length !== 1 || populated.available[0]?.member_id !== 'm3') throw new Error('Assigned leaders must remain excluded from available choices.');
if (populated.isEmpty !== false) throw new Error('Populated assignment panels must not be marked empty.');
if (populated.assignButtonLabel !== 'Assign Another Foreman / Leader') throw new Error('Additional-assignment button label changed.');

const empty = core.jobAssignmentPanelViewModel([], leaders);
if (empty.assignments.length !== 0 || empty.available.length !== 3) throw new Error('Empty assignment panels must expose all assignable leaders.');
if (empty.isEmpty !== true) throw new Error('Empty assignment panels must preserve the empty state.');
if (empty.assignButtonLabel !== 'Assign Foreman / Leader') throw new Error('Initial assignment button label changed.');

const nullSafe = core.jobAssignmentPanelViewModel(null, null);
if (nullSafe.assignments.length !== 0 || nullSafe.available.length !== 0 || !nullSafe.isEmpty) throw new Error('Null assignment-panel input must remain safe and empty.');
if (sandbox.window.jobAssignmentPanelViewModel !== core.jobAssignmentPanelViewModel) throw new Error('Jobs assignment-panel compatibility bridge is not active.');

const datedRow = core.jobAssignmentRowViewModel({
  full_name:'Foreman One',
  member_role:'foreman',
  assigned_by_name:'Admin User',
  assigned_at:'2026-09-11T18:30:00Z'
});
if (datedRow.fullName !== 'Foreman One' || datedRow.memberRole !== 'foreman') throw new Error('Assignment row name/role mapping changed.');
if (!datedRow.hasAssignedAt || datedRow.assignedByName !== 'Admin User' || datedRow.assignedAt !== '2026-09-11T18:30:00Z') throw new Error('Assignment row audit-detail mapping changed.');

const unknownAssigner = core.jobAssignmentRowViewModel({
  full_name:'GF Two',
  member_role:'gf',
  assigned_at:'2026-09-11T19:00:00Z'
});
if (unknownAssigner.assignedByName !== 'Unknown Team Member') throw new Error('Assignment row missing-assigner fallback changed.');

const undatedRow = core.jobAssignmentRowViewModel({ full_name:'GF Two', member_role:'gf' });
if (undatedRow.hasAssignedAt || undatedRow.assignedByName !== '' || undatedRow.assignedAt !== '') throw new Error('Undated assignment rows must not invent audit detail.');
if (sandbox.window.jobAssignmentRowViewModel !== core.jobAssignmentRowViewModel) throw new Error('Jobs assignment-row compatibility bridge is not active.');

for (const marker of [
  'function renderJobLeaderAssignments(job, container){',
  'const assignments = currentJobLeaderAssignments.get(job.id) || [];',
  'const assignedIds = new Set(assignments.map(item => item.member_id));',
  'const available = currentJobAssignableLeaders.filter(',
  'leader => !assignedIds.has(leader.member_id)',
  "? 'Assign Another Foreman / Leader'",
  ": 'Assign Foreman / Leader';",
  "const assignmentDetail = assignment.assigned_at",
  "escapeHtml(assignment.assigned_by_name || 'Unknown Team Member')",
  "escapeHtml(formatAuditTimestamp(assignment.assigned_at))",
  'remove.onclick = () => changeJobLeaderAssignment(',
  'assign.onclick = () => changeJobLeaderAssignment('
]) {
  if (!index.includes(marker)) throw new Error(`Legacy Jobs assignment behavior marker missing: ${marker}`);
}

console.log('Jobs assignment-panel view-model guard passed.');
console.log('- assigned leaders remain excluded from available choices');
console.log('- assignment row audit display data matches the existing renderer');
console.log('- empty/populated labels match the existing renderer');
console.log('- live assign/unassign handlers remain inline and untouched');
