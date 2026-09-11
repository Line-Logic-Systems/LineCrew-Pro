import fs from 'node:fs';
import vm from 'node:vm';

const moduleSource = fs.readFileSync('production-core.js','utf8');
const bootstrap = fs.readFileSync('number-input-polish.js','utf8');
const index = fs.readFileSync('index.html','utf8');
const serviceWorker = fs.readFileSync('service-worker.js','utf8');

const sandbox = { window:{} };
vm.runInNewContext(moduleSource, sandbox, { filename:'production-core.js' });
const core = sandbox.window.LineCrewProductionCore;
if (!core || typeof core.reportUtilityKey !== 'function') {
  throw new Error('Production core module must expose reportUtilityKey().');
}

const cases = [
  [{ jobs:{ contracts:{ customers:{ id:'utility-123' } } } }, 'utility-123'],
  [{ jobs:{ contracts:{ customers:{} } } }, 'unassigned'],
  [{}, 'unassigned'],
  [null, 'unassigned']
];
for (const [input, expected] of cases) {
  const actual = core.reportUtilityKey(input);
  if (actual !== expected) throw new Error(`reportUtilityKey() returned ${actual}; expected ${expected}.`);
}

if (sandbox.window.productionReportUtilityKey !== core.reportUtilityKey) {
  throw new Error('Production core compatibility bridge is not active.');
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

console.log('Production core modularization guard passed.');
console.log('- extracted utility-key helper matches legacy behavior');
console.log('- compatibility bridge is active');
console.log('- module is available offline');
console.log('- inline fallback remains available if the module cannot load');
