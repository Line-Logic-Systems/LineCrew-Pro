import fs from 'node:fs';
import vm from 'node:vm';

const moduleSource = fs.readFileSync('daily-report-core.js','utf8');
const bootstrap = fs.readFileSync('number-input-polish.js','utf8');
const index = fs.readFileSync('index.html','utf8');
const serviceWorker = fs.readFileSync('service-worker.js','utf8');

const sandbox = { window:{} };
vm.runInNewContext(moduleSource, sandbox, { filename:'daily-report-core.js' });
const core = sandbox.window.LineCrewDailyReportCore;
for (const name of ['workTypeLabel','safeStorageFilename','dailyQuantityText']) {
  if (!core || typeof core[name] !== 'function') throw new Error(`Daily Report core module must expose ${name}().`);
}

for (const [input, expected] of [['install','Install'],['retirement','Remove / Retirement'],['transfer','Transfer'],['','Install'],[null,'Install']]) {
  if (core.workTypeLabel(input) !== expected) throw new Error(`workTypeLabel(${String(input)}) parity failed.`);
}
for (const [input, expected] of [['photo 1.jpg','photo-1.jpg'],['Crew/Map #7.PNG','Crew-Map-7.png'],['..pdf','attachment.pdf'],['no-extension','no-extension'],['','attachment'],['a'.repeat(100)+'.jpeg','a'.repeat(80)+'.jpeg']]) {
  if (core.safeStorageFilename(input) !== expected) throw new Error(`safeStorageFilename(${JSON.stringify(input)}) parity failed.`);
}
for (const [input, expected] of [[null,'0'],['','0'],[0,'0'],[1,'1'],[2.5,'2.5'],[2.25,'2.25'],[2.2,'2.2'],[3.456,'3.46'],['4.50','4.5'],['not-a-number','0']]) {
  const actual = core.dailyQuantityText(input);
  if (actual !== expected) throw new Error(`dailyQuantityText(${JSON.stringify(input)}) returned ${actual}; expected ${expected}.`);
}

if (sandbox.window.dailyUnitWorkTypeLabel !== core.workTypeLabel) throw new Error('Daily Report work-type compatibility bridge is not active.');
if (sandbox.window.safeStorageFilename !== core.safeStorageFilename) throw new Error('Daily Report attachment filename compatibility bridge is not active.');
if (sandbox.window.dailyQuantityText !== core.dailyQuantityText) throw new Error('Daily Report quantity compatibility bridge is not active.');
if (!bootstrap.includes("script.src = '/daily-report-core.js?v=20260910a'")) throw new Error('Daily Report core module is not bootstrapped by the existing front-end loader path.');
if (!bootstrap.includes('using inline compatibility fallback')) throw new Error('Daily Report module loader must retain an explicit fallback path.');
if (!serviceWorker.includes("'/daily-report-core.js?v=20260910a'")) throw new Error('Daily Report core module must remain in the offline app shell.');
for (const signature of ['function dailyUnitWorkTypeLabel(workType){','function safeStorageFilename(filename){','function dailyQuantityText(value){']) {
  if (!index.includes(signature)) throw new Error(`Legacy inline Daily Report fallback missing: ${signature}`);
}

console.log('Daily Report core modularization guard passed.');
console.log('- work-type labels, attachment filenames, and quantity text match legacy behavior');
console.log('- compatibility bridges are active');
console.log('- module is pinned in the offline app shell and inline fallbacks remain available');
