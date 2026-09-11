import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync('production-core.js','utf8');
const sandbox = { window:{} };
vm.runInNewContext(source, sandbox, {filename:'production-reporting-metrics-markup.js'});
const core = sandbox.window.LineCrewProductionCore;
if (!core || typeof core.reportingMetricsMarkup !== 'function') {
  throw new Error('Production core must expose reportingMetricsMarkup().');
}

const reports = [
  {id:'r1',status:'approved',regular_hours:8,overtime_hours:2},
  {id:'r2',status:'submitted',regular_hours:'10',overtime_hours:'1'}
];
const values = new Map([
  ['r1',{actual_total:1200.5,adjusted_total:1100}],
  ['r2',{actual_total:300,adjusted_total:275.25}]
]);
const auth = new Map([
  ['r1',{redline_count:1,pending_packet_count:2}],
  ['r2',{redline_count:2,pending_packet_count:1}]
]);
const helpers = {
  formatCurrency:value => '$' + Number(value).toFixed(2),
  escapeHtml:value => 'ESC(' + String(value) + ')'
};

const both = core.reportingMetricsMarkup(reports,'div',values,auth,{showActual:true,showField:true},helpers);
const expectedBoth = '<div class="daily-value-summary production-reporting-group-metrics">' +
  '<span><strong>2</strong><br>Reports</span>' +
  '<span><strong>1</strong><br>Completed</span>' +
  '<span><strong>ESC($1500.50)</strong><br>Actual Unit Value</span>' +
  '<span><strong>ESC($1375.25)</strong><br>Field Unit Value</span>' +
  '<span><strong>18</strong><br>Regular Hours</span>' +
  '<span><strong>3</strong><br>OT Hours</span>' +
  '<span><strong>3</strong><br>Redlines</span>' +
  '<span><strong>3</strong><br>Pending Job Units</span>' +
  '</div>';
if (both !== expectedBoth) throw new Error(`Both-money Production metrics markup changed: ${both}`);

const noMoney = core.reportingMetricsMarkup(reports,'span',values,auth,{},helpers);
const expectedNoMoney = '<span class="daily-value-summary production-reporting-group-metrics">' +
  '<span><strong>2</strong><br>Reports</span>' +
  '<span><strong>1</strong><br>Completed</span>' +
  '<span><strong>18</strong><br>Regular Hours</span>' +
  '<span><strong>3</strong><br>OT Hours</span>' +
  '<span><strong>3</strong><br>Redlines</span>' +
  '<span><strong>3</strong><br>Pending Job Units</span>' +
  '</span>';
if (noMoney !== expectedNoMoney) throw new Error(`No-money Production metrics markup changed: ${noMoney}`);

const invalidWrapper = core.reportingMetricsMarkup([], 'section');
if (!invalidWrapper.startsWith('<div class="daily-value-summary production-reporting-group-metrics">')) {
  throw new Error('Production metrics wrapper-tag fallback changed.');
}
if (sandbox.window.productionReportingMetricsMarkupCore !== core.reportingMetricsMarkup) {
  throw new Error('Production reporting metrics markup compatibility bridge is not active.');
}

const index = fs.readFileSync('index.html','utf8');
for (const marker of [
  'function productionReportingMetricsMarkup(reports, wrapperTag = \'div\'){',
  "const tag = wrapperTag === 'span' ? 'span' : 'div';",
  "'<span><strong>' + totals.reports + '</strong><br>Reports</span>'",
  "'<span><strong>' + totals.approved + '</strong><br>Completed</span>'",
  "'<span><strong>' + totals.regularHours + '</strong><br>Regular Hours</span>'",
  "'<span><strong>' + totals.overtimeHours + '</strong><br>OT Hours</span>'",
  "'<span><strong>' + totals.redlines + '</strong><br>Redlines</span>'",
  "'<span><strong>' + totals.pending + '</strong><br>Pending Job Units</span>'"
]) {
  if (!index.includes(marker)) throw new Error(`Legacy reporting-metrics fallback marker missing: ${marker}`);
}

console.log('Production reporting metrics markup parity guard passed.');
console.log('- div/span wrapper behavior matches legacy behavior');
console.log('- Actual/Field money visibility and formatting are protected');
console.log('- report, completed, hours, redline, and pending metrics are protected');
console.log('- live inline renderer remains present and unchanged');
