import fs from 'node:fs';

const path='supabase/migrations/20260912011326_enforce_privileged_mfa_on_sensitive_mutations.sql';
if(!fs.existsSync(path)) throw new Error('Missing privileged MFA migration.');
const sql=fs.readFileSync(path,'utf8');
const need=(token,msg)=>{if(!sql.includes(token))throw new Error(msg);};

need('linecrew_require_privileged_mfa_for_mutation','Privileged MFA mutation trigger function is missing.');
need('linecrew_privileged_mfa_satisfied()','Existing role-aware MFA predicate must be used.');
for(const table of ['profiles','companies','customers','contracts','price_books','price_book_items','contract_field_settings','billing_export_batches','billing_export_lines']){
  need(`'${table}'`,`Sensitive table MFA coverage is missing for ${table}.`);
}
need("actor_role not in (''owner'',''manager'',''admin'',''superintendent'')",'Manager team-access parity is missing.');
need("v_role not in (''owner'',''manager'',''admin'',''superintendent'')",'Manager billing-status parity is missing.');
if(sql.includes('timekeeping_entries')||sql.includes('daily_production_unit_locations')||sql.includes('daily_report_jsas')) throw new Error('Field-work tables must not be pulled into privileged MFA enforcement.');

console.log('Privileged MFA enforcement guard passed.');
