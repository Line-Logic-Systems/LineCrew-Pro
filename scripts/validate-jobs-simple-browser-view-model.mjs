import fs from 'node:fs';
import vm from 'node:vm';

const moduleSource = fs.readFileSync('jobs-core.js','utf8');
const index = fs.readFileSync('index.html','utf8');
const sandbox = { window:{} };
vm.runInNewContext(moduleSource, sandbox, { filename:'jobs-core.js' });
const core = sandbox.window.LineCrewJobsCore;

if (!core || typeof core.simpleJobBrowserViewModel !== 'function') {
  throw new Error('Jobs core module must expose simpleJobBrowserViewModel().');
}
if (sandbox.window.simpleJobBrowserViewModel !== core.simpleJobBrowserViewModel) {
  throw new Error('simpleJobBrowserViewModel compatibility bridge is not active.');
}

const jobs = [
  {id:'a1',job_number:'100',job_name:'Alpha Build',active:true},
  {id:'c1',job_number:'200',job_name:'Closed Alpha',active:false},
  {id:'a2',job_number:'300',job_name:'Beta Rebuild',active:true},
  {id:'a3',job_number:'400',job_name:'Gamma Work',active:true}
];

const active = core.simpleJobBrowserViewModel(jobs,{status:'active',visibleCount:2});
if (active.matchingCount !== 3 || active.visibleCount !== 2 || !active.hasMore) {
  throw new Error('Simple Jobs active filter or paging changed.');
}
if (active.visibleJobs.map(job=>job.id).join(',') !== 'a1,a2') {
  throw new Error('Simple Jobs browser must preserve catalog order.');
}

const closed = core.simpleJobBrowserViewModel(jobs,{status:'closed',visibleCount:25});
if (closed.matchingCount !== 1 || closed.visibleJobs[0]?.id !== 'c1' || closed.hasMore) {
  throw new Error('Simple Jobs closed filter changed.');
}

const searchByName = core.simpleJobBrowserViewModel(jobs,{status:'all',search:'alpha',visibleCount:25});
if (searchByName.matchingCount !== 2 || searchByName.visibleJobs.map(job=>job.id).join(',') !== 'a1,c1') {
  throw new Error('Simple Jobs name search changed.');
}

const searchByNumber = core.simpleJobBrowserViewModel(jobs,{status:'all',search:'300',visibleCount:25});
if (searchByNumber.matchingCount !== 1 || searchByNumber.visibleJobs[0]?.id !== 'a2') {
  throw new Error('Simple Jobs number search changed.');
}

const trimmedCaseSearch = core.simpleJobBrowserViewModel(jobs,{status:'all',search:'  GAMMA  ',visibleCount:25});
if (trimmedCaseSearch.matchingCount !== 1 || trimmedCaseSearch.visibleJobs[0]?.id !== 'a3') {
  throw new Error('Simple Jobs search trimming/case behavior changed.');
}

const noJobs = core.simpleJobBrowserViewModel(null,{status:'active',visibleCount:25});
if (noJobs.matchingCount !== 0 || noJobs.visibleCount !== 0 || noJobs.visibleJobs.length !== 0 || noJobs.hasMore) {
  throw new Error('Null Simple Jobs browser input must produce an empty view model.');
}

for (const marker of [
  'function renderSimpleJobBrowser(){',
  "const status = $('simpleJobStatus').value || 'active';",
  "if(status === 'active' && job.active !== true) return false;",
  "if(status === 'closed' && job.active === true) return false;",
  "String(job.job_number || '').toLowerCase().includes(search)",
  "String(job.job_name || '').toLowerCase().includes(search)",
  'matching.slice(0, currentSimpleJobVisibleCount).forEach(renderJob);',
  'if(matching.length > currentSimpleJobVisibleCount){'
]) {
  if (!index.includes(marker)) throw new Error(`Legacy Simple Jobs behavior marker missing: ${marker}`);
}

console.log('Simple Jobs browser view-model guard passed.');
console.log('- active/closed status filtering matches legacy behavior');
console.log('- job number/name search matches legacy behavior');
console.log('- catalog order and visible-count paging are preserved');
console.log('- live Simple Jobs DOM renderer remains unchanged');
