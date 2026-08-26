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

const mimeByExtension = new Map([
  ['.pdf', 'application/pdf'],
  ['.jpg', 'image/jpeg'],
  ['.jpeg', 'image/jpeg'],
  ['.png', 'image/png'],
  ['.gif', 'image/gif'],
  ['.webp', 'image/webp'],
  ['.heic', 'image/heic'],
  ['.heif', 'image/heif'],
  ['.mp4', 'video/mp4'],
  ['.mov', 'video/quicktime'],
  ['.csv', 'text/csv'],
  ['.txt', 'text/plain'],
  ['.json', 'application/json'],
  ['.zip', 'application/zip'],
  ['.xls', 'application/vnd.ms-excel'],
  ['.xlsx', 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'],
  ['.doc', 'application/msword'],
  ['.docx', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'],
]);

function normalizedMime(value) {
  const mime = typeof value === 'string' ? value.split(';', 1)[0].trim().toLowerCase() : '';
  return /^[a-z0-9][a-z0-9!#$&^_.+-]*\/[a-z0-9][a-z0-9!#$&^_.+-]*$/.test(mime) ? mime : null;
}

function contentTypeFor(object, data) {
  const recorded = normalizedMime(object.mimeType || object.contentType);
  if (recorded && recorded !== 'application/octet-stream') return recorded;

  const inferred = mimeByExtension.get(path.extname(object.path).toLowerCase());
  if (inferred) return inferred;

  if (data.subarray(0, 5).toString('ascii') === '%PDF-') return 'application/pdf';
  if (data.length >= 4 && data[0] === 0xff && data[1] === 0xd8 && data[2] === 0xff) return 'image/jpeg';
  if (data.length >= 8 && data.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]))) return 'image/png';

  return 'application/octet-stream';
}

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

const resumableChunkBytes = 6 * 1024 * 1024;
const projectRef = new URL(url).hostname.split('.')[0];
const resumableEndpoint = `https://${projectRef}.storage.supabase.co/storage/v1/upload/resumable`;
const tusMetadata = (value) => Buffer.from(value, 'utf8').toString('base64');

async function resumableUpload(bucket, objectPath, data, contentType) {
  const create = await fetch(resumableEndpoint, {
    method: 'POST',
    headers: {
      ...headers,
      'tus-resumable': '1.0.0',
      'upload-length': String(data.length),
      'upload-metadata': [
        `bucketName ${tusMetadata(bucket)}`,
        `objectName ${tusMetadata(objectPath)}`,
        `contentType ${tusMetadata(contentType)}`,
        `cacheControl ${tusMetadata('3600')}`,
      ].join(','),
      'x-upsert': 'true',
    },
  });
  if (!create.ok) {
    const detail = await responseError(create);
    if (create.status === 413) {
      const requiredMb = Math.ceil(data.length / (1024 * 1024));
      throw new Error(`Recovery project Storage limit is too small for ${bucket}/${objectPath} (${requiredMb} MB). Increase the project's global Storage file-size limit, then restart the drill. ${detail}`);
    }
    throw new Error(`Unable to start resumable restore for ${bucket}/${objectPath}: ${detail}`);
  }

  const location = create.headers.get('location');
  if (!location) throw new Error(`Resumable restore returned no upload URL for ${bucket}/${objectPath}`);
  const uploadUrl = new URL(location, resumableEndpoint).toString();

  for (let offset = 0; offset < data.length; ) {
    const end = Math.min(offset + resumableChunkBytes, data.length);
    const chunk = data.subarray(offset, end);
    const patch = await fetch(uploadUrl, {
      method: 'PATCH',
      headers: {
        ...headers,
        'tus-resumable': '1.0.0',
        'upload-offset': String(offset),
        'content-type': 'application/offset+octet-stream',
      },
      body: chunk,
    });
    if (!patch.ok) throw new Error(`Unable to continue resumable restore for ${bucket}/${objectPath}: ${await responseError(patch)}`);
    const nextOffset = Number(patch.headers.get('upload-offset'));
    if (nextOffset !== end) throw new Error(`Resumable restore offset mismatch for ${bucket}/${objectPath}: expected ${end}, received ${nextOffset}`);
    offset = nextOffset;
  }
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
    const contentType = contentTypeFor(object, data);

    if (data.length !== object.bytes || sha256(data) !== object.sha256) {
      throw new Error(`Backup object failed pre-upload verification: ${bucket}/${object.path}`);
    }

    if (data.length > resumableChunkBytes) {
      await resumableUpload(bucket, object.path, data, contentType);
    } else {
      const upload = await fetch(`${url}/storage/v1/object/${bucketPath}/${objectPath}`, {
        method: 'POST',
        headers: {
          ...headers,
          'content-type': contentType,
          'x-upsert': 'true',
        },
        body: data,
      });
      if (!upload.ok) throw new Error(`Unable to restore ${bucket}/${object.path}: ${await responseError(upload)}`);
    }

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
