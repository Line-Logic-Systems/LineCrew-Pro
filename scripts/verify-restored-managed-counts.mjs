#!/usr/bin/env node
import fs from 'node:fs/promises';

const [managedDataPath, actualCountsPath] = process.argv.slice(2);
if (!managedDataPath || !actualCountsPath) {
  throw new Error('Usage: node scripts/verify-restored-managed-counts.mjs <managed-data.sql> <actual-counts.tsv>');
}

const skipped = new Set([
  'auth.schema_migrations',
  'storage.migrations',
  'storage.buckets_vectors',
  'storage.vector_indexes',
]);
const required = new Set(['auth.users', 'auth.identities', 'storage.buckets', 'storage.objects']);
const expected = new Map();
const lines = (await fs.readFile(managedDataPath, 'utf8')).split(/\r?\n/);
let activeTable = null;

for (const line of lines) {
  if (!activeTable) {
    const match = line.match(/^COPY\s+"?(auth|storage)"?\."?([a-z0-9_]+)"?\s+\([^)]*\)\s+FROM stdin;$/i);
    if (!match) continue;
    const name = `${match[1].toLowerCase()}.${match[2].toLowerCase()}`;
    activeTable = skipped.has(name) ? { name, skipped: true } : { name, skipped: false };
    if (!activeTable.skipped) expected.set(name, 0);
    continue;
  }

  if (line === '\\.') {
    activeTable = null;
    continue;
  }
  if (!activeTable.skipped) expected.set(activeTable.name, expected.get(activeTable.name) + 1);
}

if (activeTable) throw new Error(`Unterminated COPY block for ${activeTable.name}`);
for (const table of required) {
  if (!expected.has(table)) throw new Error(`Managed backup is missing table data for ${table}`);
}

const actual = new Map();
for (const line of (await fs.readFile(actualCountsPath, 'utf8')).split(/\r?\n/)) {
  if (!line) continue;
  const [name, value, ...extra] = line.split('\t');
  if (!name || value === undefined || extra.length || !/^\d+$/.test(value)) {
    throw new Error(`Invalid restored managed-table count line: ${line}`);
  }
  actual.set(name, Number(value));
}

const failures = [];
for (const [table, expectedRows] of expected) {
  if (!actual.has(table)) failures.push(`${table}: missing from recovery project`);
  else if (actual.get(table) !== expectedRows) {
    failures.push(`${table}: expected ${expectedRows} rows, restored ${actual.get(table)}`);
  }
}

if (failures.length) {
  console.error(failures.map((failure) => `FAIL: ${failure}`).join('\n'));
  process.exitCode = 1;
} else {
  console.log(`PASS: restored row counts match all ${expected.size} backed-up Auth and Storage tables.`);
}
