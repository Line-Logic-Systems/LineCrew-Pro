import fs from 'node:fs';
import vm from 'node:vm';

const moduleSource = fs.readFileSync('production-core.js','utf8');
const bootstrap = fs.readFileSync('number-input-polish.js','utf8');
const index = fs.readFileSync('index.html','utf8');
const serviceWorker = fs.readFileSync('service-worker.js','utf8');

const sandbox = { window:{} };
vm.runInNewContext(moduleSource, sandbox, { filename:'production-core.js' });
const core = sandbox.window.LineCrewProductionCore;
for (const name of ['reportUtilityKey','groupReportsByContractJob']) {
  if (!core || typeof core[name] !== 'function') throw new Error(`Production core module must expose ${name}().`);
}

for (const [input, expected] of [
  [{ jobs:{ contracts:{ customers:{ id:'utility-123' } } } }, 'utility-123'],
  [{ jobs:{ contracts:{ customers:{} } } }, 'unassigned'],
  [{}, 'unassigned'],
  [null, 'unassigned']
]) {
  const actual = core.reportUtilityKey(input);
  if (actual !== expected) throw new Error(`reportUtilityKey() returned ${actual}; expected ${expected}.`);
}

const reportA = { id:'r1', job_id:'job-b', jobs:{ job_number:'200', job_name:'Beta', contracts:{ id:'contract-b', contract_number:'20', contract_name:'South' } } };
const reportB = { id:'r2', job_id:'job-a', jobs:{ job_number:'100', job_name:'Alpha', contracts:{ id:'contract-a', contract_number:'10', contract_name:'North' } } };
const reportC = { id:'r3', job_id:'job-a', jobs:{ job_number:'100', job_name:'Alpha', contracts:{ id:'contract-a', contract_number:'10', contract_name:'North' } } };
const reportD = { id:'r4', jobs:{} };
const grouped = core.groupReportsByContractJob([reportA, reportB, reportC, reportD]);
if (grouped.length !== 3) throw new Error(`Expected 3 contract groups; got ${grouped.length}.`);
if (grouped[0].label !== '10 — North' || grouped[1].label !== '20 — South' || grouped[2].label !== 'No Contract Assigned') {
  throw new Error('Contract labels/sort behavior changed.');
}
const north = grouped[0];
if (north.reports.length !== 2 || north.jobs.length !== 1) throw new Error('Contract report/job grouping changed.');
if (north.jobs[0].label !== '100 — Alpha' || north.jobs[0].reports.length !== 2) throw new Error('Job label/grouping behavior changed.');
if (grouped[2].jobs[0].label !== 'No Job Assigned') throw new Error('Unassigned job fallback label changed.');
if (core.groupReportsByContractJob(null).length !== 0) throw new Error('Null report input must produce an empty grouping.');

if (sandbox.window.productionReportUtilityKey !== core.reportUtilityKey) {
  throw new Error('Production utility-key compatibility bridge is not active.');
}
if (sandbox.window.productionGroupReportsByContractJob !== core.groupReportsByContractJob) {
  throw new Error('Production grouping compatibility bridge is not active.');
}
if (!bootstrap.includes("script.src = '/production-core.js?v=20260910a'")) {
  throw new Error('Production core module is not bootstrapped by the existing front-end loader path.');
}
if (!bootstrap.includes('Production core module unavailable; using inline compatibility fallback.')) {
  throw new Error('Production core loader must retain an explicit inline fallback path.');
}
if (!serviceWorker.includes("'/production-core.js?v=20260910a'")) {
  throw new Error('Production core module must remain in the offline app shell.');
}
if (!index.includes('function productionReportUtilityKey(report){') ||
    !index.includes("return String(report.jobs?.contracts?.customers?.id || 'unassigned');")) {
  throw new Error('Legacy inline Production utility-key fallback must remain during staged extraction.');
}
for (const marker of [
  "const contractKey = String(contract.id || 'no-contract');",
  "label:[contract.contract_number, contract.contract_name].filter(Boolean).join(' — ') || 'No Contract Assigned'",
  "const jobKey = String(report.job_id || 'no-job');",
  "label:[report.jobs?.job_number, report.jobs?.job_name].filter(Boolean).join(' — ') || 'No Job Assigned'",
  ".sort((a, b) => a.label.localeCompare(b.label))"
]) {
  if (!index.includes(marker)) throw new Error(`Legacy Production grouping behavior marker missing: ${marker}`);
}

console.log('Production core modularization guard passed.');
console.log('- utility-key behavior matches legacy behavior');
console.log('- contract/job grouping labels, sort order, and report membership are parity-tested');
console.log('- compatibility bridges are active');
console.log('- module is available offline');
console.log('- inline renderer behavior remains available while staged rollout continues');
