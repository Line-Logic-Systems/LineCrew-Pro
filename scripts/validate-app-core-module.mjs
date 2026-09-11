import fs from 'node:fs';
import vm from 'node:vm';

const moduleSource = fs.readFileSync('app-core.js','utf8');
const bootstrap = fs.readFileSync('number-input-polish.js','utf8');
const index = fs.readFileSync('index.html','utf8');
const serviceWorker = fs.readFileSync('service-worker.js','utf8');

const sandbox = { window:{} };
vm.runInNewContext(moduleSource, sandbox, { filename:'app-core.js' });
const core = sandbox.window.LineCrewAppCore;
if (!core || typeof core.uniqueOfflineJsaJobs !== 'function') {
  throw new Error('App core module must expose uniqueOfflineJsaJobs().');
}

const cases = [
  [[], []],
  [[{id:'1',job_number:'A1',job_name:'Alpha'}],[{id:'1',job_number:'A1',job_name:'Alpha'}]],
  [[{id:'1',job_number:'A1',job_name:'Alpha'},{id:'1',job_number:'B2',job_name:'Duplicate'}],[{id:'1',job_number:'A1',job_name:'Alpha'}]],
  [[{id:2,job_number:'',job_name:''},null,{id:'3'}],[{id:'2',job_number:'Job',job_name:'Unnamed'},{id:'3',job_number:'Job',job_name:'Unnamed'}]]
];
for (const [input, expected] of cases) {
  const actual = core.uniqueOfflineJsaJobs(input);
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`uniqueOfflineJsaJobs parity failed: ${JSON.stringify(actual)} !== ${JSON.stringify(expected)}`);
  }
}
if (sandbox.window.uniqueOfflineJsaJobs !== core.uniqueOfflineJsaJobs) {
  throw new Error('App core compatibility bridge is not active.');
}
if (!bootstrap.includes("script.src = '/app-core.js?v=20260910a'")) {
  throw new Error('App core module is not bootstrapped by the existing front-end loader path.');
}
if (!bootstrap.includes('App core module unavailable; using inline compatibility fallback.')) {
  throw new Error('App core loader must retain an explicit inline fallback path.');
}
if (!serviceWorker.includes("'/app-core.js?v=20260910a'")) {
  throw new Error('App core module must remain in the offline app shell.');
}
if (!index.includes('function uniqueOfflineJsaJobs(jobs){')) {
  throw new Error('Legacy inline uniqueOfflineJsaJobs() fallback must remain during staged extraction.');
}

console.log('App core modularization guard passed.');
console.log('- offline JSA job deduping/default labels match legacy behavior');
console.log('- compatibility bridge is active');
console.log('- module is available offline');
console.log('- inline fallback remains available if the module cannot load');
