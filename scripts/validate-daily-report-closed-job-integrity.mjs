import fs from 'node:fs';

const migrationPath='supabase/migrations/20260912005003_protect_closed_jobs_and_approval_metadata.sql';
if(!fs.existsSync(migrationPath)) throw new Error('Missing closed-job Daily Report integrity migration.');
const sql=fs.readFileSync(migrationPath,'utf8');

function need(token,message){ if(!sql.includes(token)) throw new Error(message); }

need("and job.active is true", 'Daily Report submit/approval must require an active job.');
need("Closed jobs are read-only. Reopen the job before approving this report.", 'Closed-job approval rejection is missing.');
need("approved_by=auth.uid()", 'Approval actor metadata is missing.');
need("approved_at=now()", 'Approval timestamp metadata is missing.');
need("reviewed_by=auth.uid()", 'Reviewer metadata is missing.');
need("reviewed_at=now()", 'Review timestamp metadata is missing.');
need("updated_at=now()", 'Approval update timestamp is missing.');
need("v_role not in ('admin','manager','gf','owner','superintendent')", 'Manager must remain in Daily Report approval leadership.');
need("lower(coalesce(public.my_role(),'')) in ('owner','manager','admin','gf')", 'Leadership direct-update policy role boundary is missing.');
need("drop policy if exists daily_reports_leadership_update", 'Closed-job direct-update policy replacement is missing.');
need("for update of report", 'Submit/approve path must lock the report row before state transition.');
need("Job closed or report changed before submission completed", 'Submit race-condition guard is missing.');
need("Job closed or report changed before approval completed.", 'Approval race-condition guard is missing.');

console.log('Daily Report closed-job and approval metadata guard passed.');
