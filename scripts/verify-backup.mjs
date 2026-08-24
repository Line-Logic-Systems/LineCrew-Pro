#!/usr/bin/env node
import crypto from 'node:crypto';
import fs from 'node:fs/promises';
import path from 'node:path';

const backupDir = process.argv[2];
if (!backupDir) throw new Error('Usage: node scripts/verify-backup.mjs <timestamped-backup-directory>');
const sha256 = (data) => crypto.createHash('sha256').update(data).digest('hex');
const manifest = JSON.parse(await fs.readFile(path.join(backupDir, 'manifest.json'), 'utf8'));
const failures = [];
if (manifest.format_version !== 2) failures.push(`Unsupported manifest format ${manifest.format_version}`);
if (!Array.isArray(manifest.required_public_tables) || !manifest.required_public_tables.length) failures.push('No required table inventory');
if (manifest.errors?.length) failures.push(`Manifest records ${manifest.errors.length} backup error(s)`);

for (const table of manifest.required_public_tables || []) {
  const entry = manifest.tables?.[table];
  if (!entry || entry.error || !entry.file) { failures.push(`Missing or failed table: ${table}`); continue; }
  try {
    const bytes = await fs.readFile(path.join(backupDir, entry.file));
    const rows = JSON.parse(bytes.toString('utf8'));
    if (!Array.isArray(rows)) failures.push(`${table} is not a JSON array`);
    else if (rows.length !== entry.rows) failures.push(`${table} row count mismatch`);
    if (bytes.length !== entry.bytes) failures.push(`${table} byte count mismatch`);
    if (sha256(bytes) !== entry.sha256) failures.push(`${table} SHA-256 mismatch`);
  } catch (error) { failures.push(`${table} could not be verified: ${error.message}`); }
}

for (const [bucket, entry] of Object.entries(manifest.storage || {})) {
  if (entry.excluded) continue;
  if (entry.error) failures.push(`Storage bucket ${bucket} failed during backup`);
  if (!Array.isArray(entry.files)) { failures.push(`Storage bucket ${bucket} has no file inventory`); continue; }
  let byteTotal = 0;
  for (const object of entry.files) {
    try {
      const bytes = await fs.readFile(path.join(backupDir, ...object.file.split('/')));
      byteTotal += bytes.length;
      if (bytes.length !== object.bytes) failures.push(`${bucket}/${object.path} byte count mismatch`);
      if (sha256(bytes) !== object.sha256) failures.push(`${bucket}/${object.path} SHA-256 mismatch`);
    } catch (error) { failures.push(`${bucket}/${object.path} could not be verified: ${error.message}`); }
  }
  if (entry.objects !== entry.files.length) failures.push(`${bucket} object count mismatch`);
  if (entry.bytes !== byteTotal) failures.push(`${bucket} byte total mismatch`);
}

if (failures.length) {
  console.error(failures.map((failure) => `FAIL: ${failure}`).join('\n'));
  process.exitCode = 1;
} else {
  console.log(`PASS: verified ${Object.keys(manifest.tables).length} tables and all included storage objects.`);
}
