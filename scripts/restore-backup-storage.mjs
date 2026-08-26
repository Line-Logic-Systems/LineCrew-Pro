#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';

const backupDir = process.argv[2];
const url = process.env.SUPABASE_URL?.replace(/\/$/, '');
const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!backupDir) throw new Error('Usage: node scripts/restore-backup-storage.mjs <timestamped-backup-directory>');
if (!url || !serviceRoleKey) throw new Error('SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required');

const manifest = JSON.parse(await fs.readFile(path.join(backupDir, 'manifest.json'), 'utf8'));
const headers = { apikey: serviceRoleKey, Authorization: `Bearer ${serviceRoleKey}` };
const sha256 = (data) => crypto.createHash('sha256').update(data).digest('hex');

function safeSegments(value) {
  if (typeof value !== 'string' || !value) throw new Error('Storage path is empty');
  const segments = value.split('/');
  if (segments.some((segment) => !segment || segment === '.' || segment === '..')) {
    throw new Error(`Unsafe storage path: ${value}`);
  }
  return segments;
}

function encodedPath(value) {
  return safeSegments(value).map(encodeURIComponent).join('/');
}

async function responseError(response) {
  const body = await response.text();
  return `${response.status} ${response.statusText}${body ? `: ${body}` : ''}`;
}

let restoredObjects = 0;
let restoredBytes = 0;

for (const [bucket, entry] of Object.entries(manifest.storage || {})) {
  if (entry.excluded) continue;
  if (entry.error || !Array.isArray(entry.files)) throw new Error(`Backup storage inventory is invalid for ${bucket}`);

  for (const object of entry.files) {
    const bucketPath = encodeURIComponent(bucket);
    const objectPath = encodedPath(object.path);
    const localPath = path.join(backupDir, ...safeSegments(object.file));
    const data = await fs.readFile(localPath);

    if (data.length !== object.bytes || sha256(data) !== object.sha256) {
      throw new Error(`Backup object failed pre-upload verification: ${bucket}/${object.path}`);
    }

    const upload = await fetch(`${url}/storage/v1/object/${bucketPath}/${objectPath}`, {
      method: 'POST',
      headers: {
        ...headers,
        'content-type': 'application/octet-stream',
        'x-upsert': 'true',
      },
      body: data,
    });
    if (!upload.ok) throw new Error(`Unable to restore ${bucket}/${object.path}: ${await responseError(upload)}`);

    const verify = await fetch(`${url}/storage/v1/object/authenticated/${bucketPath}/${objectPath}`, { headers });
    if (!verify.ok) throw new Error(`Unable to verify ${bucket}/${object.path}: ${await responseError(verify)}`);
    const restored = Buffer.from(await verify.arrayBuffer());
    if (restored.length !== object.bytes || sha256(restored) !== object.sha256) {
      throw new Error(`Restored object hash mismatch: ${bucket}/${object.path}`);
    }

    restoredObjects += 1;
    restoredBytes += restored.length;
  }
}

console.log(`PASS: restored and hash-verified ${restoredObjects} storage objects (${restoredBytes} bytes).`);
