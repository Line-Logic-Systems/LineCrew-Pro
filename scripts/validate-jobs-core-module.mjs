import fs from 'node:fs';
import vm from 'node:vm';

const moduleSource = fs.readFileSync('jobs-core.js','utf8');
const bootstrap = fs.readFileSync('number-input-polish.js','utf8');
const index = fs.readFileSync('index.html','utf8');
const serviceWorker = fs.readFileSync('service-worker.js','utf8');

const sandbox = { window:{} };
vm.runInNewContext(moduleSource, sandbox, { filename:'jobs-core.js' });
const core = sandbox.window.LineCrewJobsCore;
const helperNames = ['fileNameWithoutExtension','jobPacketFileValidationMessage','formatCompletedJobDate','completedJobUnitRows','jobPackageRevisionLabel','normalizeJobPacketPoint','jobProgressViewModel','jobPackagesForJob','jobPackageOpenButtonLabel','jobPackageDetailSubtitle','completedJobSummaryViewModel'];
for (const name of helperNames) {
  if (!core || typeof core[name] !== 'function') throw new Error(`Jobs core module must expose ${name}().`);
}

for (const [input, expected] of [['packet.pdf','packet'],['job.packet.v2.xlsx','job.packet.v2'],['no-extension','no-extension'],['','Job Packet'],[null,'Job Packet'],['.hidden','']]) {
  const actual = core.fileNameWithoutExtension(input);
  if (actual !== expected) throw new Error(`fileNameWithoutExtension(${JSON.stringify(input)}) returned ${JSON.stringify(actual)}; expected ${JSON.stringify(expected)}.`);
}

const maxPdf = 20 * 1024 * 1024;
for (const [file, expected] of [[null,''],[{name:'packet.pdf',size:0},''],[{name:'packet.PDF',size:maxPdf},''],[{name:'packet.pdf',size:maxPdf+1},'The PDF job jacket must be 20 MB or smaller.'],[{name:'packet.xlsx',size:maxPdf*10},''],[{name:'packet.csv',size:1},''],[{name:'packet.tsv',size:1},''],[{name:'packet.txt',size:1},''],[{name:'packet.xls',size:1},''],[{name:'packet.ods',size:1},''],[{name:'packet.docx',size:1},'Choose a PDF, Excel, CSV, TSV, TXT or ODS job jacket.'],[{name:'packet',size:1},'Choose a PDF, Excel, CSV, TSV, TXT or ODS job jacket.']]) {
  const actual = core.jobPacketFileValidationMessage(file);
  if (actual !== expected) throw new Error(`jobPacketFileValidationMessage(${JSON.stringify(file)}) returned ${JSON.stringify(actual)}; expected ${JSON.stringify(expected)}.`);
}

const dateValue = '2026-09-10T15:30:00Z';
if (core.formatCompletedJobDate(null) !== 'Not recorded') throw new Error('formatCompletedJobDate(null) must preserve the Not recorded fallback.');
const expectedDate = vm.runInNewContext(`new Date(${JSON.stringify(dateValue)}).toLocaleString()`);
if (core.formatCompletedJobDate(dateValue) !== expectedDate) throw new Error('formatCompletedJobDate() must match legacy locale formatting.');

const unitRecord = {units:[{work_date:'2026-09-10',foreman_name:'Alex Foreman',crew_name:'Crew 1',pole_location:'WP-12',work_point:'WP-FALLBACK',item_code:'U100',unit_code:'ALT',item_name:'Primary description',unit_name:'Secondary',description:'Fallback',install_quantity:'2.5',transfer_quantity:'1',retirement_quantity:'0',remove_quantity:'4',authorization_status:'approved_redline',visible_line_value:'125.50',adjusted_line_value:'99',actual_line_value:'80'},{work_point:'WP-2',unit_code:'U200',description:'Fallback description',remove_quantity:'3',actual_line_value:'45'}]};
const expectedUnitRows = [
  {'Work Date':'2026-09-10','Foreman':'Alex Foreman','Crew':'Crew 1','Pole / Work Point':'WP-12','Unit Code':'U100','Description':'Primary description','Installed':2.5,'Transferred':1,'Removed':0,'Authorization':'approved redline','Visible Value':125.5},
  {'Work Date':'','Foreman':'','Crew':'','Pole / Work Point':'WP-2','Unit Code':'U200','Description':'Fallback description','Installed':0,'Transferred':0,'Removed':3,'Authorization':'','Visible Value':45}
];
if (JSON.stringify(core.completedJobUnitRows(unitRecord)) !== JSON.stringify(expectedUnitRows)) throw new Error('completedJobUnitRows() parity failed.');

