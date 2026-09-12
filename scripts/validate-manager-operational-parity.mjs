import fs from 'node:fs';

const originalPath='supabase/migrations/20260912010457_repair_manager_operational_parity.sql';
const completionPath=fs.readdirSync('supabase/migrations').find(name=>name.endsWith('_complete_manager_operational_parity.sql'));
if(!fs.existsSync(originalPath)||!completionPath) throw new Error('Missing Manager operational parity migrations.');
const originalSql=fs.readFileSync(originalPath,'utf8');
const sql=fs.readFileSync(`supabase/migrations/${completionPath}`,'utf8');

for(const signature of [
  'public.create_billing_export_batch(uuid,date,date,boolean,text)',
  'public.get_job_billing_reconciliation(uuid)',
  'public.set_job_closeout(uuid,boolean,text)',
  'public.get_job_progress_dashboard()',
  'public.get_completed_job_export_details_v1(uuid)',
  'public.set_job_leader_assignment(uuid,uuid,boolean)',
  'public.get_price_book_items_for_user(uuid)',
  'public.can_review_daily_reports()',
  'public.linecrew_can_manage_job_packages()',
  'public.linecrew_can_manage_jobs()'
]) {
  if(!originalSql.includes(signature)) throw new Error(`Initial Manager parity migration does not explicitly patch ${signature}.`);
}
for(const signature of [
  'public.get_job_packages_v2(uuid)',
  'public.get_company_jsas()',
  'public.get_job_closeout_history(uuid)',
  'public.get_billing_export_batches_v3()',
  'public.update_company_settings(text,text,text,text,text,text)',
  'public.set_company_storm_mode(boolean,text)',
  'public.save_daily_report_unit_location_v2(uuid,uuid,text,numeric,numeric,numeric)',
  'public.get_job_package_work_points(uuid)',
  'public.get_daily_report_unit_locations_v2(uuid)'
]){
  if(!sql.includes(signature)) throw new Error(`Completed Manager parity migration does not explicitly patch ${signature}.`);
}
for(const forbidden of [
  'public.linecrew_transfer_company_owner(uuid)',
  'public.linecrew_admin_replace_company_owner(uuid,uuid,text)',
  'public.linecrew_claim_initial_owner()',
  'public.platform_owner_prepare_beta_company(uuid,text,timestamp with time zone,timestamp with time zone)'
]){
  if(sql.includes(`('${forbidden}')`)) throw new Error(`Manager parity must not patch protected function ${forbidden}.`);
}
if(!sql.includes("v_override_required and v_role <> ''owner''")) throw new Error('Unresolved closeout overrides must remain Owner-only.');
if(!sql.includes('No operational Admin role list was patched')) throw new Error('Manager migration must fail closed if an expected function body changes.');
if(/regexp_replace/i.test(sql)) throw new Error('Manager parity must not use a broad regexp rewrite.');

console.log('Manager operational parity guard passed.');
console.log('- operational RPCs include Manager while ownership and platform controls remain excluded');
console.log('- unresolved closeout overrides remain Owner-only');
