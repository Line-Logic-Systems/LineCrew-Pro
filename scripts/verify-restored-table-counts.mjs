#!/usr/bin/env node
import fs from 'node:fs/promises';
import path from 'node:path';

const backupDir = process.argv[2];
const url = process.env.SUPABASE_URL?.replace(/\/$/, '');
const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

if (!backupDir) throw new Error('Usage: node scripts/verify-restored-table-counts.mjs <timestamped-backup-directory>');
if (!url || !serviceRoleKey) throw new Error('SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required');

const manifest = JSON.parse(await fs.readFile(path.join(backupDir, 'manifest.json'), 'utf8'));
const headers = {
  apikey: serviceRoleKey,
  Authorization: `Bearer ${serviceRoleKey}`,
  Prefer: 'count=exact',
  Range: '0-0',
};
const failures = [];

for (const table of manifest.required_public_tables || []) {
  if (!/^[a-z0-9_]+$/.test(table)) throw new Error(`Unsafe table name in manifest: ${table}`);
  const response = await fetch(`${url}/rest/v1/${encodeURIComponent(table)}?select=*`, { headers });
  if (!response.ok) {
    failures.push(`${table}: ${response.status} ${response.statusText}`);
    continue;
  }
  const range = response.headers.get('content-range') || '';
  const match = range.match(/\/(\d+)$/);
  if (!match) {
    failures.push(`${table}: missing exact Content-Range count`);
    continue;
  }
  const restoredRows = Number(match[1]);
  const expectedRows = Number(manifest.tables?.[table]?.rows);
  if (restoredRows !== expectedRows) failures.push(`${table}: expected ${expectedRows} rows, restored ${restoredRows}`);
}

if (failures.length) {
  console.error(failures.map((failure) => `FAIL: ${failure}`).join('\n'));
  process.exitCode = 1;
} else {
  console.log(`PASS: restored row counts match all ${manifest.required_public_tables.length} public tables.`);
}
