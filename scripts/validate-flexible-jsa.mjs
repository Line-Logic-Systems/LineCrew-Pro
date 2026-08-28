import fs from 'node:fs';

const html = fs.readFileSync('index.html','utf8');
const offlineJsa = fs.readFileSync('offline-jsa.js','utf8');
const serviceWorker = fs.readFileSync('service-worker.js','utf8');
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

const coldStartHtml = [
  'linecrew-offline-jsa-access-v1',
  'OFFLINE_JSA_ACCESS_MAX_AGE_MS',
  'enterOfflineJsaMode',
  'primeOfflineJsaJobs',
  'Offline JSA Mode',
  "!['foreman','gf'].includes(role)",
  'clearOfflineJsaAccess();',
  'fillOfflineJsaJobSelect',
  'uniqueOfflineJsaJobs'
];
for(const token of coldStartHtml){
  if(!html.includes(token)) throw new Error('Missing cold-start Offline JSA guard: ' + token);
}

// Keep the iPhone cold-start fallback and cached/online job-list merge regression-proof.
if(!html.includes('if(!session){\nif(enterOfflineJsaMode()) return;')){
  throw new Error('A missing online session must fall back to cached Offline JSA access.');
}
const signedOutStart = html.indexOf("if(event === 'SIGNED_OUT'){");
const signedOutEnd = html.indexOf("if(\nevent === 'SIGNED_IN'", signedOutStart);
const signedOutBlock = html.slice(signedOutStart, signedOutEnd);
if(!signedOutBlock.includes('if(readOfflineJsaAccess())') || signedOutBlock.includes('clearOfflineJsaAccess();')){
  throw new Error('Transient SIGNED_OUT events must preserve valid Offline JSA access.');
}
if((html.match(/return fillOfflineJsaJobSelect\(select,data \|\| \[\]\);/g) || []).length < 2){
  throw new Error('Both digital and uploaded JSA job lists must rebuild from the deduplicated list.');
}

for(const token of [
  'linecrew-pro-shell-v44',
  '@supabase/supabase-js@2.112.3',
  'isSupabaseRuntime',
  '/offline-jsa.js?v=20260827b',
  '/jsa-signatures.js?v=20260828a'
]){
  if(!serviceWorker.includes(token)) throw new Error('Missing Offline JSA app-shell token: ' + token);
}

for(const token of [
  'markColdStartReady',
  'Offline JSA form and device storage are ready.',
  'window.LineCrewOfflineColdStart',
  "toast(message, 'warning')",
  "console.info('[offline-jsa] Digital JSA save requested.'"
]){
  if(!offlineJsa.includes(token)) throw new Error('Missing Offline JSA readiness token: ' + token);
}

const signatures = fs.readFileSync('jsa-signatures.js','utf8');
if(!signatures.includes("!e.target?.closest?.('.lc-signature-wrap')")){
  throw new Error('Signature click suppression must be limited to the signature pad.');
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
