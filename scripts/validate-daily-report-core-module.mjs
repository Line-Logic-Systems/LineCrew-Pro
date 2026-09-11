import fs from 'node:fs';
import vm from 'node:vm';

const moduleSource = fs.readFileSync('daily-report-core.js','utf8');
const bootstrap = fs.readFileSync('number-input-polish.js','utf8');
const index = fs.readFileSync('index.html','utf8');

const sandbox = { window:{} };
vm.runInNewContext(moduleSource, sandbox, { filename:'daily-report-core.js' });
const core = sandbox.window.LineCrewDailyReportCore;
if (!core || typeof core.workTypeLabel !== 'function' || typeof core.safeStorageFilename !== 'function') {
  throw new Error('Daily Report core module must expose workTypeLabel() and safeStorageFilename().');
}

const workTypeCases = [
  ['install','Install'],
  ['retirement','Remove / Retirement'],
  ['transfer','Transfer'],
  ['', 'Install'],
  [null, 'Install']
];
for (const [input, expected] of workTypeCases) {
  const actual = core.workTypeLabel(input);
  if (actual !== expected) throw new Error(`workTypeLabel(${String(input)}) returned ${actual}; expected ${expected}.`);
}

const filenameCases = [
  ['photo 1.jpg','photo-1.jpg'],
  ['Crew/Map #7.PNG','Crew-Map-7.png'],
  ['..pdf','attachment.pdf'],
  ['no-extension','no-extension'],
  ['', 'attachment'],
  ['a'.repeat(100) + '.jpeg', 'a'.repeat(80) + '.jpeg']
];
for (const [input, expected] of filenameCases) {
  const actual = core.safeStorageFilename(input);
  if (actual !== expected) throw new Error(`safeStorageFilename(${JSON.stringify(input)}) returned ${actual}; expected ${expected}.`);
}

if (sandbox.window.dailyUnitWorkTypeLabel !== core.workTypeLabel) {
  throw new Error('Daily Report work-type compatibility bridge is not active.');
}
if (sandbox.window.safeStorageFilename !== core.safeStorageFilename) {
  throw new Error('Daily Report attachment filename compatibility bridge is not active.');
}
if (!bootstrap.includes("script.src = '/daily-report-core.js?v=20260910a'")) {
  throw new Error('Daily Report core module is not bootstrapped by the existing front-end loader path.');
}
if (!bootstrap.includes('using inline compatibility fallback')) {
  throw new Error('Daily Report module loader must retain an explicit fallback path.');
}
if (!index.includes('function dailyUnitWorkTypeLabel(workType){')) {
  throw new Error('Legacy inline Daily Report work-type helper must remain during the staged extraction rollout.');
}
if (!index.includes("if(workType === 'retirement') return 'Remove / Retirement';") ||
    !index.includes("if(workType === 'transfer') return 'Transfer';") ||
    !index.includes("return 'Install';")) {
  throw new Error('Legacy Daily Report work-type fallback no longer matches the extracted module behavior.');
}
if (!index.includes('function safeStorageFilename(filename){') ||
    !index.includes("String(filename || 'attachment').split('.')") ||
    !index.includes(".replace(/[^a-z0-9_-]+/gi, '-')") ||
    !index.includes(".slice(0, 80) || 'attachment'")) {
  throw new Error('Legacy Daily Report attachment filename fallback must remain during staged extraction.');
}

console.log('Daily Report core modularization guard passed.');
console.log('- extracted module behavior matches legacy work-type labels');
console.log('- attachment filename sanitizer is extracted with parity fixtures');
console.log('- compatibility bridges are active');
console.log('- inline fallbacks remain available if the module cannot load');
