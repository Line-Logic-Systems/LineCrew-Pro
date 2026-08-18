#!/usr/bin/env node
import fs from 'node:fs';
import vm from 'node:vm';

const scriptPath = 'scripts/manage-test-platform-owner.mjs';
const workflowPath = '.github/workflows/manage-test-platform-owner.yml';
for (const path of [scriptPath, workflowPath]) {
  if (!fs.existsSync(path)) throw new Error(`Missing ${path}`);
}

const script = fs.readFileSync(scriptPath, 'utf8');
const workflow = fs.readFileSync(workflowPath, 'utf8');
new vm.SourceTextModule(script, { identifier: scriptPath });

for (const marker of [
  'DISPOSABLE_ONLY',
  'SUPABASE_TEST_PROJECT_REF',
  'SUPABASE_PRODUCTION_PROJECT_REF',
  'projectRef === productionRef',
  "['grant','revoke']",
  'platform_owners',
  'Grant verification failed',
  'Revoke verification failed',
]) {
  if (!script.includes(marker)) throw new Error(`Test owner manager is missing safety marker: ${marker}`);
}
for (const marker of [
  'environment: isolation-test',
  'SUPABASE_TEST_SERVICE_ROLE_KEY',
  'SUPABASE_PRODUCTION_PROJECT_REF',
  'LINECREW_ISOLATION_TEST_CONFIRM',
  'permissions:',
  'contents: read',
]) {
  if (!workflow.includes(marker)) throw new Error(`Test owner workflow is missing safety marker: ${marker}`);
}

if (/service_role\s*=\s*['"][^'"]+/i.test(script + workflow)) {
  throw new Error('Potential hard-coded service-role secret detected.');
}

console.log('PASS: disposable test platform-owner management tooling is guarded and syntactically valid.');
