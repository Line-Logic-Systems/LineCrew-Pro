import fs from 'node:fs';
import vm from 'node:vm';

const moduleSource = fs.readFileSync('jobs-core.js','utf8');
const index = fs.readFileSync('index.html','utf8');
const sandbox = { window:{} };
vm.runInNewContext(moduleSource, sandbox, { filename:'jobs-core.js' });
const core = sandbox.window.LineCrewJobsCore;

if (!core || typeof core.jobProgressRowViewModel !== 'function') {
  throw new Error('Jobs core module must expose jobProgressRowViewModel().');
}
if (sandbox.window.jobProgressRowViewModel !== core.jobProgressRowViewModel) {
  throw new Error('jobProgressRowViewModel compatibility bridge is not active.');
}

const activeJob = {id:'job-1',active:true};
const closedJob = {id:'job-2',active:false};

const assigned = core.jobProgressRowViewModel(
  activeJob,
  {package_count:'2',work_point_count:'15'},
  [{full_name:'Alex Foreman'},{full_name:'Jamie Leader'}],
  {role:'admin',profileName:'Admin User'}
);
if (assigned.statusText !== 'ACTIVE' || assigned.statusClass !== 'active') throw new Error('Active Jobs row status changed.');
if (assigned.assignmentLabel !== 'Alex Foreman, Jamie Leader') throw new Error('Assigned leader label changed.');
if (assigned.packageCount !== 2 || assigned.workPointCount !== 15) throw new Error('Jobs row setup counts changed.');

const foremanFallback = core.jobProgressRowViewModel(activeJob,{},[],{role:'foreman',profileName:'Taylor Foreman'});
if (foremanFallback.assignmentLabel !== 'Taylor Foreman') throw new Error('Foreman self-assignment fallback changed.');

const foremanGeneric = core.jobProgressRowViewModel(activeJob,{},[],{role:'foreman'});
if (foremanGeneric.assignmentLabel !== 'Assigned to you') throw new Error('Generic Foreman assignment fallback changed.');

const leadershipFallback = core.jobProgressRowViewModel(closedJob,{},null,{role:'admin'});
if (leadershipFallback.assignmentLabel !== 'Unassigned') throw new Error('Leadership unassigned fallback changed.');
if (leadershipFallback.statusText !== 'CLOSED' || leadershipFallback.statusClass !== 'closed') throw new Error('Closed Jobs row status changed.');
if (leadershipFallback.packageCount !== 0 || leadershipFallback.workPointCount !== 0) throw new Error('Missing Jobs setup counts must remain zero.');

for (const marker of [
  'const summary = currentJobProgressSummaries.get(job.id) || {};',
  'const assignments = currentJobLeaderAssignments.get(job.id) || [];',
  'const assignedNames = assignments.map(assignment => assignment.full_name);',
  "const assignmentLabel = assignedNames.length",
  "? assignedNames.join(', ')",
  ": (currentUserRole() === 'foreman' ? (currentProfile?.full_name || 'Assigned to you') : 'Unassigned');",
  "'<span class=\"status ' + (job.active === true ? 'active' : 'closed') + '\">' + (job.active === true ? 'ACTIVE' : 'CLOSED') + '</span></div>' +",
  "Number(summary.package_count || 0)",
  "Number(summary.work_point_count || 0)"
]) {
  if (!index.includes(marker)) throw new Error(`Legacy Jobs progress-row behavior marker missing: ${marker}`);
}

console.log('Jobs progress row view-model guard passed.');
console.log('- status text/classes match legacy behavior');
console.log('- assigned leader labels and Foreman fallbacks match legacy behavior');
console.log('- job-jacket and work-point counts preserve numeric coercion/defaults');
console.log('- live Jobs progress row renderer remains unchanged');
