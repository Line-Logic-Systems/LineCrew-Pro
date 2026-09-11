import fs from 'node:fs';
import vm from 'node:vm';

const moduleSource = fs.readFileSync('app-core.js','utf8');
const bootstrap = fs.readFileSync('number-input-polish.js','utf8');
const index = fs.readFileSync('index.html','utf8');
const serviceWorker = fs.readFileSync('service-worker.js','utf8');

let storedDesktopView = null;
let fallbackDesktopClass = false;
let throwStorage = false;
let pageSections = [];
const sandbox = {
  window:{ location:{ pathname:'/index.html' } },
  navigator:{onLine:true},
  localStorage:{
    getItem(key){
      if(throwStorage) throw new Error('storage unavailable');
      return key === 'linecrew-pro-desktop-view' ? storedDesktopView : null;
    }
  },
  document:{
    documentElement:{
      classList:{ contains:name => name === 'desktop-view' && fallbackDesktopClass }
    },
    querySelectorAll(selector){
      return selector === 'main > section' ? pageSections : [];
    }
  }
};
vm.runInNewContext(moduleSource, sandbox, { filename:'app-core.js' });
const core = sandbox.window.LineCrewAppCore;
const helperNames = ['uniqueOfflineJsaJobs','offlineJsaNetworkFailure','companyAccessInactive','firstStackFrame','desktopViewEnabled','currentErrorPage','formatTeamRole','formatAuditTimestamp','formatCurrency'];
for (const name of helperNames) {
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
  if (JSON.stringify(actual) !== JSON.stringify(expected)) throw new Error(`uniqueOfflineJsaJobs parity failed: ${JSON.stringify(actual)} !== ${JSON.stringify(expected)}`);
}

for (const [error, expected] of [[{message:'Failed to fetch'},true],[{message:'Network request failed'},true],[{message:'Request timed out'},true],[{message:'Connection reset'},true],[{message:'Permission denied'},false],[null,false]]) {
  sandbox.navigator.onLine = true;
  const actual = core.offlineJsaNetworkFailure(error);
  if (actual !== expected) throw new Error(`offlineJsaNetworkFailure(${JSON.stringify(error)}) returned ${actual}; expected ${expected}.`);
}
sandbox.navigator.onLine = false;
if (core.offlineJsaNetworkFailure({message:'Permission denied'}) !== true) throw new Error('offlineJsaNetworkFailure() must return true whenever navigator reports offline.');
sandbox.navigator.onLine = true;

for (const [error, expected] of [[{message:'Company access is inactive'},true],[{message:'Permission denied',hint:'Company access is inactive until billing is restored'},true],[{message:'company ACCESS is INACTIVE'},true],[{message:'Permission denied'},false],[null,false]]) {
  const actual = core.companyAccessInactive(error);
  if (actual !== expected) throw new Error(`companyAccessInactive(${JSON.stringify(error)}) returned ${actual}; expected ${expected}.`);
}

for (const [error, expected] of [[{stack:'Error: Boom\n    at doThing (app.js:12:34)\n    at run (app.js:20:4)'},'at doThing (app.js:12:34)'],[{stack:'Error: Boom\nno-location-here'},''],[{stack:'Error: Boom\n  https://example.test/app.js:44:9 '},'https://example.test/app.js:44:9'],[null,'']]) {
  const actual = core.firstStackFrame(error);
  if (actual !== expected) throw new Error(`firstStackFrame() returned ${JSON.stringify(actual)}; expected ${JSON.stringify(expected)}.`);
}

storedDesktopView = '1'; throwStorage = false;
if (core.desktopViewEnabled() !== true) throw new Error('desktopViewEnabled() must return true for stored desktop view.');
storedDesktopView = '0';
if (core.desktopViewEnabled() !== false) throw new Error('desktopViewEnabled() must return false when stored desktop view is off.');
storedDesktopView = null;
if (core.desktopViewEnabled() !== false) throw new Error('desktopViewEnabled() must return false when no preference is stored.');
throwStorage = true; fallbackDesktopClass = true;
if (core.desktopViewEnabled() !== true) throw new Error('desktopViewEnabled() must preserve the desktop-view class fallback when storage is unavailable.');
fallbackDesktopClass = false;
if (core.desktopViewEnabled() !== false) throw new Error('desktopViewEnabled() fallback must return false when the desktop-view class is absent.');
throwStorage = false;

