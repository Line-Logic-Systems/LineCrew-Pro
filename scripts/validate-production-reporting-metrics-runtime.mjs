import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync('production-core.js','utf8');
const reports = [
  {id:'r1',status:'approved',regular_hours:8,overtime_hours:2},
  {id:'r2',status:'submitted',regular_hours:10,overtime_hours:1}
];
const values = new Map([
  ['r1',{actual_total:1200.5,adjusted_total:1100}],
  ['r2',{actual_total:300,adjusted_total:275.25}]
]);
const auth = new Map([
  ['r1',{redline_count:1,pending_packet_count:2}],
  ['r2',{redline_count:2,pending_packet_count:1}]
]);

let fallbackCalls = 0;
const fallbackSandbox = {
  window:{
    productionReportingTotals(){ return {legacyTotals:true}; },
    productionReportingMetricsMarkup(input,wrapperTag){
      fallbackCalls += 1;
      return `LEGACY:${wrapperTag}:${input.length}`;
    },
    productionUtilityPrimaryMetricsMarkup(){ return 'LEGACY-PRIMARY'; }
  }
};
vm.runInNewContext(source,fallbackSandbox,{filename:'production-reporting-fallback.js'});
const fallback = fallbackSandbox.window.productionReportingMetricsMarkup(reports,'span');
if (fallback !== 'LEGACY:span:2' || fallbackCalls !== 1) {
  throw new Error('Reporting metrics runtime bridge did not preserve the captured inline fallback and wrapper tag.');
}

let unexpectedFallbackCalls = 0;
const runtimeSandbox = {
  window:{
    productionReportingTotals(){ return {legacyTotals:true}; },
    productionReportingMetricsMarkup(){
      unexpectedFallbackCalls += 1;
      return 'LEGACY';
    },
    productionUtilityPrimaryMetricsMarkup(){ return 'LEGACY-PRIMARY'; }
  },
  currentDailyReportValueSummaries:values,
  currentDailyAuthorizationSummaries:auth,
  userCanSeeActualContractPrices:() => true,
  userCanSeeFieldMoney:() => true,
  formatCurrency:value => '$' + Number(value).toFixed(2),
  escapeHtml:value => 'ESC(' + String(value) + ')'
};
vm.runInNewContext(source,runtimeSandbox,{filename:'production-reporting-runtime.js'});
const actual = runtimeSandbox.window.productionReportingMetricsMarkup(reports,'span');
const expected = '<span class="daily-value-summary production-reporting-group-metrics">' +
  '<span><strong>2</strong><br>Reports</span>' +
  '<span><strong>1</strong><br>Completed</span>' +
  '<span><strong>ESC($1500.50)</strong><br>Actual Unit Value</span>' +
  '<span><strong>ESC($1375.25)</strong><br>Field Unit Value</span>' +
  '<span><strong>18</strong><br>Regular Hours</span>' +
  '<span><strong>3</strong><br>OT Hours</span>' +
  '<span><strong>3</strong><br>Redlines</span>' +
  '<span><strong>3</strong><br>Pending Job Units</span>' +
  '</span>';
if (actual !== expected) throw new Error(`Reporting metrics runtime output changed: ${actual}`);
if (unexpectedFallbackCalls !== 0) throw new Error('Reporting metrics runtime bridge used legacy fallback despite complete dependencies.');
if (runtimeSandbox.window.LineCrewProductionCore.runtimeReportingMetricsMarkup !== runtimeSandbox.window.productionReportingMetricsMarkup) {
  throw new Error('Reporting metrics runtime bridge is not active.');
}

const throwingSandbox = {
  window:{
    productionReportingTotals(){ return {legacyTotals:true}; },
    productionReportingMetricsMarkup(){ return 'SAFE-REPORTING-FALLBACK'; },
    productionUtilityPrimaryMetricsMarkup(){ return 'LEGACY-PRIMARY'; }
  },
  currentDailyReportValueSummaries:values,
  currentDailyAuthorizationSummaries:auth,
  userCanSeeActualContractPrices:() => { throw new Error('permission helper unavailable'); },
  userCanSeeFieldMoney:() => false,
  formatCurrency:value => String(value),
  escapeHtml:value => String(value)
};
vm.runInNewContext(source,throwingSandbox,{filename:'production-reporting-throw-fallback.js'});
if (throwingSandbox.window.productionReportingMetricsMarkup(reports,'div') !== 'SAFE-REPORTING-FALLBACK') {
  throw new Error('Reporting metrics runtime bridge must fall back when a dependency throws.');
}

console.log('Production reporting metrics runtime handoff guard passed.');
console.log('- tested module-owned reporting markup path');
console.log('- tested wrapper-tag preservation through legacy fallback');
console.log('- tested missing/thrown dependency fallback behavior');
