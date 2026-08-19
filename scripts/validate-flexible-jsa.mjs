import fs from 'node:fs';

const html = fs.readFileSync('index.html','utf8');
const migration = fs.readFileSync('supabase/migrations/202608190700_flexible_jsa_upload.sql','utf8');
const compat = fs.readFileSync('supabase/migrations/202608190710_flexible_jsa_digital_compat.sql','utf8');

const requiredHtml = [
  'companyJsaMethod',
  'uploadCompanyJsaBtn',
  'companyJsaUploadFiles',
  'create_uploaded_company_jsa',
  'register_jsa_upload_attachment',
  "from('jsa-uploads')",
  'A JSA is not required to submit production'
];
for(const token of requiredHtml){
  if(!html.includes(token)) throw new Error('Missing flexible JSA UI token: ' + token);
}

const requiredSql = [
  "jsa_method text not null default 'both'",
  "jsa_source text not null default 'digital'",
  "'jsa-uploads'",
  "linecrew_has_capability('safety_records')",
  'create_uploaded_company_jsa',
  'get_uploaded_company_jsas',
  'get_jsa_upload_attachments',
  'delete_uploaded_company_jsa',
  'revoke all on function public.set_company_jsa_method(text) from public, anon'
];
for(const token of requiredSql){
  if(!migration.includes(token)) throw new Error('Missing flexible JSA migration token: ' + token);
}

if(!compat.includes("coalesce(safety.jsa_source, 'digital') = 'digital'")){
  throw new Error('Legacy digital JSA list must exclude uploaded company JSAs.');
}
if(!compat.includes("'superintendent', 'admin', 'owner'")){
  throw new Error('Digital JSA compatibility must include new leadership roles.');
}

// Guard the product decision: adding flexible JSA must never make production submission conditional on JSA.
const submitStart = html.indexOf("async function submitDailyReport");
if(submitStart !== -1){
  const submitBlock = html.slice(submitStart, submitStart + 5000).toLowerCase();
  if(submitBlock.includes('jsa')) throw new Error('Daily Report submission unexpectedly references JSA.');
}

console.log('Flexible JSA validation passed.');
