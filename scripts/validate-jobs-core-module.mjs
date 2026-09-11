import fs from 'node:fs';
import vm from 'node:vm';

const moduleSource = fs.readFileSync('jobs-core.js','utf8');
const bootstrap = fs.readFileSync('number-input-polish.js','utf8');
const index = fs.readFileSync('index.html','utf8');
const serviceWorker = fs.readFileSync('service-worker.js','utf8');

const sandbox = { window:{} };
vm.runInNewContext(moduleSource, sandbox, { filename:'jobs-core.js' });
const core = sandbox.window.LineCrewJobsCore;
for (const name of ['fileNameWithoutExtension','jobPacketFileValidationMessage']) {
  if (!core || typeof core[name] !== 'function') throw new Error(`Jobs core module must expose ${name}().`);
}

const nameCases = [
  ['packet.pdf','packet'],
  ['job.packet.v2.xlsx','job.packet.v2'],
  ['no-extension','no-extension'],
  ['', 'Job Packet'],
  [null, 'Job Packet'],
  ['.hidden','']
];
for (const [input, expected] of nameCases) {
  const actual = core.fileNameWithoutExtension(input);
  if (actual !== expected) throw new Error(`fileNameWithoutExtension(${JSON.stringify(input)}) returned ${JSON.stringify(actual)}; expected ${JSON.stringify(expected)}.`);
}

const maxPdf = 20 * 1024 * 1024;
const fileCases = [
  [null, ''],
  [{name:'packet.pdf',size:0}, ''],
  [{name:'packet.PDF',size:maxPdf}, ''],
  [{name:'packet.pdf',size:maxPdf + 1}, 'The PDF job jacket must be 20 MB or smaller.'],
  [{name:'packet.xlsx',size:maxPdf * 10}, ''],
  [{name:'packet.csv',size:1}, ''],
  [{name:'packet.tsv',size:1}, ''],
  [{name:'packet.txt',size:1}, ''],
  [{name:'packet.xls',size:1}, ''],
  [{name:'packet.ods',size:1}, ''],
  [{name:'packet.docx',size:1}, 'Choose a PDF, Excel, CSV, TSV, TXT or ODS job jacket.'],
  [{name:'packet',size:1}, 'Choose a PDF, Excel, CSV, TSV, TXT or ODS job jacket.']
];
for (const [file, expected] of fileCases) {
  const actual = core.jobPacketFileValidationMessage(file);
  if (actual !== expected) throw new Error(`jobPacketFileValidationMessage(${JSON.stringify(file)}) returned ${JSON.stringify(actual)}; expected ${JSON.stringify(expected)}.`);
}

for (const name of ['fileNameWithoutExtension','jobPacketFileValidationMessage']) {
  if (sandbox.window[name] !== core[name]) throw new Error(`Jobs core compatibility bridge ${name} is not active.`);
}
if (!bootstrap.includes("script.src = '/jobs-core.js?v=20260910a'")) {
  throw new Error('Jobs core module is not bootstrapped by the existing front-end loader path.');
}
if (!bootstrap.includes('Jobs core module unavailable; using inline compatibility fallback.')) {
  throw new Error('Jobs core loader must retain an explicit inline fallback path.');
}
if (!serviceWorker.includes("'/jobs-core.js?v=20260910a'")) {
  throw new Error('Jobs core module must remain in the offline app shell.');
}
for (const signature of ['function fileNameWithoutExtension(value){','function jobPacketFileValidationMessage(file){']) {
  if (!index.includes(signature)) throw new Error(`Legacy inline Jobs fallback missing: ${signature}`);
}

console.log('Jobs core modularization guard passed.');
console.log('- packet filename display helper matches legacy behavior');
console.log('- packet file type/size validation matches legacy behavior');
console.log('- compatibility bridges are active');
console.log('- module is available offline');
console.log('- inline fallbacks remain available if the module cannot load');
