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
const helperNames=['uniqueOfflineJsaJobs','offlineJsaNetworkFailure','companyAccessInactive','firstStackFrame','desktopViewEnabled','currentErrorPage','formatTeamRole','formatAuditTimestamp','formatCurrency','csvCell','companyLogoExtension'];
for(const name of helperNames) if(!core||typeof core[name]!=='function') throw new Error(`App core module must expose ${name}().`);

const jobs=[[[],[]],[[{id:'1',job_number:'A1',job_name:'Alpha'}],[{id:'1',job_number:'A1',job_name:'Alpha'}]],[[{id:'1',job_number:'A1',job_name:'Alpha'},{id:'1'}],[{id:'1',job_number:'A1',job_name:'Alpha'}]]];
for(const [input,expected] of jobs) if(JSON.stringify(core.uniqueOfflineJsaJobs(input))!==JSON.stringify(expected)) throw new Error('uniqueOfflineJsaJobs parity failed.');
for(const [error,expected] of [[{message:'Failed to fetch'},true],[{message:'Permission denied'},false],[null,false]]){sandbox.navigator.onLine=true;if(core.offlineJsaNetworkFailure(error)!==expected)throw new Error('offlineJsaNetworkFailure parity failed.');}
sandbox.navigator.onLine=false;if(core.offlineJsaNetworkFailure({message:'Permission denied'})!==true)throw new Error('offlineJsaNetworkFailure offline parity failed.');sandbox.navigator.onLine=true;
for(const [error,expected] of [[{message:'Company access is inactive'},true],[{message:'Permission denied'},false],[null,false]]) if(core.companyAccessInactive(error)!==expected) throw new Error('companyAccessInactive parity failed.');
if(core.firstStackFrame({stack:'Error\n at x (app.js:1:2)'})!=='at x (app.js:1:2)') throw new Error('firstStackFrame parity failed.');
storedDesktopView='1';if(core.desktopViewEnabled()!==true)throw new Error('desktopViewEnabled true failed.');storedDesktopView='0';if(core.desktopViewEnabled()!==false)throw new Error('desktopViewEnabled false failed.');throwStorage=true;fallbackDesktopClass=true;if(core.desktopViewEnabled()!==true)throw new Error('desktopViewEnabled fallback failed.');throwStorage=false;
const section=(id,hidden)=>({id,classList:{contains:name=>name==='hidden'?hidden:false}});pageSections=[section('productionPage',false)];if(core.currentErrorPage()!=='productionPage')throw new Error('currentErrorPage failed.');
for(const [role,expected] of [['owner','Owner'],['gf','General Foreman'],['unknown','Foreman']]) if(core.formatTeamRole(role)!==expected)throw new Error('formatTeamRole parity failed.');
if(core.formatAuditTimestamp(null)!=='Not recorded'||core.formatAuditTimestamp('not-a-date')!=='not-a-date')throw new Error('formatAuditTimestamp parity failed.');
for(const [value,expected] of [[0,'$0.00'],[1250.5,'$1,250.50'],[null,'$0.00']]) if(core.formatCurrency(value)!==expected)throw new Error('formatCurrency parity failed.');
for(const [value,expected] of [[null,''],['a,b','"a,b"'],['=SUM(A1:A2)',"'=SUM(A1:A2)"],[123,'123']]) if(core.csvCell(value)!==expected)throw new Error('csvCell parity failed.');
for(const [file,expected] of [[{type:'image/png'},'png'],[{type:'image/jpeg'},'jpg'],[{type:'image/webp'},'webp'],[{type:'image/gif'},''],[null,'']]) if(core.companyLogoExtension(file)!==expected) throw new Error(`companyLogoExtension(${JSON.stringify(file)}) parity failed.`);

for(const name of helperNames) if(sandbox.window[name]!==core[name]) throw new Error(`App core compatibility bridge ${name} is not active.`);
if(!bootstrap.includes("script.src = '/app-core.js?v=20260910a'"))throw new Error('App core module is not bootstrapped.');
if(!bootstrap.includes('App core module unavailable; using inline compatibility fallback.'))throw new Error('App core loader must retain fallback.');
if(!serviceWorker.includes("'/app-core.js?v=20260910a'"))throw new Error('App core module must remain offline-capable.');
for(const signature of ['function uniqueOfflineJsaJobs(jobs){','function offlineJsaNetworkFailure(error){','function companyAccessInactive(error){','function firstStackFrame(error){','function desktopViewEnabled(){','function currentErrorPage(){','function formatTeamRole(role){','function formatAuditTimestamp(value){','function formatCurrency(value){','function csvCell(value){','function companyLogoExtension(file){']) if(!index.includes(signature)) throw new Error(`Legacy inline app-core fallback missing: ${signature}`);

console.log('App core modularization guard passed.');
console.log('- low-risk shared helpers match legacy behavior, including company logo extension detection');
console.log('- compatibility bridges are active; module is offline-capable; inline fallbacks remain available');
