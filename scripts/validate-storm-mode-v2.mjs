import fs from 'node:fs';

const html=fs.readFileSync('index.html','utf8');
const js=fs.readFileSync('storm-mode-v2.js','utf8');
const css=fs.readFileSync('storm-mode-v2.css','utf8');
const sw=fs.readFileSync('service-worker.js','utf8');
const migration=fs.readFileSync('supabase/migrations/20260909053945_storm_event_workspace_v2.sql','utf8');
const failures=[];
const requireText=(source,text,message)=>{if(!source.includes(text))failures.push(message);};

requireText(html,'id="stormCommandCenter"','Storm Command Center is missing.');
requireText(html,'id="stormFieldWorkspace"','Field check-in workspace is missing.');
requireText(html,'LineCrewSaveStormWorkspace(enabled,eventName)','Legacy Storm save is not connected to the additive workspace.');
requireText(html,'storm-mode-v2.js?v=20260909a','Storm workspace script is not loaded.');
requireText(sw,"'/storm-mode-v2.js?v=20260909a'",'Storm workspace is missing from the offline shell.');
requireText(sw,"'/storm-mode-v2.css?v=20260909a'",'Storm workspace styles are missing from the offline shell.');
requireText(js,"['42883','PGRST202','PGRST204']",'Graceful pre-migration fallback is missing.');
requireText(js,"p_time_policy:value('stormEventTimePolicy')||'record_only'",'Safe record-only time default is missing.');
requireText(css,'.storm-workspace','Storm workspace styles are missing.');

for(const table of ['storm_events','storm_event_crew_status','storm_event_activity']){
  requireText(migration,`alter table public.${table} enable row level security`,`${table} does not enable RLS.`);
  requireText(migration,`revoke all on table public.${table} from public, anon, authenticated`,`${table} direct browser access is not revoked.`);
}
requireText(migration,"create unique index if not exists storm_events_one_active_per_company_idx",'One-active-event invariant is missing.');
requireText(migration,"v_role not in ('owner','admin','superintendent')",'Storm event manager role check is missing.');
requireText(migration,"p_user_id <> auth.uid()",'Self-only field check-in boundary is missing.');
requireText(migration,"storm_event_id=case when",'Daily Reports are not linked to exact storm events.');
requireText(migration,'apply_timekeeping_storm_event_context','Timekeeping event inheritance is missing.');
requireText(migration,"time_policy text not null default 'record_only'",'Storm time policy must remain non-mutating by default.');

if(/update\s+public\.daily_reports[\s\S]{0,300}(regular_hours|overtime_hours)\s*=/i.test(migration)){
  failures.push('Migration appears to rewrite Daily Report hours.');
}
if(/update\s+public\.timekeeping_entries[\s\S]{0,300}(regular_hours|overtime_hours|per_diem)\s*=/i.test(migration)){
  failures.push('Migration appears to rewrite normal timekeeping or per diem values.');
}
if(failures.length){console.error(failures.map(item=>`- ${item}`).join('\n'));process.exit(1);}
console.log('Storm Mode v2 safety validation passed.');
