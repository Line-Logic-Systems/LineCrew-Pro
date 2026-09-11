import fs from 'node:fs';
import vm from 'node:vm';

const moduleSource = fs.readFileSync('jobs-core.js','utf8');
const bootstrap = fs.readFileSync('number-input-polish.js','utf8');
const index = fs.readFileSync('index.html','utf8');
const serviceWorker = fs.readFileSync('service-worker.js','utf8');

const sandbox = { window:{} };
vm.runInNewContext(moduleSource, sandbox, { filename:'jobs-core.js' });
const core = sandbox.window.LineCrewJobsCore;
if (!core || typeof core.fileNameWithoutExtension !== 'function') {
  throw new Error('Jobs core module must expose fileNameWithoutExtension().');
}

const cases = [
  ['packet.pdf','packet'],
  ['job.packet.v2.xlsx','job.packet.v2'],
  ['no-extension','no-extension'],
  ['', 'Job Packet'],
  [null, 'Job Packet'],
  ['.hidden','']
];
for (const [input, expected] of cases) {
  const actual = core.fileNameWithoutExtension(input);
  if (actual !== expected) throw new Error(`fileNameWithoutExtension(${JSON.stringify(input)}) returned ${JSON.stringify(actual)}; expected ${JSON.stringify(expected)}.`);
}
if (sandbox.window.fileNameWithoutExtension !== core.fileNameWithoutExtension) {
  throw new Error('Jobs core compatibility bridge is not active.');
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
if (!index.includes('function fileNameWithoutExtension(value){')) {
  throw new Error('Legacy inline fileNameWithoutExtension() fallback must remain during staged extraction.');
}

console.log('Jobs core modularization guard passed.');
console.log('- packet filename display helper matches legacy behavior');
console.log('- compatibility bridge is active');
console.log('- module is available offline');
console.log('- inline fallback remains available if the module cannot load');
