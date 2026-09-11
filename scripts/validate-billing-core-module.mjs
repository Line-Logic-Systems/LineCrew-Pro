import fs from 'node:fs';
import vm from 'node:vm';

const moduleSource = fs.readFileSync('billing-core.js','utf8');
const bootstrap = fs.readFileSync('number-input-polish.js','utf8');
const index = fs.readFileSync('index.html','utf8');
const serviceWorker = fs.readFileSync('service-worker.js','utf8');

const sandbox = { window:{} };
vm.runInNewContext(moduleSource, sandbox, { filename:'billing-core.js' });
const core = sandbox.window.LineCrewBillingCore;
const helperNames = ['billingStatusLabel','billingStageLabel','completeBillingSafeName','billingSafeStorageFilename'];
for (const name of helperNames) {
  if (!core || typeof core[name] !== 'function') throw new Error(`Billing core module must expose ${name}().`);
}

for (const [input, expected] of [[null,'DRAFT'],['','DRAFT'],['draft','DRAFT'],['submitted','SUBMITTED'],['paid','PAID'],['void','VOID'],['awaiting_payment','AWAITING PAYMENT'],['Mixed_Case','MIXED CASE']]) {
  const actual = core.billingStatusLabel(input);
  if (actual !== expected) throw new Error(`billingStatusLabel(${JSON.stringify(input)}) returned ${actual}; expected ${expected}.`);
}

for (const [batch, expected] of [
  [null,'Partial Bill 1'],
  [{},'Partial Bill 1'],
  [{billing_type:'partial',billing_sequence:1},'Partial Bill 1'],
  [{billing_type:'partial',billing_sequence:'3'},'Partial Bill 3'],
  [{billing_type:'final',billing_sequence:9},'Final Bill'],
  [{billing_type:'FINAL'},'Final Bill'],
  [{billing_type:'credit',billing_sequence:4},'Billing Adjustment'],
  [{billing_type:'CREDIT'},'Billing Adjustment']
]) {
  const actual = core.billingStageLabel(batch);
  if (actual !== expected) throw new Error(`billingStageLabel(${JSON.stringify(batch)}) returned ${actual}; expected ${expected}.`);
}

for (const [value, fallback, expected] of [
  [null,'record','record'],
  ['','job','job'],
  ['Job 123','record','Job-123'],
  ['  A/B:C*D?  ','record','A-B-C-D'],
  ['job_packet.v2','record','job_packet.v2'],
  ['---','fallback','fallback']
]) {
  const actual = core.completeBillingSafeName(value, fallback);
  if (actual !== expected) throw new Error(`completeBillingSafeName(${JSON.stringify(value)}, ${JSON.stringify(fallback)}) returned ${JSON.stringify(actual)}; expected ${JSON.stringify(expected)}.`);
}
if (core.completeBillingSafeName('A'.repeat(140)).length !== 110) throw new Error('completeBillingSafeName() must preserve the 110-character filename cap.');

for (const [input, expected] of [
  [null,'billing-attachment'],
  ['', 'billing-attachment'],
  ['invoice.pdf','invoice.pdf'],
  ['Invoice Copy.PDF','Invoice-Copy.pdf'],
  ['WO 123 / approval.final.PDF','WO-123-approval-final.pdf'],
  ['no-extension','no-extension'],
  ['###.PDF','billing-attachment.pdf'],
  ['photo.JPEG','photo.jpeg'],
  ['file.longextension123456789','file.longextensio']
]) {
  const actual = core.billingSafeStorageFilename(input);
  if (actual !== expected) throw new Error(`billingSafeStorageFilename(${JSON.stringify(input)}) returned ${JSON.stringify(actual)}; expected ${JSON.stringify(expected)}.`);
}
const longStorageBase = core.billingSafeStorageFilename('A'.repeat(100)+'.pdf').replace(/\.pdf$/,'');
if (longStorageBase.length !== 80) throw new Error('billingSafeStorageFilename() must preserve the 80-character base-name cap.');

for (const name of helperNames) {
  if (sandbox.window[name] !== core[name]) throw new Error(`Billing core compatibility bridge ${name} is not active.`);
}
if (!bootstrap.includes("script.src = '/billing-core.js?v=20260910a'")) throw new Error('Billing core module is not bootstrapped by the existing front-end loader path.');
if (!bootstrap.includes('Billing core module unavailable; using inline compatibility fallback.')) throw new Error('Billing core loader must retain an explicit inline fallback path.');
if (!serviceWorker.includes("'/billing-core.js?v=20260910a'")) throw new Error('Billing core module must remain in the offline app shell.');
for (const signature of ['function billingStatusLabel(status){','function billingStageLabel(batch){',"function completeBillingSafeName(value,fallback='record'){",'function billingSafeStorageFilename(filename){']) {
  if (!index.includes(signature)) throw new Error(`Legacy inline Billing fallback missing: ${signature}`);
}

console.log('Billing core modularization guard passed.');
console.log('- billing status/stage labels and filename sanitizers match legacy behavior');
console.log('- compatibility bridges are active; module is offline-capable; inline fallbacks remain available');
