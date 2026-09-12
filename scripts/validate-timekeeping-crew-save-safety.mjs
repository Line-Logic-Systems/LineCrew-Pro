import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync('number-input-polish.js','utf8');
const start = source.indexOf('/* F1 payroll-data safety guard.');
const end = source.indexOf('/* Staged App Core modularization bootstrap.', start);
if(start < 0 || end < 0) throw new Error('Crew-time safety guard block is missing.');
const guardSource = source.slice(start, end);

function field(value, checked = false){
  return { value, checked };
}
function crewRow({employee='e1', regular='8', overtime='0'} = {}){
  const fields = {
    '.tk-employee': field(employee),
    '.tk-regular': field(regular),
    '.tk-ot': field(overtime)
  };
  return { querySelector(selector){ return fields[selector] || null; } };
}

async function runCase(rows, expectedMessage = ''){
  let calls = 0;
  const sandbox = {
    window:{},
    document:{querySelectorAll(){ return rows; }},
    Error,
    Number,
    Object,
    Array,
    String,
    Set,
    Promise
  };
  vm.runInNewContext(guardSource, sandbox, {filename:'timekeeping-crew-save-safety.js'});
  sandbox.window.saveDailyReportCrewTime = async reportId => { calls += 1; return reportId; };
  let error = null;
  try { await sandbox.window.saveDailyReportCrewTime('report-1'); }
  catch (caught) { error = caught; }
  if(expectedMessage){
    if(!error || !String(error.message).includes(expectedMessage)){
      throw new Error(`Expected save to fail with ${JSON.stringify(expectedMessage)}, got ${error?.message || 'success'}`);
    }
    if(calls !== 0) throw new Error('Original crew-time save ran after validation failed.');
  }else{
    if(error) throw error;
    if(calls !== 1) throw new Error('Valid crew-time snapshot did not reach the original save exactly once.');
  }
}

await runCase([crewRow({employee:''})], 'Select an employee');
await runCase([crewRow({employee:'e1'}), crewRow({employee:'e1'})], 'only once');
await runCase([crewRow({regular:'25'})], 'exceed 24');
await runCase([crewRow({regular:'-1'})], 'negative');
await runCase([crewRow({regular:'abc'})], 'valid numbers');
await runCase([crewRow({employee:'e1',regular:'8',overtime:'2'}),crewRow({employee:'e2',regular:'10',overtime:'0'})]);

console.log('Crew-time destructive-save guard passed.');
console.log('- invalid/duplicate visible rows abort before the existing save function runs');
console.log('- valid rows still delegate to the existing save exactly once');
