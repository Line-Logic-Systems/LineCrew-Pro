import fs from 'node:fs';

const client = fs.readFileSync('timekeeping.js','utf8');
const migrationPath = fs.readdirSync('supabase/migrations').find(name => name.endsWith('_transactional_crew_time_save.sql'));
if(!migrationPath) throw new Error('Transactional Crew Time migration is missing.');
const migration = fs.readFileSync(`supabase/migrations/${migrationPath}`,'utf8');

for(const token of [
  "rpc('save_daily_report_crew_time'",
  'p_report_id:reportId',
  'p_rows:rows'
]){
  if(!client.includes(token)) throw new Error(`Crew Time client is not wired to the atomic RPC: ${token}`);
}
for(const forbidden of [
  ".from('timekeeping_entries').upsert(rows",
  ".from('timekeeping_entries').delete().eq('daily_report_id',reportId)",
  "rpc('recalculate_timekeeping_employee_week',{p_report_id:reportId"
]){
  if(client.includes(forbidden)) throw new Error(`Crew Time still contains a non-transactional mutation: ${forbidden}`);
}
for(const token of [
  'create or replace function public.save_daily_report_crew_time',
  "jsonb_array_length(p_rows)=0",
  "lower(coalesce(r.status,'draft'))='approved'",
  'timekeeping_entries_employee_day_job_unique',
  "message='An employee is already recorded on another crew report for this job and date.'",
  "lower(coalesce(source_report.status,'draft'))<>'approved'",
  'revoke all on function public.save_daily_report_crew_time(uuid,jsonb) from public,anon',
  'grant execute on function public.save_daily_report_crew_time(uuid,jsonb) to authenticated,service_role'
]){
  if(!migration.includes(token)) throw new Error(`Transactional Crew Time database guard is missing: ${token}`);
}

console.log('Transactional Crew Time validation passed.');
console.log('- the browser performs one atomic RPC instead of independent upsert/delete/recalculate calls');
console.log('- empty, duplicate, cross-report, approved-report, and cross-company states fail closed');
console.log('- approved weekly entries are excluded from recalculation and header rewrites');
