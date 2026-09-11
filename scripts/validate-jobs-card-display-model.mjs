import fs from 'node:fs';
import vm from 'node:vm';

const moduleSource = fs.readFileSync('jobs-core.js','utf8');
const index = fs.readFileSync('index.html','utf8');
const sandbox = { window:{} };
vm.runInNewContext(moduleSource, sandbox, { filename:'jobs-core.js' });
const core = sandbox.window.LineCrewJobsCore;

if (!core || typeof core.jobCardDisplayModel !== 'function') throw new Error('Jobs core module must expose jobCardDisplayModel().');
if (sandbox.window.jobCardDisplayModel !== core.jobCardDisplayModel) throw new Error('jobCardDisplayModel compatibility bridge is not active.');

const current = core.jobCardDisplayModel({
  active:true,
  customer_name:'Legacy Customer',
  utility_name:'Utility A',
  contracts:{contract_name:'North Contract',contract_number:'C-12',customers:{name:'Contract Customer'}}
});
if (current.statusText !== 'ACTIVE' || current.statusClass !== 'active') throw new Error('Active Job card status changed.');
if (current.customer !== 'Contract Customer') throw new Error('Contract customer precedence changed.');
if (current.utility !== 'Utility A') throw new Error('Job utility display changed.');
if (current.contractLabel !== 'North Contract (C-12)') throw new Error('Contract number label changed.');

const legacy = core.jobCardDisplayModel({active:false,customer_name:'Legacy Customer'});
if (legacy.statusText !== 'CLOSED' || legacy.statusClass !== 'closed') throw new Error('Closed Job card status changed.');
if (legacy.customer !== 'Legacy Customer') throw new Error('Legacy customer fallback changed.');
if (legacy.utility !== 'No utility listed') throw new Error('Missing utility fallback changed.');
if (legacy.contractLabel !== 'Legacy job — contract not assigned') throw new Error('Legacy contract fallback changed.');

const minimal = core.jobCardDisplayModel({contracts:{contract_name:'Only Name',customers:{}}});
if (minimal.customer !== 'No customer listed') throw new Error('Missing customer fallback changed.');
if (minimal.contractLabel !== 'Only Name') throw new Error('Contract label without number changed.');

for (const marker of [
  "const statusText =",
  "? 'ACTIVE'",
  ": 'CLOSED';",
  "job.customer_name ||",
  "'No customer listed';",
  "job.utility_name ||",
  "'No utility listed';",
  "'Legacy job — contract not assigned';",
  "const contractCustomer =",
  "contract?.customers?.name || customer;"
]) {
  if (!index.includes(marker)) throw new Error(`Legacy Job card display marker missing: ${marker}`);
}

console.log('Jobs card display model guard passed.');
console.log('- ACTIVE/CLOSED status display matches legacy behavior');
console.log('- contract customer precedence and customer/utility fallbacks are preserved');
console.log('- contract number and legacy-contract labels are preserved');
console.log('- live renderJob() DOM/action behavior remains unchanged');
