import fs from 'node:fs';
import vm from 'node:vm';

const moduleSource = fs.readFileSync('app-core.js','utf8');
const bootstrap = fs.readFileSync('number-input-polish.js','utf8');
const index = fs.readFileSync('index.html','utf8');
const serviceWorker = fs.readFileSync('service-worker.js','utf8');

let storedDesktopView=null,fallbackDesktopClass=false,throwStorage=false,pageSections=[];
const sandbox={window:{location:{pathname:'/index.html'}},navigator:{onLine:true},localStorage:{getItem(key){if(throwStorage)throw new Error('storage unavailable');return key==='linecrew-pro-desktop-view'?storedDesktopView:null;}},document:{documentElement:{classList:{contains:name=>name==='desktop-view'&&fallbackDesktopClass}},querySelectorAll(selector){return selector==='main > section'?pageSections:[];}}};
vm.runInNewContext(moduleSource,sandbox,{filename:'app-core.js'});
const core=sandbox.window.LineCrewAppCore;
const helperNames=['uniqueOfflineJsaJobs','offlineJsaNetworkFailure','companyAccessInactive','firstStackFrame','desktopViewEnabled','currentErrorPage','formatTeamRole','formatAuditTimestamp','formatCurrency','csvCell','companyLogoExtension','companyJsaFileKey','safeJsaFilename','allowedJsaFile'];
for(const name of helperNames) if(!core||typeof core[name]!=='function') throw new Error(`App core module must expose ${name}().`);

if(JSON.stringify(core.uniqueOfflineJsaJobs([{id:'1',job_number:'A1',job_name:'Alpha'},{id:'1'}]))!==JSON.stringify([{id:'1',job_number:'A1',job_name:'Alpha'}])) throw new Error('uniqueOfflineJsaJobs parity failed.');
sandbox.navigator.onLine=true;if(core.offlineJsaNetworkFailure({message:'Failed to fetch'})!==true||core.offlineJsaNetworkFailure({message:'Permission denied'})!==false)throw new Error('offlineJsaNetworkFailure parity failed.');
if(core.companyAccessInactive({message:'Company access is inactive'})!==true||core.companyAccessInactive({message:'Permission denied'})!==false)throw new Error('companyAccessInactive parity failed.');
if(core.firstStackFrame({stack:'Error\n at x (app.js:1:2)'})!=='at x (app.js:1:2)')throw new Error('firstStackFrame parity failed.');
storedDesktopView='1';if(core.desktopViewEnabled()!==true)throw new Error('desktopViewEnabled parity failed.');
const section=(id,hidden)=>({id,classList:{contains:name=>name==='hidden'?hidden:false}});pageSections=[section('productionPage',false)];if(core.currentErrorPage()!=='productionPage')throw new Error('currentErrorPage parity failed.');
if(core.formatTeamRole('gf')!=='General Foreman'||core.formatTeamRole('unknown')!=='Foreman')throw new Error('formatTeamRole parity failed.');
if(core.formatAuditTimestamp(null)!=='Not recorded'||core.formatAuditTimestamp('not-a-date')!=='not-a-date')throw new Error('formatAuditTimestamp parity failed.');
if(core.formatCurrency(1250.5)!=='$1,250.50')throw new Error('formatCurrency parity failed.');
if(core.csvCell('=SUM(A1:A2)')!=="'=SUM(A1:A2)"||core.csvCell('a,b')!=='"a,b"')throw new Error('csvCell parity failed.');
if(core.companyLogoExtension({type:'image/jpeg'})!=='jpg'||core.companyLogoExtension({type:'image/gif'})!=='')throw new Error('companyLogoExtension parity failed.');
if(core.companyJsaFileKey({name:'jsa.jpg',size:12,lastModified:34})!=='jsa.jpg:12:34')throw new Error('companyJsaFileKey parity failed.');
if(core.safeJsaFilename('JSA Page 1.jpg')!=='JSA-Page-1.jpg')throw new Error('safeJsaFilename parity failed.');
const max=15728640;
for(const [file,expected] of [
  [{type:'application/pdf',size:1},true],
  [{type:'image/jpeg',size:max},true],
  [{type:'image/png',size:100},true],
  [{type:'image/heic',size:100},true],
  [{type:'image/heif',size:100},true],
  [{type:'IMAGE/JPEG',size:100},true],
  [{type:'image/gif',size:100},false],
  [{type:'application/pdf',size:0},false],
  [{type:'application/pdf',size:max+1},false],
  [null,false]
]) {
  const actual=core.allowedJsaFile(file);
  if(actual!==expected) throw new Error(`allowedJsaFile(${JSON.stringify(file)}) returned ${actual}; expected ${expected}.`);
}

for(const name of helperNames) if(sandbox.window[name]!==core[name]) throw new Error(`App core compatibility bridge ${name} is not active.`);
if(!bootstrap.includes("script.src = '/app-core.js?v=20260910a'"))throw new Error('App core module is not bootstrapped.');
if(!bootstrap.includes('App core module unavailable; using inline compatibility fallback.'))throw new Error('App core loader must retain fallback.');
if(!serviceWorker.includes("'/app-core.js?v=20260910a'"))throw new Error('App core module must remain offline-capable.');
for(const signature of ['function uniqueOfflineJsaJobs(jobs){','function offlineJsaNetworkFailure(error){','function companyAccessInactive(error){','function firstStackFrame(error){','function desktopViewEnabled(){','function currentErrorPage(){','function formatTeamRole(role){','function formatAuditTimestamp(value){','function formatCurrency(value){','function csvCell(value){','function companyLogoExtension(file){','function companyJsaFileKey(file){','function safeJsaFilename(name){','function allowedJsaFile(file){']) if(!index.includes(signature)) throw new Error(`Legacy inline app-core fallback missing: ${signature}`);

console.log('App core modularization guard passed.');
console.log('- low-risk shared helpers match legacy behavior, including JSA file validation');
console.log('- compatibility bridges are active; module is offline-capable; inline fallbacks remain available');
