import fs from 'node:fs';
import vm from 'node:vm';

const moduleSource = fs.readFileSync('billing-core.js','utf8');
const bootstrap = fs.readFileSync('number-input-polish.js','utf8');
const index = fs.readFileSync('index.html','utf8');
const serviceWorker = fs.readFileSync('service-worker.js','utf8');

const sandbox = { window:{} };
vm.runInNewContext(moduleSource, sandbox, { filename:'billing-core.js' });
const core = sandbox.window.LineCrewBillingCore;
const helperNames = ['billingStatusLabel','billingStageLabel','completeBillingSafeName','billingSafeStorageFilename','completeBillingSheetName'];
for (const name of helperNames) {
  if (!core || typeof core[name] !== 'function') throw new Error(`Billing core module must expose ${name}().`);
}

for (const [input, expected] of [[null,'DRAFT'],['','DRAFT'],['draft','DRAFT'],['submitted','SUBMITTED'],['paid','PAID'],['void','VOID'],['awaiting_payment','AWAITING PAYMENT'],['Mixed_Case','MIXED CASE']]) {
  if (core.billingStatusLabel(input) !== expected) throw new Error(`billingStatusLabel(${JSON.stringify(input)}) parity failed.`);
}
for (const [batch, expected] of [[null,'Partial Bill 1'],[{},'Partial Bill 1'],[{billing_type:'partial',billing_sequence:1},'Partial Bill 1'],[{billing_type:'partial',billing_sequence:'3'},'Partial Bill 3'],[{billing_type:'final'},'Final Bill'],[{billing_type:'credit'},'Billing Adjustment']]) {
  if (core.billingStageLabel(batch) !== expected) throw new Error(`billingStageLabel(${JSON.stringify(batch)}) parity failed.`);
}
for (const [value, fallback, expected] of [[null,'record','record'],['','job','job'],['Job 123','record','Job-123'],['  A/B:C*D?  ','record','A-B-C-D'],['job_packet.v2','record','job_packet.v2'],['---','fallback','fallback']]) {
  if (core.completeBillingSafeName(value, fallback) !== expected) throw new Error(`completeBillingSafeName(${JSON.stringify(value)}) parity failed.`);
}
if (core.completeBillingSafeName('A'.repeat(140)).length !== 110) throw new Error('completeBillingSafeName() must preserve the 110-character cap.');
for (const [input, expected] of [[null,'billing-attachment'],['','billing-attachment'],['invoice.pdf','invoice.pdf'],['Invoice Copy.PDF','Invoice-Copy.pdf'],['WO 123 / approval.final.PDF','WO-123-approval-final.pdf'],['no-extension','no-extension'],['###.PDF','billing-attachment.pdf'],['photo.JPEG','photo.jpeg'],['file.longextension123456789','file.longextensio']]) {
  if (core.billingSafeStorageFilename(input) !== expected) throw new Error(`billingSafeStorageFilename(${JSON.stringify(input)}) parity failed.`);
}
if (core.billingSafeStorageFilename('A'.repeat(100)+'.pdf').replace(/\.pdf$/,'').length !== 80) throw new Error('billingSafeStorageFilename() must preserve the 80-character base cap.');

const used = new Set();
if (core.completeBillingSheetName('Batch 1', used) !== 'Batch 1') throw new Error('First worksheet label must be preserved.');
if (core.completeBillingSheetName('Batch 1', used) !== 'Batch 1 2') throw new Error('Duplicate worksheet label must receive sequence 2.');
if (core.completeBillingSheetName('Batch 1', used) !== 'Batch 1 3') throw new Error('Third duplicate worksheet label must receive sequence 3.');
if (core.completeBillingSheetName('Bad/Name:*?[]', new Set()) !== 'Bad Name') throw new Error('Worksheet-invalid characters must be replaced and trimmed.');
if (core.completeBillingSheetName('', new Set()) !== 'Batch') throw new Error('Blank worksheet names must use Batch fallback.');
if (core.completeBillingSheetName('A'.repeat(60), new Set()).length !== 31) throw new Error('Worksheet names must preserve the 31-character Excel limit.');

for (const name of helperNames) {
  if (sandbox.window[name] !== core[name]) throw new Error(`Billing core compatibility bridge ${name} is not active.`);
}
if (!bootstrap.includes("script.src = '/billing-core.js?v=20260910a'")) throw new Error('Billing core module is not bootstrapped by the existing front-end loader path.');
if (!bootstrap.includes('Billing core module unavailable; using inline compatibility fallback.')) throw new Error('Billing core loader must retain an explicit inline fallback path.');
if (!serviceWorker.includes("'/billing-core.js?v=20260910a'")) throw new Error('Billing core module must remain in the offline app shell.');
for (const signature of ['function billingStatusLabel(status){','function billingStageLabel(batch){',"function completeBillingSafeName(value,fallback='record'){",'function billingSafeStorageFilename(filename){','function completeBillingSheetName(label,used){']) {
  if (!index.includes(signature)) throw new Error(`Legacy inline Billing fallback missing: ${signature}`);
}

console.log('Billing core modularization guard passed.');
console.log('- billing labels, filename sanitizers, and Excel worksheet naming match legacy behavior');
console.log('- compatibility bridges are active; module is offline-capable; inline fallbacks remain available');
