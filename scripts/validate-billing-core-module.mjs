import fs from 'node:fs';
import vm from 'node:vm';

const moduleSource = fs.readFileSync('billing-core.js','utf8');
const bootstrap = fs.readFileSync('number-input-polish.js','utf8');
const index = fs.readFileSync('index.html','utf8');
const serviceWorker = fs.readFileSync('service-worker.js','utf8');

const sandbox = { window:{} };
vm.runInNewContext(moduleSource, sandbox, { filename:'billing-core.js' });
const core = sandbox.window.LineCrewBillingCore;
if (!core || typeof core.billingStatusLabel !== 'function') {
  throw new Error('Billing core module must expose billingStatusLabel().');
}

const cases = [
  [null,'DRAFT'],
  ['', 'DRAFT'],
  ['draft','DRAFT'],
  ['submitted','SUBMITTED'],
  ['paid','PAID'],
  ['void','VOID'],
  ['awaiting_payment','AWAITING PAYMENT'],
  ['Mixed_Case','MIXED CASE']
];
for (const [input, expected] of cases) {
  const actual = core.billingStatusLabel(input);
  if (actual !== expected) throw new Error(`billingStatusLabel(${JSON.stringify(input)}) returned ${actual}; expected ${expected}.`);
}
if (sandbox.window.billingStatusLabel !== core.billingStatusLabel) {
  throw new Error('Billing core compatibility bridge is not active.');
}
if (!bootstrap.includes("script.src = '/billing-core.js?v=20260910a'")) {
  throw new Error('Billing core module is not bootstrapped by the existing front-end loader path.');
}
if (!bootstrap.includes('Billing core module unavailable; using inline compatibility fallback.')) {
  throw new Error('Billing core loader must retain an explicit inline fallback path.');
}
if (!serviceWorker.includes("'/billing-core.js?v=20260910a'")) {
  throw new Error('Billing core module must remain in the offline app shell.');
}
if (!index.includes('function billingStatusLabel(status){')) {
  throw new Error('Legacy inline billingStatusLabel() fallback must remain during staged extraction.');
}

console.log('Billing core modularization guard passed.');
console.log('- billing status labels match legacy behavior');
console.log('- compatibility bridge is active; module is offline-capable; inline fallback remains available');
