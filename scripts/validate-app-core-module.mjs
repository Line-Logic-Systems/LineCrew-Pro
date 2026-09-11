import fs from 'node:fs';
import vm from 'node:vm';

const moduleSource = fs.readFileSync('app-core.js','utf8');
const bootstrap = fs.readFileSync('number-input-polish.js','utf8');
const index = fs.readFileSync('index.html','utf8');
const serviceWorker = fs.readFileSync('service-worker.js','utf8');

const sandbox = { window:{}, navigator:{onLine:true} };
vm.runInNewContext(moduleSource, sandbox, { filename:'app-core.js' });
const core = sandbox.window.LineCrewAppCore;
for (const name of ['uniqueOfflineJsaJobs','offlineJsaNetworkFailure','companyAccessInactive']) {
  if (!core || typeof core[name] !== 'function') throw new Error(`App core module must expose ${name}().`);
}

const jobCases = [
  [[], []],
  [[{id:'1',job_number:'A1',job_name:'Alpha'}],[{id:'1',job_number:'A1',job_name:'Alpha'}]],
  [[{id:'1',job_number:'A1',job_name:'Alpha'},{id:'1',job_number:'B2',job_name:'Duplicate'}],[{id:'1',job_number:'A1',job_name:'Alpha'}]],
  [[{id:2,job_number:'',job_name:''},null,{id:'3'}],[{id:'2',job_number:'Job',job_name:'Unnamed'},{id:'3',job_number:'Job',job_name:'Unnamed'}]]
];
for (const [input, expected] of jobCases) {
  const actual = core.uniqueOfflineJsaJobs(input);
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`uniqueOfflineJsaJobs parity failed: ${JSON.stringify(actual)} !== ${JSON.stringify(expected)}`);
  }
}

const onlineCases = [
  [{message:'Failed to fetch'}, true],
  [{message:'Network request failed'}, true],
  [{message:'Request timed out'}, true],
  [{message:'Connection reset'}, true],
  [{message:'Permission denied'}, false],
  [null, false]
];
for (const [error, expected] of onlineCases) {
  sandbox.navigator.onLine = true;
  const actual = core.offlineJsaNetworkFailure(error);
  if (actual !== expected) throw new Error(`offlineJsaNetworkFailure(${JSON.stringify(error)}) returned ${actual}; expected ${expected}.`);
}
sandbox.navigator.onLine = false;
if (core.offlineJsaNetworkFailure({message:'Permission denied'}) !== true) {
  throw new Error('offlineJsaNetworkFailure() must return true whenever navigator reports offline.');
}
sandbox.navigator.onLine = true;

const accessCases = [
  [{message:'Company access is inactive'}, true],
  [{message:'Permission denied',hint:'Company access is inactive until billing is restored'}, true],
  [{message:'company ACCESS is INACTIVE'}, true],
  [{message:'Permission denied'}, false],
  [null, false]
];
for (const [error, expected] of accessCases) {
  const actual = core.companyAccessInactive(error);
  if (actual !== expected) throw new Error(`companyAccessInactive(${JSON.stringify(error)}) returned ${actual}; expected ${expected}.`);
}

for (const name of ['uniqueOfflineJsaJobs','offlineJsaNetworkFailure','companyAccessInactive']) {
  if (sandbox.window[name] !== core[name]) throw new Error(`App core compatibility bridge ${name} is not active.`);
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
for (const signature of [
  'function uniqueOfflineJsaJobs(jobs){',
  'function offlineJsaNetworkFailure(error){',
  'function companyAccessInactive(error){'
]) {
  if (!index.includes(signature)) throw new Error(`Legacy inline app-core fallback missing: ${signature}`);
}

console.log('App core modularization guard passed.');
console.log('- offline JSA job deduping/default labels match legacy behavior');
console.log('- offline/network failure classification matches legacy behavior');
console.log('- inactive-company error detection matches legacy behavior');
console.log('- compatibility bridges are active');
console.log('- module is available offline and inline fallbacks remain available');
