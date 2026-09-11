import fs from 'node:fs';

function read(path){
  if(!fs.existsSync(path)) throw new Error(`Missing required file: ${path}`);
  return fs.readFileSync(path,'utf8');
}
function need(source, token, message){
  if(!source.includes(token)) throw new Error(message);
}

const maps = read('job-map-documents.js');
const migration = read('supabase/migrations/20260910201500_add_job_packet_documents_and_map_access.sql');

for (const [token,message] of [
  ["job-packet-documents", 'Job packet document bucket binding is missing.'],
  ["storage.from(BUCKET).upload", 'Original job packet upload path is missing.'],
  ["register_job_package_document", 'Original job packet registration RPC is missing.'],
  ["get_job_package_documents", 'Job packet document listing RPC wiring is missing.'],
  ["get_job_map_page", 'Work-point to map-page lookup wiring is missing.'],
  ["dailyReportMapButton", 'Daily Report map button wiring is missing.'],
  ["['foreman','gf'].includes(role())", 'Daily Report map access must remain available to Foreman and GF.'],
  ["createSignedUrl(documentRow.storage_path,900)", 'Retained packets must use short-lived signed URLs.']
]) need(maps, token, message);

for (const [token,message] of [
  ["values ('job-packet-documents','job-packet-documents',false,104857600,array['application/pdf'])", 'Job packet bucket must remain private, PDF-only, and capped at 100 MB.'],
  ['create table if not exists public.job_package_documents', 'Job package document metadata table is missing.'],
  ['split_part(p_storage_path,\'/\',1) <> v_company::text', 'Job packet storage path must remain company-scoped.'],
  ['create or replace function public.get_job_map_page', 'Map-page lookup RPC is missing.'],
  ['select min(r.source_page)', 'Map-page lookup must continue using imported source-page metadata.'],
  ["revoke all on function public.register_job_package_document(uuid,text,text,text,bigint,integer,text) from public,anon", 'Job packet registration must remain unavailable to anonymous users.'],
  ["revoke all on function public.get_job_map_page(uuid,text) from public,anon", 'Map lookup must remain unavailable to anonymous users.'],
  ["bucket_id='job-packet-documents' and public.current_user_has_active_profile() and (storage.foldername(name))[1]=(public.my_company_id())::text", 'Job packet read policy must remain company-scoped.']
]) need(migration, token, message);

console.log('Job packet/map retention regression guard passed.');
