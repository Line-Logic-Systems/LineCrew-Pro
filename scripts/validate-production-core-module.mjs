import fs from 'node:fs';
import vm from 'node:vm';

const moduleSource = fs.readFileSync('production-core.js','utf8');
const bootstrap = fs.readFileSync('number-input-polish.js','utf8');
const index = fs.readFileSync('index.html','utf8');
const serviceWorker = fs.readFileSync('service-worker.js','utf8');

let fallbackCalls = 0;
const sandbox = {
  window:{
    productionReportingTotals(reports){
      fallbackCalls += 1;
      return { legacyFallback:true, reports:Array.isArray(reports) ? reports.length : 0 };
    }
  }
};
vm.runInNewContext(moduleSource, sandbox, { filename:'production-core.js' });
const core = sandbox.window.LineCrewProductionCore;
for (const name of ['reportUtilityKey','groupReportsByContractJob','groupReportsByUtility','reportingTotals','runtimeReportingTotals']) {
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

const reportA = { id:'r1', job_id:'job-b', status:'approved', regular_hours:8, overtime_hours:2, jobs:{ job_number:'200', job_name:'Beta', contracts:{ id:'contract-b', contract_number:'20', contract_name:'South', customers:{ id:'utility-b', name:'Beta Utility' } } } };
const reportB = { id:'r2', job_id:'job-a', status:'submitted', regular_hours:'10', overtime_hours:'1', jobs:{ job_number:'100', job_name:'Alpha', contracts:{ id:'contract-a', contract_number:'10', contract_name:'North', customers:{ id:'utility-a', name:'Alpha Cooperative' } } } };
const reportC = { id:'r3', job_id:'job-a', status:'APPROVED', regular_hours:null, overtime_hours:0, jobs:{ job_number:'100', job_name:'Alpha', contracts:{ id:'contract-a', contract_number:'10', contract_name:'North', customers:{ id:'utility-a', name:'Alpha Cooperative' } } } };
const reportD = { id:'r4', jobs:{} };
const grouped = core.groupReportsByContractJob([reportA, reportB, reportC, reportD]);
if (grouped.length !== 3) throw new Error(`Expected 3 contract groups; got ${grouped.length}.`);
if (grouped[0].label !== '10 — North' || grouped[1].label !== '20 — South' || grouped[2].label !== 'No Contract Assigned') throw new Error('Contract labels/sort behavior changed.');
const north = grouped[0];
if (north.reports.length !== 2 || north.jobs.length !== 1) throw new Error('Contract report/job grouping changed.');
if (north.jobs[0].label !== '100 — Alpha' || north.jobs[0].reports.length !== 2) throw new Error('Job label/grouping behavior changed.');
if (grouped[2].jobs[0].label !== 'No Job Assigned') throw new Error('Unassigned job fallback label changed.');
if (core.groupReportsByContractJob(null).length !== 0) throw new Error('Null report input must produce an empty grouping.');

const archivedUtilityReport = { id:'r5', archived:true, jobs:{ contracts:{ customers:{ id:'utility-z', name:'Archived Utility' } } } };
const utilityGroups = core.groupReportsByUtility([reportA, reportB, reportC, reportD, archivedUtilityReport]);
if (utilityGroups.length !== 3) throw new Error(`Expected 3 visible utility groups; got ${utilityGroups.length}.`);
if (utilityGroups[0].name !== 'Alpha Cooperative' || utilityGroups[1].name !== 'Beta Utility' || utilityGroups[2].name !== 'No Utility / Cooperative Assigned') throw new Error('Utility label/sort behavior changed.');
if (utilityGroups[0].reports.length !== 2 || utilityGroups[1].reports.length !== 1 || utilityGroups[2].reports.length !== 1) throw new Error('Utility report membership changed.');
if (utilityGroups.some(group => group.id === 'utility-z')) throw new Error('Archived reports must remain excluded from the utility directory.');
if (core.groupReportsByUtility(null).length !== 0) throw new Error('Null utility input must produce an empty grouping.');

const valueSummaries = new Map([
  ['r1',{ actual_total:1200.5, adjusted_total:1100 }],
  ['r2',{ actual_total:'300', adjusted_total:'275.25' }],
  ['r3',{ actual_total:null, adjusted_total:25 }]
]);
const authorizationSummaries = new Map([
  ['r1',{ redline_count:1, pending_packet_count:2 }],
  ['r2',{ redline_count:'2', pending_packet_count:'1' }],
  ['r3',{ redline_count:0, pending_packet_count:3 }]
]);
const expectedTotals = { reports:4, approved:2, actualValue:1500.5, fieldValue:1400.25, regularHours:18, overtimeHours:3, redlines:3, pending:6 };
const totals = core.reportingTotals([reportA, reportB, reportC, reportD], valueSummaries, authorizationSummaries);
if (JSON.stringify(totals) !== JSON.stringify(expectedTotals)) throw new Error(`Production totals parity failed: ${JSON.stringify(totals)} != ${JSON.stringify(expectedTotals)}.`);
const emptyTotals = core.reportingTotals(null);
if (JSON.stringify(emptyTotals) !== JSON.stringify({reports:0,approved:0,actualValue:0,fieldValue:0,regularHours:0,overtimeHours:0,redlines:0,pending:0})) throw new Error('Null Production totals input must return zero totals.');

// Runtime handoff must fall back to the captured inline implementation when summary dependencies are unavailable.
const fallbackResult = sandbox.window.productionReportingTotals([reportA, reportB]);
if (!fallbackResult?.legacyFallback || fallbackResult.reports !== 2 || fallbackCalls !== 1) {
  throw new Error('Production totals runtime handoff did not preserve the inline fallback path.');
}

// With the live summary maps available, the runtime bridge must use the module calculation and not the legacy fallback.
let unexpectedLegacyCalls = 0;
const runtimeSandbox = {
  window:{
    productionReportingTotals(){
      unexpectedLegacyCalls += 1;
      return { legacyFallback:true };
    }
  },
  currentDailyReportValueSummaries:valueSummaries,
  currentDailyAuthorizationSummaries:authorizationSummaries
};
vm.runInNewContext(moduleSource, runtimeSandbox, { filename:'production-core-runtime.js' });
const runtimeTotals = runtimeSandbox.window.productionReportingTotals([reportA, reportB, reportC, reportD]);
if (JSON.stringify(runtimeTotals) !== JSON.stringify(expectedTotals)) throw new Error('Production totals runtime bridge changed calculated totals.');
if (unexpectedLegacyCalls !== 0) throw new Error('Production totals runtime bridge incorrectly used the legacy fallback with dependencies available.');

for (const [bridge, fn] of [
  ['productionReportUtilityKey', core.reportUtilityKey],
  ['productionGroupReportsByContractJob', core.groupReportsByContractJob],
  ['productionGroupReportsByUtility', core.groupReportsByUtility],
  ['productionReportingTotalsCore', core.reportingTotals],
  ['productionReportingTotals', core.runtimeReportingTotals]
]) {
  if (sandbox.window[bridge] !== fn) throw new Error(`Production compatibility bridge ${bridge} is not active.`);
}
if (!bootstrap.includes("script.src = '/production-core.js?v=20260910a'")) throw new Error('Production core module is not bootstrapped by the existing front-end loader path.');
if (!bootstrap.includes('Production core module unavailable; using inline compatibility fallback.')) throw new Error('Production core loader must retain an explicit inline fallback path.');
if (!serviceWorker.includes("'/production-core.js?v=20260910a'")) throw new Error('Production core module must remain in the offline app shell.');
if (!index.includes('function productionReportUtilityKey(report){') || !index.includes("return String(report.jobs?.contracts?.customers?.id || 'unassigned');")) throw new Error('Legacy inline Production utility-key fallback must remain during staged extraction.');
for (const marker of [
  "const contractKey = String(contract.id || 'no-contract');",
  "label:[contract.contract_number, contract.contract_name].filter(Boolean).join(' — ') || 'No Contract Assigned'",
  "const jobKey = String(report.job_id || 'no-job');",
  "label:[report.jobs?.job_number, report.jobs?.job_name].filter(Boolean).join(' — ') || 'No Job Assigned'",
  ".filter(report => report.archived !== true)",
  "name:String(utility.name || 'No Utility / Cooperative Assigned')",
  'function productionReportingTotals(reports){',
  'totals.actualValue += Number(value.actual_total || 0);',
  'totals.fieldValue += Number(value.adjusted_total || 0);',
  'totals.redlines += Number(authorization.redline_count || 0);',
  'totals.pending += Number(authorization.pending_packet_count || 0);'
]) {
  if (!index.includes(marker)) throw new Error(`Legacy Production behavior marker missing: ${marker}`);
}

console.log('Production core modularization guard passed.');
console.log('- utility, contract/job grouping, and report totals match legacy behavior');
console.log('- live Production totals handoff uses module summaries when available');
console.log('- captured inline Production totals remain an automatic runtime fallback');
console.log('- module remains offline-capable and legacy inline code remains present');
