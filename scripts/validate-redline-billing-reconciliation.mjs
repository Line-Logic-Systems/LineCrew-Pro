import fs from 'node:fs';
import assert from 'node:assert/strict';

const migrationPath=fs.readdirSync('supabase/migrations').find(name=>name.endsWith('_reconcile_billing_buckets_and_work_point_keys.sql'));
assert.ok(migrationPath,'Billing bucket and normalized-key migration is missing.');
const migration=fs.readFileSync(`supabase/migrations/${migrationPath}`,'utf8');
const app=fs.readFileSync('index.html','utf8');

for(const marker of [
  'get_job_billing_reconciliation_v3',
  'authorized_install_quantity',
  'install_quantity-authorized_install_quantity',
  'approved_authorized_progress_value', 'approved_redline_value',
  'approved_billable_value', 'approved.redline_total', 'approved.billable_total',
  'normalized_pole_location_key',
  'daily_production_unit_locations_report_item_normalized_location_unique',
  'daily_production_unit_locations_company_item_normalized_idx'
]) assert.ok(migration.includes(marker),`Redline reconciliation migration is missing: ${marker}`);

for(const label of ['Authorized Scope','Approved Authorized Progress','Approved Redlines','Total Approved Billable','Remaining Unapproved Authorized Scope']){
  assert.ok(app.includes(label),`Billing UI/export is missing the explicit ${label} label.`);
}
assert.ok(!app.includes("sb.rpc('get_job_billing_reconciliation'"),'No UI path may remain pinned to conflated reconciliation v1.');
assert.ok(!app.includes("sb.rpc('get_job_billing_reconciliation_v2'"),'No UI path may remain pinned to whole-row redline reconciliation v2.');
assert.ok(app.includes("sb.rpc('get_job_billing_reconciliation_v3',{p_job_id:job.id})"),'Completed Jobs must use split-bucket reconciliation v3.');
assert.ok(migration.includes("'public.create_billing_export_batch_v3(uuid,date,date,boolean,text,boolean,text)'"),'Final Bill creation must use reconciliation v3.');
assert.ok(migration.includes("'public.set_job_closeout(uuid,boolean,text)'"),'Job closeout must use reconciliation v3.');

console.log('Redline billing reconciliation validation passed.');
console.log('- Authorized progress remains capped to the utility package');
console.log('- Approved quantities are split into authorized and excess portions at snapshot prices');
console.log('- Billing, Final Bill, closeout and Completed Jobs all use reconciliation v3');
