import fs from 'node:fs';
import vm from 'node:vm';

const moduleSource = fs.readFileSync('daily-report-core.js','utf8');
const bootstrap = fs.readFileSync('number-input-polish.js','utf8');
const index = fs.readFileSync('index.html','utf8');

const sandbox = { window:{} };
vm.runInNewContext(moduleSource, sandbox, { filename:'daily-report-core.js' });
const core = sandbox.window.LineCrewDailyReportCore;
if (!core || typeof core.workTypeLabel !== 'function') {
  throw new Error('Daily Report core module must expose workTypeLabel().');
}

const cases = [
  ['install','Install'],
  ['retirement','Remove / Retirement'],
  ['transfer','Transfer'],
  ['', 'Install'],
  [null, 'Install']
];
for (const [input, expected] of cases) {
  const actual = core.workTypeLabel(input);
  if (actual !== expected) throw new Error(`workTypeLabel(${String(input)}) returned ${actual}; expected ${expected}.`);
}

if (sandbox.window.dailyUnitWorkTypeLabel !== core.workTypeLabel) {
  throw new Error('Daily Report module compatibility bridge is not active.');
}
if (!bootstrap.includes("script.src = '/daily-report-core.js?v=20260910a'")) {
  throw new Error('Daily Report core module is not bootstrapped by the existing front-end loader path.');
}
if (!bootstrap.includes('using inline compatibility fallback')) {
  throw new Error('Daily Report module loader must retain an explicit fallback path.');
}
if (!index.includes('function dailyUnitWorkTypeLabel(workType){')) {
  throw new Error('Legacy inline Daily Report helper must remain during the staged extraction rollout.');
}
if (!index.includes("if(workType === 'retirement') return 'Remove / Retirement';") ||
    !index.includes("if(workType === 'transfer') return 'Transfer';") ||
    !index.includes("return 'Install';")) {
  throw new Error('Legacy Daily Report fallback no longer matches the extracted module behavior.');
}

console.log('Daily Report core modularization guard passed.');
console.log('- extracted module behavior matches legacy work-type labels');
console.log('- compatibility bridge is active');
console.log('- inline fallback remains available if the module cannot load');
