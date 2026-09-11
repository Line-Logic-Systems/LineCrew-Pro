import fs from 'node:fs';

function read(path){
  if(!fs.existsSync(path)) throw new Error(`Missing GF scope dependency: ${path}`);
  return fs.readFileSync(path,'utf8');
}
function need(source, token, message){
  if(!source.includes(token)) throw new Error(message);
}

const gf = read('gf-crew-scope.js');
const migration = read('supabase/migrations/archive/20260826090000_gf_foreman_scope_and_scoped_jsas.sql');

for(const [token,message] of [
  ["sessionStorage.getItem('linecrew-gf-show-all-crews')",'GF coverage-mode state is missing.'],
  ["return role() === 'gf' && !showAll()",'GF normal crew-scoping rule is missing.'],
  ["rpc('get_gf_crew_assignment_roster')",'GF assignment roster load is missing.'],
  ["rpc('get_company_general_foremen')",'General Foreman roster load is missing.'],
  ["rpc('set_gf_crew_assignment'",'GF crew assignment save path is missing.'],
  ["installScopeBar('productionPage','gfProductionScopeBar')",'GF Production scope control is missing.'],
  ["installScopeBar('safetyPage','gfSafetyScopeBar')",'GF Safety/JSA scope control is missing.'],
  ['installAdminAssignments()','GF/Admin assignment UI wiring is missing.'],
  ['installJsaHistoryControls()','JSA history controls are missing.'],
  ['installJsaPaginationReset()','JSA pagination-reset wiring is missing.'],
  ['paginateJsaHistory()','JSA history pagination is missing.'],
  ['observerTimer=setTimeout(refreshUi,80)','GF observer refresh must remain debounced while legacy broad observation exists.'],
  ["window.addEventListener('pageshow',scheduleRefresh)",'GF scope must refresh after browser page restore.']
]) need(gf,token,message);

for(const token of ['get_gf_crew_assignment_roster','get_company_general_foremen','set_gf_crew_assignment','get_company_jsas_scoped']){
  need(migration,token,`GF database contract is missing: ${token}`);
}

if(!migration.includes("lower(coalesce(p.role,'')) = 'foreman'")){
  throw new Error('GF assignments must stay limited to Foreman profiles.');
}
if(!migration.includes("lower(coalesce(p.role,'')) = 'gf'")){
  throw new Error('GF assignment targets must stay limited to General Foreman profiles.');
}

console.log('GF scope regression fence passed.');
