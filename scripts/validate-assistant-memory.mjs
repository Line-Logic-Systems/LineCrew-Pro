import fs from 'node:fs';
import assert from 'node:assert/strict';

const migrationPath = 'supabase/migrations/archive/20260830174354_assistant_memory_reminders.sql';
const migration = fs.readFileSync(migrationPath,'utf8');
const indexMigration = fs.readFileSync('supabase/migrations/archive/20260830175934_index_assistant_memory_foreign_keys.sql','utf8');
const edge = fs.readFileSync('supabase/functions/linecrew-assistant/index.ts','utf8');
const app = fs.readFileSync('index.html','utf8');

for(const marker of [
  'create table public.assistant_memories',
  "memory_type in ('company_workflow', 'job_reminder')",
  'alter table public.assistant_memories enable row level security',
  'revoke all on table public.assistant_memories from public, anon, authenticated',
  'grant select on table public.assistant_memories to authenticated',
  "v_role not in ('owner', 'admin')",
  'create_assistant_memory',
  'complete_assistant_memory',
  'remove_assistant_memory',
  "set search_path = ''",
  'memory.company_id = v_company'
]) assert(migration.includes(marker),`Assistant Memory migration is missing: ${marker}`);

assert(!/grant\s+(?:insert|update|delete|all)[^;]*assistant_memories[^;]*authenticated/i.test(migration),
  'Authenticated clients must not receive direct Assistant Memory mutation grants.');
assert((migration.match(/revoke all on function public\./g) || []).length >= 3,
  'Every Assistant Memory mutation RPC must revoke default execution.');
assert((migration.match(/grant execute on function public\./g) || []).length >= 3,
  'Every Assistant Memory mutation RPC needs an explicit authenticated grant.');
for(const column of ['created_by','completed_by','removed_by']){
  assert(indexMigration.includes(`(${column})`),`Assistant Memory audit foreign key needs an index: ${column}`);
}

for(const marker of [
  '.from("assistant_memories")',
  'pending_memory_proposal: memoryProposal',
  'memory_proposal: memoryProposal',
  'route: "memory-management"',
  'There is no Edit button, date/time scheduling, attachment field or visible audit-detail screen',
  'must choose Save in the app',
  'advisory data'
]) assert(edge.includes(marker),`Assistant Edge memory boundary is missing: ${marker}`);
for(const mutation of ['.insert(','.update(','.upsert(','.delete(','.rpc(']){
  assert(!edge.includes(mutation),`Assistant Edge must remain non-mutating: ${mutation}`);
}

for(const marker of [
  'Not saved yet — review this memory',
  "sb.rpc('create_assistant_memory'",
  "sb.rpc(rpc,{p_memory_id:memoryId})",
  'Save Reminder',
  'Save Workflow Memory',
  'Mark Complete',
  'confirmAssistantFinalBillingReminders(jobId)',
  'This reminder is advisory and makes no billing changes',
  'Saved Memories'
]) assert(app.includes(marker),`Assistant Memory UI is missing: ${marker}`);
for(const marker of [
  'id="assistantMemoryTile"',
  "$('assistantMemoryTile').classList.toggle('hidden', !userCanUseAssistant())",
  "$('assistantMemoryTile').onclick",
  "$('assistantMemorySection').open = true"
]) assert(app.includes(marker),`Dashboard Assistant Memory access is missing: ${marker}`);

const createRpcIndex = app.indexOf("sb.rpc('create_assistant_memory'");
const saveHandlerIndex = app.lastIndexOf('save.onclick',createRpcIndex);
assert(saveHandlerIndex >= 0 && saveHandlerIndex < createRpcIndex,
  'Assistant Memory creation must occur only inside the explicit Save handler.');

console.log('Assistant Memory validation passed.');
console.log('- Owner/Admin-only RPCs validate company and job scope');
console.log('- Edge Function proposes and reads memories but never mutates records');
console.log('- Browser requires explicit Save and shows advisory Final Bill reminders');
