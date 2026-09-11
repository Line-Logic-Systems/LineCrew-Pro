import fs from 'node:fs';
import vm from 'node:vm';

const moduleSource = fs.readFileSync('assistant-core.js','utf8');
const bootstrap = fs.readFileSync('number-input-polish.js','utf8');
const index = fs.readFileSync('index.html','utf8');
const serviceWorker = fs.readFileSync('service-worker.js','utf8');

const sandbox = { window:{} };
vm.runInNewContext(moduleSource, sandbox, { filename:'assistant-core.js' });
const core = sandbox.window.LineCrewAssistantCore;
if (!core || typeof core.assistantMemoryTriggerLabel !== 'function') {
  throw new Error('Assistant core module must expose assistantMemoryTriggerLabel().');
}

const cases = [
  ['always','Always'],
  ['job_open','When the job is open'],
  ['production_review','During production review'],
  ['final_billing','Before final billing'],
  ['timekeeping','During timekeeping'],
  ['billing','During billing'],
  ['manual','Only in Saved Memories'],
  ['unknown','Saved reminder'],
  [null,'Saved reminder']
];
for (const [input, expected] of cases) {
  const actual = core.assistantMemoryTriggerLabel(input);
  if (actual !== expected) throw new Error(`assistantMemoryTriggerLabel(${JSON.stringify(input)}) returned ${actual}; expected ${expected}.`);
}
if (sandbox.window.assistantMemoryTriggerLabel !== core.assistantMemoryTriggerLabel) {
  throw new Error('Assistant core compatibility bridge is not active.');
}
if (!bootstrap.includes("script.src = '/assistant-core.js?v=20260910a'")) {
  throw new Error('Assistant core module is not bootstrapped by the existing front-end loader path.');
}
if (!bootstrap.includes('Assistant core module unavailable; using inline compatibility fallback.')) {
  throw new Error('Assistant core loader must retain an explicit inline fallback path.');
}
if (!serviceWorker.includes("'/assistant-core.js?v=20260910a'")) {
  throw new Error('Assistant core module must remain in the offline app shell.');
}
if (!index.includes('function assistantMemoryTriggerLabel(trigger){')) {
  throw new Error('Legacy inline assistantMemoryTriggerLabel() fallback must remain during staged extraction.');
}

console.log('Assistant core modularization guard passed.');
console.log('- Assistant Memory trigger labels match legacy behavior');
console.log('- compatibility bridge is active; module is offline-capable; inline fallback remains available');
