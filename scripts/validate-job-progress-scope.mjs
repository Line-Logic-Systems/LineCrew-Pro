import fs from 'node:fs';
import assert from 'node:assert/strict';

const migrationPath=fs.readdirSync('supabase/migrations').find(name=>name.endsWith('_scope_and_optimize_job_progress.sql'));
assert.ok(migrationPath,'Scoped job-progress migration is missing.');
const migration=fs.readFileSync(`supabase/migrations/${migrationPath}`,'utf8');
const app=fs.readFileSync('index.html','utf8');

for(const marker of [
  'get_job_progress_dashboard_v2(p_job_id uuid default null)',
  'p_job_id is null or job.id=p_job_id',
  'location.normalized_pole_location_key',
  'public.get_job_progress_dashboard_v2(p_job_id) dashboard',
  'revoke all on function public.get_job_progress_dashboard_v2(uuid) from public,anon',
  'grant execute on function public.get_job_progress_dashboard_v2(uuid) to authenticated,service_role'
]) assert.ok(migration.includes(marker),`Scoped job progress is missing: ${marker}`);

assert.ok(!migration.includes('left join lateral'),'Scoped progress must not restore a per-work-point lateral scan.');
assert.ok(!app.includes("sb.rpc('get_job_progress_dashboard')"),'The UI must not call the legacy full-company dashboard.');
assert.ok(app.includes("sb.rpc('get_job_progress_dashboard_v2')"),'Job list pages must use the set-based v2 dashboard.');

console.log('Scoped job progress validation passed.');
console.log('- billing and closeout push one job ID into every aggregate');
console.log('- list pages use the same set-based implementation without lateral fanout');
