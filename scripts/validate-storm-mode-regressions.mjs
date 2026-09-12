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
const stormLock = read('supabase/migrations/20260912004620_lock_daily_report_storm_context.sql');

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

for(const [token,message] of [
  ['add column if not exists storm_context_set_at timestamptz', 'Daily Reports need a persisted storm-context lock marker.'],
  ['set storm_context_set_at = coalesce(updated_at, created_at, now())', 'Existing Daily Reports must be treated as already classified so history cannot be re-stamped.'],
  ['for update;', 'Storm context initialization must serialize concurrent first saves.'],
  ['if v_context_set_at is not null then', 'Storm context must become immutable after its first classification.'],
  ['and storm_context_set_at is null;', 'Storm classification update must be set-once at the database level.'],
  ['create or replace function public.linecrew_sync_timekeeping_storm_context()', 'Timekeeping storm flags need a server-side source of truth.'],
  ['select dr.storm_mode', 'Timekeeping rows must inherit the locked Daily Report storm classification.'],
  ['before insert or update of daily_report_id, storm_work', 'Timekeeping storm context trigger is missing.']
]) need(stormLock, token, message);

const superintendentChecks = (stormLock.match(/v_role = 'superintendent' and not public\.linecrew_has_capability\('storm_mode'\)/g) || []).length;
if(superintendentChecks !== 1) throw new Error(`Storm context should contain exactly one Superintendent capability check; found ${superintendentChecks}.`);

console.log('Storm Mode regression guards passed.');
console.log('- historical Daily Report storm context is locked after first classification');
console.log('- crew time linked to a report inherits that report storm context');