const section = (id, hidden) => ({ id, classList:{ contains:name => name === 'hidden' ? hidden : false } });
pageSections = [section('dashboardPage',true), section('productionPage',false), section('jobsPage',true)];
if (core.currentErrorPage() !== 'productionPage') throw new Error('currentErrorPage() must return the visible app section id.');
pageSections = [section('dashboardPage',true), section('productionPage',true)]; sandbox.window.location.pathname = '/billing.html';
if (core.currentErrorPage() !== '/billing.html') throw new Error('currentErrorPage() must fall back to window.location.pathname.');
pageSections = []; sandbox.window.location.pathname = '';
if (core.currentErrorPage() !== 'app') throw new Error('currentErrorPage() must preserve the final app fallback.');
sandbox.window.location.pathname = '/index.html';

for (const [role, expected] of [['owner','Owner'],['manager','Manager'],['admin','Admin'],['superintendent','Superintendent'],['gf','General Foreman'],['foreman','Foreman'],['safety','Safety'],['GF','General Foreman'],['','Foreman'],[null,'Foreman'],['unknown-role','Foreman']]) {
  const actual = core.formatTeamRole(role);
  if (actual !== expected) throw new Error(`formatTeamRole(${JSON.stringify(role)}) returned ${JSON.stringify(actual)}; expected ${JSON.stringify(expected)}.`);
}

if (core.formatAuditTimestamp(null) !== 'Not recorded') throw new Error('formatAuditTimestamp(null) must preserve Not recorded.');
if (core.formatAuditTimestamp('not-a-date') !== 'not-a-date') throw new Error('formatAuditTimestamp() must preserve invalid source text.');
const auditDate = '2026-09-11T15:45:00Z';
const expectedAuditDate = vm.runInNewContext(`new Date(${JSON.stringify(auditDate)}).toLocaleString(undefined,{year:'numeric',month:'short',day:'numeric',hour:'numeric',minute:'2-digit'})`);
if (core.formatAuditTimestamp(auditDate) !== expectedAuditDate) throw new Error('formatAuditTimestamp() must match legacy date formatting.');

for (const [value, expected] of [[0,'$0.00'],[1250,'$1,250.00'],[1250.5,'$1,250.50'],[-42.25,'-$42.25'],['99.95','$99.95'],[null,'$0.00'],['','$0.00']]) {
  const actual = core.formatCurrency(value);
  if (actual !== expected) throw new Error(`formatCurrency(${JSON.stringify(value)}) returned ${JSON.stringify(actual)}; expected ${JSON.stringify(expected)}.`);
}

for (const name of helperNames) {
  if (sandbox.window[name] !== core[name]) throw new Error(`App core compatibility bridge ${name} is not active.`);
}
if (!bootstrap.includes("script.src = '/app-core.js?v=20260910a'")) throw new Error('App core module is not bootstrapped by the existing front-end loader path.');
if (!bootstrap.includes('App core module unavailable; using inline compatibility fallback.')) throw new Error('App core loader must retain an explicit inline fallback path.');
if (!serviceWorker.includes("'/app-core.js?v=20260910a'")) throw new Error('App core module must remain in the offline app shell.');
for (const signature of ['function uniqueOfflineJsaJobs(jobs){','function offlineJsaNetworkFailure(error){','function companyAccessInactive(error){','function firstStackFrame(error){','function desktopViewEnabled(){','function currentErrorPage(){','function formatTeamRole(role){','function formatAuditTimestamp(value){','function formatCurrency(value){']) {
  if (!index.includes(signature)) throw new Error(`Legacy inline app-core fallback missing: ${signature}`);
}

console.log('App core modularization guard passed.');
console.log('- low-risk shared helpers match legacy behavior, including currency formatting');
console.log('- compatibility bridges are active');
console.log('- module is available offline and inline fallbacks remain available');
