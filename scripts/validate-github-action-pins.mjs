#!/usr/bin/env node

import fs from 'node:fs';
import path from 'node:path';

const workflowDirectory = '.github/workflows';
const workflowFiles = fs.readdirSync(workflowDirectory)
  .filter(name => name.endsWith('.yml') || name.endsWith('.yaml'));
const failures = [];

for (const name of workflowFiles) {
  const file = path.join(workflowDirectory, name);
  const lines = fs.readFileSync(file, 'utf8').split('\n');

  lines.forEach((line, index) => {
    const match = line.match(/^\s*-?\s*uses:\s*([^\s#]+)/);
    if (!match) return;

    const reference = match[1];
    if (reference.startsWith('./') || reference.startsWith('docker://')) return;

    const separator = reference.lastIndexOf('@');
    const revision = separator >= 0 ? reference.slice(separator + 1) : '';
    if (!/^[0-9a-f]{40}$/.test(revision)) {
      failures.push(`${file}:${index + 1} is not pinned to a full commit SHA: ${reference}`);
    }
  });
}

if (failures.length) {
  console.error('GitHub Action pin validation failed:');
  failures.forEach(failure => console.error(`- ${failure}`));
  process.exit(1);
}

console.log(`GitHub Action pin validation passed for ${workflowFiles.length} workflow files.`);
