import fs from 'node:fs';

const path='supabase/migrations/20260912010823_protect_approved_report_timekeeping.sql';
if(!fs.existsSync(path)) throw new Error('Missing approved-timekeeping integrity migration.');
const sql=fs.readFileSync(path,'utf8');
const need=(token,msg)=>{if(!sql.includes(token))throw new Error(msg);};

need('guard_approved_daily_report_timekeeping','Approved timekeeping row guard is missing.');
need("v_status <> 'approved'",'Approved-report status boundary is missing.');
need("tg_op in ('INSERT','DELETE')",'Approved-report insert/delete protection is missing.');
for(const field of ['regular_hours','overtime_hours','start_time','stop_time','per_diem','equipment_used','storm_work']) need(`new.${field} is distinct from old.${field}`,`Approved timekeeping field protection is missing for ${field}.`);
need('guard_approved_daily_report_hours','Approved Daily Report hour guard is missing.');
need("lower(coalesce(old.status,'draft'))='approved'",'Approved report old-status protection is missing.');
need("lower(coalesce(new.status,'draft'))='approved'",'Return/reopen escape hatch must be preserved.');
need("v_role not in (''foreman'',''gf'',''admin'',''manager'',''owner'',''superintendent'')",'Manager timekeeping parity is missing.');
if(sql.includes('40 - v_running')||sql.includes('v_week_start :=')||sql.includes('v_regular := least')) throw new Error('This migration must not rewrite the 40-hour OT algorithm.');

console.log('Approved Daily Report timekeeping integrity guard passed.');