for (const [packet, expected] of [[null,'Original Packet'],[{revision_number:0},'Original Packet'],[{revision_number:1},'Original Packet'],[{revision_number:2},'Revision 1'],[{revision_number:'5'},'Revision 4']]) {
  const actual = core.jobPackageRevisionLabel(packet);
  if (actual !== expected) throw new Error(`jobPackageRevisionLabel(${JSON.stringify(packet)}) returned ${actual}; expected ${expected}.`);
}

for (const [input, expected] of [
  ['Pole #001','1'],
  ['WP-0007','7'],
  ['Work Point 12','12'],
  ['work_point: 003','3'],
  ['A-12','a12'],
  ['  Pole B-07  ','b07'],
  ['', ''],
  [null, ''],
  ['000', '0']
]) {
  const actual = core.normalizeJobPacketPoint(input);
  if (actual !== expected) throw new Error(`normalizeJobPacketPoint(${JSON.stringify(input)}) returned ${JSON.stringify(actual)}; expected ${JSON.stringify(expected)}.`);
}

const jobs = [
  {id:'j10',job_number:'10',job_name:'Beta Rebuild',active:true,contracts:{contract_name:'South',contract_number:'2',customers:{name:'Utility B'}}},
  {id:'j2',job_number:'2',job_name:'Alpha Work',active:true,contracts:{contract_name:'North',contract_number:'1',customers:{name:'Utility A'}}},
  {id:'j5',job_number:'5',job_name:'Closed Alpha',active:false,contracts:{contract_name:'North',contract_number:'1',customers:{name:'Utility A'}}},
  {id:'j20',job_number:'20',job_name:'No Contract Job',active:true,utility_name:'Utility A'}
];

const activeView = core.jobProgressViewModel(jobs,{attention:'',sort:'',visibleCount:10});
if (activeView.matchingCount !== 3) throw new Error(`Default Jobs progress filter must show active jobs only; got ${activeView.matchingCount}.`);
if (activeView.visibleJobs.map(job=>job.id).join(',') !== 'j20,j2,j10') throw new Error(`Utility/contract/job default sort changed: ${activeView.visibleJobs.map(job=>job.id).join(',')}.`);
if (activeView.groups.length !== 2 || activeView.groups[0].utility !== 'Utility A' || activeView.groups[1].utility !== 'Utility B') throw new Error('Jobs utility grouping changed.');
if (activeView.groups[0].contracts.length !== 2) throw new Error('Jobs contract grouping changed.');

const closedView = core.jobProgressViewModel(jobs,{attention:'closed',visibleCount:10});
if (closedView.matchingCount !== 1 || closedView.visibleJobs[0]?.id !== 'j5') throw new Error('Closed Jobs progress filter changed.');

const searchView = core.jobProgressViewModel(jobs,{attention:'all',search:'beta',visibleCount:10});
if (searchView.matchingCount !== 1 || searchView.visibleJobs[0]?.id !== 'j10') throw new Error('Jobs progress search behavior changed.');

const numberView = core.jobProgressViewModel(jobs,{attention:'all',sort:'job_number',visibleCount:3});
if (numberView.matchingCount !== 4 || numberView.visibleJobs.map(job=>job.job_number).join(',') !== '2,5,10') throw new Error('Numeric job-number sorting or paging changed.');

const noJobs = core.jobProgressViewModel(null,{visibleCount:25});
if (noJobs.matchingCount !== 0 || noJobs.visibleJobs.length !== 0 || noJobs.groups.length !== 0) throw new Error('Null Jobs progress input must produce an empty view model.');

const packages = [
  {id:'p1', job_id:'j1'},
  {id:'p2', job_id:'j2'},
  {id:'p3', job_id:1},
  {id:'p4', job_id:null}
];
const jobOnePackages = core.jobPackagesForJob(packages,'j1');
if (jobOnePackages.length !== 1 || jobOnePackages[0]?.id !== 'p1') throw new Error('Job package filtering by string id changed.');
const numericJobPackages = core.jobPackagesForJob(packages,'1');
if (numericJobPackages.length !== 1 || numericJobPackages[0]?.id !== 'p3') throw new Error('Job package id string coercion changed.');
if (core.jobPackagesForJob(null,'j1').length !== 0) throw new Error('Null job-package catalog must return an empty list.');

for (const [count, expected] of [[1,'Open Package'],[2,'View Packages'],[0,'View Packages'],['1','Open Package'],[null,'View Packages']]) {
  const actual = core.jobPackageOpenButtonLabel(count);
  if (actual !== expected) throw new Error(`jobPackageOpenButtonLabel(${JSON.stringify(count)}) returned ${actual}; expected ${expected}.`);
}

