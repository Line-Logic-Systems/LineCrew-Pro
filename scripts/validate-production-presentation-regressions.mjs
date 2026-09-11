import fs from 'node:fs';

const index = fs.readFileSync('index.html','utf8');

const required = [
  'function productionReportingTotals(reports){',
  'reports:reports.length,',
  'actualValue:0,',
  'fieldValue:0,',
  'regularHours:0,',
  'overtimeHours:0,',
  'redlines:0,',
  'pending:0',
  "if(String(report.status || '').toLowerCase() === 'approved') totals.approved += 1;",
  'function productionReportingMetricsMarkup(reports, wrapperTag = \'div\'){',
  'userCanSeeActualContractPrices()',
  'userCanSeeFieldMoney()',
  'Actual Unit Value',
  'Field Unit Value',
  'Regular Hours',
  'OT Hours',
  'Redlines',
  'Pending Job Units',
  'function productionUtilityPrimaryMetricsMarkup(reports){',
  "String(report.status || '').toLowerCase() === 'submitted'",
  "const activeJobCount = new Set(reports.filter(report => report.jobs?.active === true).map(report => String(report.job_id)).filter(Boolean)).size;",
  'Awaiting Review',
  'Active Jobs',
  'MH Rate',
  'function renderProductionReportingSummary(reports, canViewProductionReporting){',
  "details.className = 'production-contract-summary';",
  "'<strong>Jobs</strong>' +",
  'productionReportingMetricsMarkup(contract.reports)',
  'productionReportingMetricsMarkup(job.reports)',
  'function productionReportUtilityKey(report){',
  "return String(report.jobs?.contracts?.customers?.id || 'unassigned');",
  'function renderProductionUtilityDirectory(reports){',
  '.filter(report => report.archived !== true)',
  "name:String(utility.name || 'No Utility / Cooperative Assigned')",
  "view:'utilityProduction'"
];

for (const marker of required) {
  if (!index.includes(marker)) throw new Error(`Production presentation regression marker missing: ${marker}`);
}

console.log('Production presentation regression fence passed.');
console.log('- report totals retain approved/value/hour/redline/pending calculations');
console.log('- money visibility remains gated by actual/field permissions');
console.log('- utility summary retains awaiting-review, active-jobs and MH-rate metrics');
console.log('- production summary remains grouped contract -> jobs');
console.log('- archived reports remain excluded from the utility directory');
