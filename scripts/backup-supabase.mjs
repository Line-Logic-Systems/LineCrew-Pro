import fs from 'node:fs/promises';
import path from 'node:path';
import { createClient } from '@supabase/supabase-js';

const url = process.env.SUPABASE_URL;
const secretKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
const outRoot = process.env.BACKUP_DIR || 'backup-output';
if (!url || !secretKey) throw new Error('SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required');

const sb = createClient(url, secretKey, {
  auth: { persistSession:false, autoRefreshToken:false, detectSessionInUrl:false },
});
const stamp = new Date().toISOString().replace(/[:.]/g,'-');
const out = path.join(outRoot, stamp);
await fs.mkdir(out, { recursive:true });

const tables = [
  'companies','profiles','customers','contracts','price_books','price_book_items','jobs','work_points',
  'job_authorized_units','crews','daily_reports','daily_report_units','daily_report_jsas','jsa_signatures',
  'jsa_upload_attachments','storm_events','storm_crews'
];

const manifest = { created_at:new Date().toISOString(), source:url, tables:{}, storage:{} };
let tableErrors = 0;
for (const table of tables) {
  const rows = [];
  const pageSize = 1000;
  for (let from=0;;from+=pageSize) {
    const { data, error } = await sb.from(table).select('*').range(from, from+pageSize-1);
    if (error) {
      manifest.tables[table] = { error:error.message };
      tableErrors++;
      break;
    }
    rows.push(...(data||[]));
    if (!data || data.length < pageSize) break;
  }
  if (!manifest.tables[table]?.error) {
    await fs.writeFile(path.join(out, `${table}.json`), JSON.stringify(rows,null,2));
    manifest.tables[table] = { rows:rows.length };
  }
}
if (tableErrors === tables.length) {
  throw new Error('All database table exports failed. Check the Supabase URL/key pairing.');
}

const storageBase = `${url.replace(/\/$/,'')}/storage/v1`;
const storageHeaders = { apikey: secretKey };
async function storageJson(pathname, options={}) {
  const res = await fetch(`${storageBase}${pathname}`, {
    ...options,
    headers: { ...storageHeaders, ...(options.headers||{}) },
  });
  if (!res.ok) throw new Error(`Storage ${res.status} ${res.statusText}: ${await res.text()}`);
  return res.json();
}
async function storageBytes(pathname) {
  const res = await fetch(`${storageBase}${pathname}`, { headers: storageHeaders });
  if (!res.ok) throw new Error(`Storage ${res.status} ${res.statusText}: ${await res.text()}`);
  return Buffer.from(await res.arrayBuffer());
}

const buckets = await storageJson('/bucket');
for (const bucket of buckets || []) {
  const bucketName = bucket.name || bucket.id;
  const bucketDir = path.join(out,'storage',bucketName);
  await fs.mkdir(bucketDir,{recursive:true});
  const queue = [''];
  let count = 0;
  while(queue.length){
    const prefix = queue.shift();
    let offset = 0;
    while(true){
      const list = await storageJson(`/object/list/${encodeURIComponent(bucketName)}`, {
        method:'POST',
        headers:{'content-type':'application/json'},
        body:JSON.stringify({ prefix, limit:1000, offset, sortBy:{column:'name',order:'asc'} }),
      });
      if(!list?.length) break;
      for(const item of list){
        const objectPath = prefix ? `${prefix}/${item.name}` : item.name;
        if(item.id){
          const encodedPath = objectPath.split('/').map(encodeURIComponent).join('/');
          const data = await storageBytes(`/object/authenticated/${encodeURIComponent(bucketName)}/${encodedPath}`);
          const dest = path.join(bucketDir,...objectPath.split('/'));
          await fs.mkdir(path.dirname(dest),{recursive:true});
          await fs.writeFile(dest,data);
          count++;
        } else {
          queue.push(objectPath);
        }
      }
      if(list.length < 1000) break;
      offset += list.length;
    }
  }
  manifest.storage[bucketName] = { objects:count };
}
await fs.writeFile(path.join(out,'manifest.json'),JSON.stringify(manifest,null,2));
console.log(`Backup complete: ${out}`);
