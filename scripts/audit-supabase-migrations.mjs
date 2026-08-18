import fs from 'node:fs';
import path from 'node:path';

const migrationDirectory = 'supabase/migrations';
const baselinePath = 'supabase/baseline/00000000000000_public_schema.sql';
const strict = process.argv.includes('--strict');

const failures = [];
const warnings = [];

if (!fs.existsSync(baselinePath)) {
  failures.push(`Verified baseline is missing: ${baselinePath}`);
}

const migrationFiles = fs.existsSync(migrationDirectory)
  ? fs.readdirSync(migrationDirectory).filter(file => file.endsWith('.sql')).sort()
  : [];

if (!migrationFiles.length) {
  failures.push(`No SQL migrations found in ${migrationDirectory}.`);
}

const versions = new Map();
for (const file of migrationFiles) {
  const match = file.match(/^(\d+)_/);
  if (!match) {
    failures.push(`Migration has no numeric version prefix: ${file}`);
    continue;
  }

  const files = versions.get(match[1]) ?? [];
  files.push(file);
  versions.set(match[1], files);
}

const collisions = [...versions.entries()].filter(([, files]) => files.length > 1);
for (const [version, files] of collisions) {
  warnings.push(`Version ${version} is shared by ${files.length} migrations: ${files.join(', ')}`);
}

const riskyStatements = [];
const riskyPattern = /^\s*(drop\s+(?:table|column|function|constraint)|truncate\b|delete\s+from\b)/gim;
for (const file of migrationFiles) {
  const sql = fs.readFileSync(path.join(migrationDirectory, file), 'utf8');
  const matches = [...sql.matchAll(riskyPattern)];
  if (matches.length) riskyStatements.push(`${file}: ${matches.length}`);
}

console.log('Supabase migration audit');
console.log(`- Verified baseline: ${fs.existsSync(baselinePath) ? 'present' : 'missing'}`);
console.log(`- Migration files: ${migrationFiles.length}`);
console.log(`- Unique version prefixes: ${versions.size}`);
console.log(`- Version collisions: ${collisions.length}`);
console.log(`- Files containing destructive/data-removal statements: ${riskyStatements.length}`);

if (warnings.length) {
  console.warn('\nWarnings:');
  warnings.forEach(warning => console.warn(`- ${warning}`));
}

if (riskyStatements.length) {
  console.warn('\nManual-review files:');
  riskyStatements.forEach(statement => console.warn(`- ${statement}`));
}

if (failures.length) {
  console.error('\nMigration audit failed:');
  failures.forEach(failure => console.error(`- ${failure}`));
  process.exit(1);
}

if (strict && warnings.length) {
  console.error('\nStrict migration audit failed because warnings remain unresolved.');
  process.exit(1);
}

console.log('\nMigration audit completed. Historical warnings are documented in docs/DATABASE_MIGRATION_AUDIT.md.');
