import fs from 'node:fs';

function read(path){
  if(!fs.existsSync(path)) throw new Error(`Missing Storm Mode dependency: ${path}`);
  return fs.readFileSync(path,'utf8');
}
function need(source, token, message){
  if(!source.includes(token)) throw new Error(message);
}

const app = read('index.html');
const timekeeping = read('timekeeping.js');
const expandedJsa = read('expanded-jsa-core.js');

need(app, 'saveStormModeSetting', 'Storm Mode save control is missing.');
need(app, 'set_company_storm_mode', 'Storm Mode company RPC wiring is missing.');
need(app, 'stormExportReports', 'Storm reporting export function is missing.');
need(app, 'userCanManageStormMode', 'Storm Mode capability guard is missing.');
need(app, 'storm_mode_assignments', 'Storm crew assignment wiring is missing.');
need(timekeeping, 'storm_work', 'Storm flag is missing from timekeeping reporting.');
need(expandedJsa, 'storm_energy_control', 'Storm/Energy JSA section is missing.');

for(const token of ['storm_mode_enabled','storm_event_name','storm_started_at','storm_ended_at']){
  if(!app.includes(token) && !read('supabase/migrations/archive/20260817_jsa_storm_mode.sql').includes(token)){
    throw new Error(`Storm Mode state field is missing: ${token}`);
  }
}

console.log('Storm Mode regression guards passed.');
