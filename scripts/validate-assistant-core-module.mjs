import fs from 'node:fs';
import vm from 'node:vm';

const moduleSource = fs.readFileSync('assistant-core.js','utf8');
const bootstrap = fs.readFileSync('number-input-polish.js','utf8');
const index = fs.readFileSync('index.html','utf8');
const serviceWorker = fs.readFileSync('service-worker.js','utf8');

const sandbox = { window:{} };
vm.runInNewContext(moduleSource, sandbox, { filename:'assistant-core.js' });
const core = sandbox.window.LineCrewAssistantCore;
const helperNames = ['assistantMemoryTriggerLabel','assistantMemoryJobLabel'];
for (const name of helperNames) {
  if (!core || typeof core[name] !== 'function') throw new Error(`Assistant core module must expose ${name}().`);
}

const triggerCases = [
  ['always','Always'],['job_open','When the job is open'],['production_review','During production review'],
  ['final_billing','Before final billing'],['timekeeping','During timekeeping'],['billing','During billing'],
  ['manual','Only in Saved Memories'],['unknown','Saved reminder'],[null,'Saved reminder']
];
for (const [input, expected] of triggerCases) {
  const actual = core.assistantMemoryTriggerLabel(input);
  if (actual !== expected) throw new Error(`assistantMemoryTriggerLabel(${JSON.stringify(input)}) returned ${actual}; expected ${expected}.`);
}

const jobCases = [
  [null,'Selected job'],
  [{jobs:null},'Selected job'],
  [{jobs:{job_number:'WO-100',job_name:'North Feeder'}},'WO-100 — North Feeder'],
  [{jobs:{job_number:'WO-100'}},'WO-100'],
  [{jobs:{job_name:'North Feeder'}},'North Feeder'],
  [{jobs:{}},'Selected job'],
  [{jobs:[{job_number:'WO-200',job_name:'South Feeder'},{job_number:'WO-201'}]},'WO-200 — South Feeder']
];
for (const [input, expected] of jobCases) {
  const actual = core.assistantMemoryJobLabel(input);
  if (actual !== expected) throw new Error(`assistantMemoryJobLabel(${JSON.stringify(input)}) returned ${actual}; expected ${expected}.`);
}

for (const name of helperNames) {
  if (sandbox.window[name] !== core[name]) throw new Error(`Assistant core compatibility bridge ${name} is not active.`);
}
if (!bootstrap.includes("script.src = '/assistant-core.js?v=20260910a'")) throw new Error('Assistant core module is not bootstrapped by the existing front-end loader path.');
if (!bootstrap.includes('Assistant core module unavailable; using inline compatibility fallback.')) throw new Error('Assistant core loader must retain an explicit inline fallback path.');
if (!serviceWorker.includes("'/assistant-core.js?v=20260910a'")) throw new Error('Assistant core module must remain in the offline app shell.');
for (const signature of ['function assistantMemoryTriggerLabel(trigger){','function assistantMemoryJobLabel(memory){']) {
  if (!index.includes(signature)) throw new Error(`Legacy inline Assistant fallback missing: ${signature}`);
}

console.log('Assistant core modularization guard passed.');
console.log('- Assistant Memory trigger and job labels match legacy behavior');
console.log('- compatibility bridges are active; module is offline-capable; inline fallbacks remain available');
