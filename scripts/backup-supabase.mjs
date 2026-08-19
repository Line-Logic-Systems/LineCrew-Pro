import fs from 'node:fs/promises';
import path from 'node:path';
import { createClient } from '@supabase/supabase-js';

const url = process.env.SUPABASE_URL;
const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
const outRoot = process.env.BACKUP_DIR || 'backup-output';
if (!url || !serviceKey) throw new Error('SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required');

const sb = createClient(url, serviceKey, { auth: { persistSession:false, autoRefreshToken:false } });
const stamp = new Date().toISOString().replace(/[:.]/g,'-');
const out = path.join(outRoot, stamp);
await fs.mkdir(out, { recursive:true });

const tables = [
  'companies','profiles','customers','contracts','price_books','price_book_items','jobs','work_points',
  'job_authorized_units','crews','daily_reports','daily_report_units','daily_report_jsas','jsa_signatures',
  'jsa_upload_attachments','storm_events','storm_crews'
];

const manifest = { created_at:new Date().toISOString(), source:url, tables:{}, storage:{} };
for (const table of tables) {
  const rows = [];
  const pageSize = 1000;
  for (let from=0;;from+=pageSize) {
    const { data, error } = await sb.from(table).select('*').range(from, from+pageSize-1);
    if (error) {
      manifest.tables[table] = { error:error.message };
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

const { data:buckets, error:bucketError } = await sb.storage.listBuckets();
if (bucketError) throw bucketError;
for (const bucket of buckets || []) {
  const bucketDir = path.join(out,'storage',bucket.name);
  await fs.mkdir(bucketDir,{recursive:true});
  const queue = [''];
  let count = 0;
  while(queue.length){
    const prefix = queue.shift();
    let offset = 0;
    while(true){
      const { data:list, error } = await sb.storage.from(bucket.name).list(prefix,{limit:1000,offset,sortBy:{column:'name',order:'asc'}});
      if(error) throw error;
      if(!list?.length) break;
      for(const item of list){
        const objectPath = prefix ? `${prefix}/${item.name}` : item.name;
        if(item.id){
          const { data:blob, error:downloadError } = await sb.storage.from(bucket.name).download(objectPath);
          if(downloadError) throw downloadError;
          const dest = path.join(bucketDir,...objectPath.split('/'));
          await fs.mkdir(path.dirname(dest),{recursive:true});
          await fs.writeFile(dest,Buffer.from(await blob.arrayBuffer()));
          count++;
        } else {
          queue.push(objectPath);
        }
      }
      if(list.length < 1000) break;
      offset += list.length;
    }
  }
  manifest.storage[bucket.name] = { objects:count };
}
await fs.writeFile(path.join(out,'manifest.json'),JSON.stringify(manifest,null,2));
console.log(`Backup complete: ${out}`);
