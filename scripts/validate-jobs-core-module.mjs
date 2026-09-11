import fs from 'node:fs';
import vm from 'node:vm';

const moduleSource = fs.readFileSync('jobs-core.js','utf8');
const bootstrap = fs.readFileSync('number-input-polish.js','utf8');
const index = fs.readFileSync('index.html','utf8');
const serviceWorker = fs.readFileSync('service-worker.js','utf8');

const sandbox = { window:{} };
vm.runInNewContext(moduleSource, sandbox, { filename:'jobs-core.js' });
const core = sandbox.window.LineCrewJobsCore;
const helperNames = ['fileNameWithoutExtension','jobPacketFileValidationMessage','formatCompletedJobDate','completedJobUnitRows'];
for (const name of helperNames) {
  if (!core || typeof core[name] !== 'function') throw new Error(`Jobs core module must expose ${name}().`);
}

const nameCases = [
  ['packet.pdf','packet'],
  ['job.packet.v2.xlsx','job.packet.v2'],
  ['no-extension','no-extension'],
  ['', 'Job Packet'],
  [null, 'Job Packet'],
  ['.hidden','']
];
for (const [input, expected] of nameCases) {
  const actual = core.fileNameWithoutExtension(input);
  if (actual !== expected) throw new Error(`fileNameWithoutExtension(${JSON.stringify(input)}) returned ${JSON.stringify(actual)}; expected ${JSON.stringify(expected)}.`);
}

const maxPdf = 20 * 1024 * 1024;
const fileCases = [
  [null, ''],
  [{name:'packet.pdf',size:0}, ''],
  [{name:'packet.PDF',size:maxPdf}, ''],
  [{name:'packet.pdf',size:maxPdf + 1}, 'The PDF job jacket must be 20 MB or smaller.'],
  [{name:'packet.xlsx',size:maxPdf * 10}, ''],
  [{name:'packet.csv',size:1}, ''],
  [{name:'packet.tsv',size:1}, ''],
  [{name:'packet.txt',size:1}, ''],
  [{name:'packet.xls',size:1}, ''],
  [{name:'packet.ods',size:1}, ''],
  [{name:'packet.docx',size:1}, 'Choose a PDF, Excel, CSV, TSV, TXT or ODS job jacket.'],
  [{name:'packet',size:1}, 'Choose a PDF, Excel, CSV, TSV, TXT or ODS job jacket.']
];
for (const [file, expected] of fileCases) {
  const actual = core.jobPacketFileValidationMessage(file);
  if (actual !== expected) throw new Error(`jobPacketFileValidationMessage(${JSON.stringify(file)}) returned ${JSON.stringify(actual)}; expected ${JSON.stringify(expected)}.`);
}

const dateValue = '2026-09-10T15:30:00Z';
if (core.formatCompletedJobDate(null) !== 'Not recorded') {
  throw new Error('formatCompletedJobDate(null) must preserve the Not recorded fallback.');
}
const expectedDate = vm.runInNewContext(`new Date(${JSON.stringify(dateValue)}).toLocaleString()`);
const actualDate = core.formatCompletedJobDate(dateValue);
if (actualDate !== expectedDate) {
  throw new Error(`formatCompletedJobDate() returned ${JSON.stringify(actualDate)}; expected ${JSON.stringify(expectedDate)}.`);
}

const unitRecord = {units:[{
  work_date:'2026-09-10',foreman_name:'Alex Foreman',crew_name:'Crew 1',
  pole_location:'WP-12',work_point:'WP-FALLBACK',item_code:'U100',unit_code:'ALT',
  item_name:'Primary description',unit_name:'Secondary',description:'Fallback',
  install_quantity:'2.5',transfer_quantity:'1',retirement_quantity:'0',remove_quantity:'4',
  authorization_status:'approved_redline',visible_line_value:'125.50',adjusted_line_value:'99',actual_line_value:'80'
},{
  work_point:'WP-2',unit_code:'U200',description:'Fallback description',remove_quantity:'3',actual_line_value:'45'
}]};
const expectedUnitRows = [{
  'Work Date':'2026-09-10','Foreman':'Alex Foreman','Crew':'Crew 1','Pole / Work Point':'WP-12',
  'Unit Code':'U100','Description':'Primary description','Installed':2.5,'Transferred':1,'Removed':0,
  'Authorization':'approved redline','Visible Value':125.5
},{
  'Work Date':'','Foreman':'','Crew':'','Pole / Work Point':'WP-2','Unit Code':'U200',
  'Description':'Fallback description','Installed':0,'Transferred':0,'Removed':3,'Authorization':'','Visible Value':45
}];
const actualUnitRows = core.completedJobUnitRows(unitRecord);
if (JSON.stringify(actualUnitRows) !== JSON.stringify(expectedUnitRows)) {
  throw new Error(`completedJobUnitRows() parity failed: ${JSON.stringify(actualUnitRows)}`);
}

for (const name of helperNames) {
  if (sandbox.window[name] !== core[name]) throw new Error(`Jobs core compatibility bridge ${name} is not active.`);
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
for (const signature of [
  'function fileNameWithoutExtension(value){',
  'function jobPacketFileValidationMessage(file){',
  'function formatCompletedJobDate(value){',
  'function completedJobUnitRows(record){'
]) {
  if (!index.includes(signature)) throw new Error(`Legacy inline Jobs fallback missing: ${signature}`);
}

console.log('Jobs core modularization guard passed.');
console.log('- packet filename display helper matches legacy behavior');
console.log('- packet file type/size validation matches legacy behavior');
console.log('- completed-job date formatting matches legacy behavior');
console.log('- completed-job unit export/display row formatting matches legacy behavior');
console.log('- compatibility bridges are active');
console.log('- module is available offline');
console.log('- inline fallbacks remain available if the module cannot load');