for (const [packet, expected] of [
  [{package_number:'WO-100',status:'approved',source_filename:'packet.pdf'},'Reference: WO-100 · Status: APPROVED · Source: packet.pdf'],
  [{package_number:'WO-200',status:'draft'},'Reference: WO-200 · Status: DRAFT'],
  [{status:'review'},'Reference: Not provided · Status: REVIEW'],
  [{},'Reference: Not provided · Status: DRAFT']
]) {
  const actual = core.jobPackageDetailSubtitle(packet);
  if (actual !== expected) throw new Error(`jobPackageDetailSubtitle(${JSON.stringify(packet)}) returned ${JSON.stringify(actual)}; expected ${JSON.stringify(expected)}.`);
}

const completedSummary = core.completedJobSummaryViewModel({
  progress:{reported_percent:'82.35',approved_percent:79},
  reports:[{},{}],
  units:[{},{},{}],
  packages:[{}],
  jsas:[{},{},{},{}],
  attachments:[{},{}]
});
const expectedSummary = {reportedPercent:'82.3',approvedPercent:'79.0',dailyReports:2,unitLines:3,packetRevisions:1,jsas:4,attachments:2};
if (JSON.stringify(completedSummary) !== JSON.stringify(expectedSummary)) throw new Error(`Completed job summary display changed: ${JSON.stringify(completedSummary)}.`);
const emptyCompletedSummary = core.completedJobSummaryViewModel(null);
if (JSON.stringify(emptyCompletedSummary) !== JSON.stringify({reportedPercent:'0.0',approvedPercent:'0.0',dailyReports:0,unitLines:0,packetRevisions:0,jsas:0,attachments:0})) {
  throw new Error('Null completed-job summary input must remain safe and empty.');
}

for (const name of helperNames) {
  if (sandbox.window[name] !== core[name]) throw new Error(`Jobs core compatibility bridge ${name} is not active.`);
}
if (!bootstrap.includes("script.src = '/jobs-core.js?v=20260910a'")) throw new Error('Jobs core module is not bootstrapped by the existing front-end loader path.');
if (!bootstrap.includes('Jobs core module unavailable; using inline compatibility fallback.')) throw new Error('Jobs core loader must retain an explicit inline fallback path.');
if (!serviceWorker.includes("'/jobs-core.js?v=20260910a'")) throw new Error('Jobs core module must remain in the offline app shell.');
for (const signature of ['function fileNameWithoutExtension(value){','function jobPacketFileValidationMessage(file){','function formatCompletedJobDate(value){','function completedJobUnitRows(record){','function jobPackageRevisionLabel(jobPackage){','function normalizeJobPacketPoint(value){']) {
  if (!index.includes(signature)) throw new Error(`Legacy inline Jobs fallback missing: ${signature}`);
}
for (const marker of [
  'function renderJobProgressDashboard(jobs, canView = true){',
  "if(attention === '' && job.active !== true) return false;",
  "if(attention === 'closed' && job.active === true) return false;",
  'const searchable = [job.job_number,job.job_name,utilityLabel(job),contractLabel(job)]',
  "if(sort === 'job_number'){",
  'const visibleJobs = sortedJobs.slice(0, currentJobProgressVisibleCount);',
  'if(!grouped.has(utility)) grouped.set(utility,new Map());',
  'if(!contracts.has(contract)) contracts.set(contract,[]);',
  'const jobPackages = currentJobPackageCatalog.filter(',
  'jobPackage => String(jobPackage.job_id) === String(job.id)',
  "openPackageButton.textContent = jobPackages.length === 1 ? 'Open Package' : 'View Packages';",
  "const source = currentOpenJobPackage.source_filename",
  "'Reference: ' + (currentOpenJobPackage.package_number || 'Not provided') +",
  "' · Status: ' + status.toUpperCase() + source;",
  "Number(p.reported_percent||0).toFixed(1)+'%'",
  "Number(p.approved_percent||0).toFixed(1)+'%'",
  "Number(r.reports.length)+'</strong><br>Daily Reports'",
  "Number(r.units.length)+'</strong><br>Unit Lines'",
  "Number(r.packages.length)+'</strong><br>Packet Revisions'",
  "Number(r.jsas.length)+'</strong><br>JSAs'",
  "Number(r.attachments.length)+'</strong><br>Attachments'"
]) {
  if (!index.includes(marker)) throw new Error(`Legacy Jobs progress behavior marker missing: ${marker}`);
}

console.log('Jobs core modularization guard passed.');
console.log('- existing Jobs helpers and job-packet normalization match legacy behavior');
console.log('- Jobs progress, package detail, and completed-job summary display values are parity-tested');
console.log('- compatibility bridges are active; module is offline-capable; inline renderers remain available');
