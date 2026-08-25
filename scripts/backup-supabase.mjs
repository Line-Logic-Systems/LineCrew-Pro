#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';

const url = process.env.SUPABASE_URL?.replace(/\/$/, '');
const secretKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
const outRoot = process.env.BACKUP_DIR || 'backup-output';
const excludedBuckets = new Set((process.env.BACKUP_EXCLUDE_BUCKETS || '').split(',').map((v) => v.trim()).filter(Boolean));
if (!url || !secretKey) throw new Error('SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required');

const headers = { apikey: secretKey, Authorization: `Bearer ${secretKey}` };
const stamp = new Date().toISOString().replace(/[:.]/g, '-');
const out = path.join(outRoot, stamp);
await fs.mkdir(out, { recursive: true });
const sha256 = (data) => crypto.createHash('sha256').update(data).digest('hex');

async function responseBody(response) {
  const text = await response.text();
  if (!text) return null;
  try { return JSON.parse(text); } catch { return text; }
}
async function jsonRequest(base, pathname, options = {}) {
  const response = await fetch(`${base}${pathname}`, {
    ...options, headers: { ...headers, ...(options.headers || {}) },
  });
  const body = await responseBody(response);
  if (!response.ok) throw new Error(`${response.status} ${response.statusText}: ${JSON.stringify(body)}`);
  return body;
}

const inventoryRows = await jsonRequest(url, '/rest/v1/rpc/backup_public_table_inventory', {
  method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}',
});
if (!Array.isArray(inventoryRows) || !inventoryRows.length) {
  throw new Error('The server returned no public-table backup inventory');
}
export const REQUIRED_PUBLIC_TABLES = [...new Set(inventoryRows.map((row) => row.table_name))]
  .filter((name) => typeof name === 'string' && /^[a-z0-9_]+$/.test(name))
  .sort();
if (REQUIRED_PUBLIC_TABLES.length !== inventoryRows.length) {
  throw new Error('The public-table backup inventory contained an invalid or duplicate table name');
}

const manifest = {
  format_version: 2,
  created_at: new Date().toISOString(),
  source_project: new URL(url).hostname.split('.')[0],
  required_public_tables: REQUIRED_PUBLIC_TABLES,
  excluded_storage_buckets: [...excludedBuckets].sort(),
  tables: {}, storage: {}, errors: [],
};

for (const table of REQUIRED_PUBLIC_TABLES) {
  try {
    const rows = [];
    for (let offset = 0; ; offset += 1000) {
      const page = await jsonRequest(url, `/rest/v1/${encodeURIComponent(table)}?select=*&offset=${offset}&limit=1000`);
      if (!Array.isArray(page)) throw new Error('REST response was not an array');
      rows.push(...page);
      if (page.length < 1000) break;
    }
    const data = Buffer.from(`${JSON.stringify(rows, null, 2)}\n`);
    const file = `${table}.json`;
    await fs.writeFile(path.join(out, file), data);
    manifest.tables[table] = { file, rows: rows.length, bytes: data.length, sha256: sha256(data) };
  } catch (error) {
    manifest.tables[table] = { error: error.message };
    manifest.errors.push({ scope: 'table', name: table, message: error.message });
  }
}

const storageBase = `${url}/storage/v1`;
async function storageBytes(pathname) {
  const response = await fetch(`${storageBase}${pathname}`, { headers });
  if (!response.ok) throw new Error(`${response.status} ${response.statusText}: ${await response.text()}`);
  return Buffer.from(await response.arrayBuffer());
}

try {
  const buckets = await jsonRequest(storageBase, '/bucket');
  for (const bucket of buckets || []) {
    const bucketName = bucket.name || bucket.id;
    if (excludedBuckets.has(bucketName)) {
      manifest.storage[bucketName] = { excluded: true };
      continue;
    }
    const queue = [''];
    const objects = [];
    try {
      while (queue.length) {
        const prefix = queue.shift();
        for (let offset = 0; ; ) {
          const list = await jsonRequest(storageBase, `/object/list/${encodeURIComponent(bucketName)}`, {
            method: 'POST', headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ prefix, limit: 1000, offset, sortBy: { column: 'name', order: 'asc' } }),
          });
          if (!list?.length) break;
          for (const item of list) {
            const objectPath = prefix ? `${prefix}/${item.name}` : item.name;
            const segments = objectPath.split('/');
            if (segments.some((segment) => !segment || segment === '.' || segment === '..')) throw new Error(`Unsafe object path: ${objectPath}`);
            if (!item.id) { queue.push(objectPath); continue; }
            const encodedPath = segments.map(encodeURIComponent).join('/');
            const data = await storageBytes(`/object/authenticated/${encodeURIComponent(bucketName)}/${encodedPath}`);
            const file = path.posix.join('storage', bucketName, ...segments);
            const destination = path.join(out, ...file.split('/'));
            await fs.mkdir(path.dirname(destination), { recursive: true });
            await fs.writeFile(destination, data);
            objects.push({ path: objectPath, file, bytes: data.length, sha256: sha256(data) });
          }
          if (list.length < 1000) break;
          offset += list.length;
        }
      }
      manifest.storage[bucketName] = {
        objects: objects.length,
        bytes: objects.reduce((sum, object) => sum + object.bytes, 0),
        files: objects,
      };
    } catch (error) {
      manifest.storage[bucketName] = { error: error.message, objects: objects.length, files: objects };
      manifest.errors.push({ scope: 'storage', name: bucketName, message: error.message });
    }
  }
} catch (error) {
  manifest.errors.push({ scope: 'storage', name: 'bucket-list', message: error.message });
}

const manifestPath = path.join(out, 'manifest.json');
await fs.writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
if (manifest.errors.length) throw new Error(`Backup incomplete: ${manifest.errors.length} error(s). See ${manifestPath}`);
console.log(`Backup complete and internally hashed: ${out}`);
