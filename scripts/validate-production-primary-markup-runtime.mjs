import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync('production-core.js','utf8');

const reports = [
  { id:'r1', job_id:'job-1', status:'approved', regular_hours:8, overtime_hours:2, jobs:{active:true} },
  { id:'r2', job_id:'job-2', status:'submitted', regular_hours:10, overtime_hours:1, jobs:{active:true} }
];
const values = new Map([
  ['r1',{actual_total:1200.5, adjusted_total:1100}],
  ['r2',{actual_total:300, adjusted_total:275.25}]
]);
const auth = new Map();

let fallbackMarkupCalls = 0;
const fallbackSandbox = {
  window:{
    productionReportingTotals(){ return {legacyTotals:true}; },
    productionUtilityPrimaryMetricsMarkup(input){
      fallbackMarkupCalls += 1;
      return `LEGACY:${input.length}`;
    }
  }
};
vm.runInNewContext(source, fallbackSandbox, {filename:'production-core-fallback.js'});
const fallback = fallbackSandbox.window.productionUtilityPrimaryMetricsMarkup(reports);
if (fallback !== 'LEGACY:2' || fallbackMarkupCalls !== 1) {
  throw new Error('Primary metrics markup runtime bridge did not preserve the captured inline fallback.');
}
if (fallbackSandbox.window.LineCrewProductionCore.runtimeUtilityPrimaryMetricsMarkup !== fallbackSandbox.window.productionUtilityPrimaryMetricsMarkup) {
  throw new Error('Primary metrics markup runtime bridge is not active.');
}

let unexpectedFallbackCalls = 0;
const runtimeSandbox = {
  window:{
    productionReportingTotals(){ return {legacyTotals:true}; },
    productionUtilityPrimaryMetricsMarkup(){
      unexpectedFallbackCalls += 1;
      return 'LEGACY';
    }
  },
  currentDailyReportValueSummaries:values,
  currentDailyAuthorizationSummaries:auth,
  userCanSeeActualContractPrices:() => true,
  userCanSeeFieldMoney:() => false,
  formatCurrency:value => '$' + Number(value).toFixed(2),
  escapeHtml:value => 'ESC(' + String(value) + ')'
};
vm.runInNewContext(source, runtimeSandbox, {filename:'production-core-runtime-markup.js'});
const actual = runtimeSandbox.window.productionUtilityPrimaryMetricsMarkup(reports);
const expected = '<div class="production-utility-primary-metrics">' +
  '<span><strong>1</strong>Awaiting Review</span>' +
  '<span><strong>ESC($1200.50)</strong>Approved Production</span>' +
  '<span><strong>2</strong>Active Jobs</span>' +
  '<span><strong>ESC($71.45)</strong>Actual MH Rate</span>' +
  '</div>';
if (actual !== expected) {
  throw new Error(`Primary metrics markup runtime output changed: ${actual}`);
}
if (unexpectedFallbackCalls !== 0) {
  throw new Error('Primary metrics markup runtime bridge used the inline fallback even though all dependencies were available.');
}

const throwingSandbox = {
  window:{
    productionReportingTotals(){ return {legacyTotals:true}; },
    productionUtilityPrimaryMetricsMarkup(){ return 'SAFE-FALLBACK'; }
  },
  currentDailyReportValueSummaries:values,
  currentDailyAuthorizationSummaries:auth,
  userCanSeeActualContractPrices:() => { throw new Error('permission helper unavailable'); },
  userCanSeeFieldMoney:() => false,
  formatCurrency:value => String(value),
  escapeHtml:value => String(value)
};
vm.runInNewContext(source, throwingSandbox, {filename:'production-core-throw-fallback.js'});
if (throwingSandbox.window.productionUtilityPrimaryMetricsMarkup(reports) !== 'SAFE-FALLBACK') {
  throw new Error('Primary metrics markup runtime bridge must fall back if a dependency throws.');
}

console.log('Production primary metrics markup runtime handoff guard passed.');
console.log('- tested module-owned live markup path');
console.log('- tested missing-dependency inline fallback');
console.log('- tested thrown-dependency inline fallback');
