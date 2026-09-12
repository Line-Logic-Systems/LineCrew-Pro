import fs from 'node:fs';

const path='supabase/migrations/20260912010457_repair_manager_operational_parity.sql';
if(!fs.existsSync(path)) throw new Error('Missing Manager operational parity migration.');
const sql=fs.readFileSync(path,'utf8');

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
  if(!sql.includes(signature)) throw new Error(`Manager parity migration does not explicitly patch ${signature}.`);
}
if(!sql.includes("v_override_required and v_role not in (''owner'', ''manager'')")) throw new Error('Manager closeout override parity is missing.');
if(!sql.includes('Expected role allow-list was not found')) throw new Error('Manager migration must fail closed if an expected function body changes.');
if(/regexp_replace/i.test(sql)) throw new Error('Manager parity must not use a broad regexp rewrite.');

console.log('Manager operational parity guard passed.');
