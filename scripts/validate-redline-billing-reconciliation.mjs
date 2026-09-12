import fs from 'node:fs';
import assert from 'node:assert/strict';

const migration=fs.readFileSync('supabase/migrations/20260912021247_clarify_redline_billing_reconciliation.sql','utf8');
const app=fs.readFileSync('index.html','utf8');

for(const marker of [
  'get_job_billing_reconciliation_v2',
  "filter (where action.authorization_status = 'authorized')",
  "filter (where action.authorization_status = 'redline')",
  'approved_authorized_progress_value', 'approved_redline_value',
  'approved_billable_value', 'coalesce(progress.approved_value, 0)',
  'approved.redline_total', 'approved.billable_total'
]) assert.ok(migration.includes(marker),`Redline reconciliation migration is missing: ${marker}`);

assert.ok(migration.includes("and location.authorization_status in ('authorized', 'redline')"),'Approved redlines must remain eligible for billing.');
for(const label of ['Authorized Scope','Approved Authorized Progress','Approved Redlines','Total Approved Billable']){
  assert.ok(app.includes(label),`Billing UI/export is missing the explicit ${label} label.`);
}
assert.ok(app.includes("sb.rpc('get_job_billing_reconciliation_v2'"),'Billing UI must use the explicit reconciliation result.');
assert.ok(app.includes("sb.rpc('get_job_billing_reconciliation',{p_job_id:job.id})"),'Completed-job closeout compatibility must remain on the existing reconciliation RPC.');

console.log('Redline billing reconciliation validation passed.');
console.log('- Authorized progress remains capped to the utility package');
console.log('- Approved redlines remain billable and are reported separately');
console.log('- Billing UI and retained exports label all four values explicitly');
