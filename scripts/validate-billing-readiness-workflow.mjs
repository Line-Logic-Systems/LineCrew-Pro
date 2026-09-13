import fs from 'node:fs';
import assert from 'node:assert/strict';

const app=fs.readFileSync('index.html','utf8');
const sql=fs.readFileSync('supabase/migrations/20260913004015_add_field_complete_billing_readiness.sql','utf8');

for(const marker of [
  'Mark Complete for Billing','Return to Field','requestBillingReadinessDecision',
  "sb.rpc('set_job_billing_readiness'","sb.rpc('get_job_billing_readiness'",
  'userCanAdministerJobPackageStatus()'
]) assert.ok(app.includes(marker),`Missing billing-readiness UI invariant: ${marker}`);

assert.ok(!app.includes('`${action.charAt(0).toUpperCase() + action.slice(1)} utility package `'),
  'Package status must not use native confirm().');
assert.ok(app.includes("if(['owner','manager','admin'].includes(currentUserRole())){\nconst closeButton"),
  'GF must not receive the final Close Job control.');

for(const marker of [
  "status in (''active'',''closed'')",'candidate.revision_number desc',
  'create table public.job_billing_readiness','create table public.job_billing_readiness_events',
  'alter table public.job_billing_readiness enable row level security',
  "v_percent<100 and v_reason is null","v_role not in ('gf','owner','manager','admin')",
  "v_role not in ('owner','manager','admin')",'Only Admin leadership can change a utility package status.'
]) assert.ok(sql.includes(marker),`Missing billing-readiness SQL invariant: ${marker}`);

assert.equal((sql.match(/package\.status in \(''active'',''closed''\)/g)||[]).length,2,
  'Both dashboard package predicates must retain the latest closed baseline.');

console.log('Billing readiness workflow validation passed.');
console.log('- GF submits complete work, with a mandatory audited reason below 100%');
console.log('- Admin can return work without closing the package or job');
console.log('- Latest closed package remains the progress and billing baseline');
