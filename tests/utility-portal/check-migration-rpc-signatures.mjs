import { readFileSync, readdirSync } from 'node:fs';

const manifestUrl = new URL('./approved-rpc-columns.json', import.meta.url);
const migrationsUrl = new URL('../../supabase/migrations/', import.meta.url);
const migrationUrls = readdirSync(migrationsUrl)
  .filter((name) => name.endsWith('.sql') && !name.endsWith('.rollback.sql'))
  .sort()
  .map((name) => new URL(name, migrationsUrl));
const approved = JSON.parse(readFileSync(manifestUrl, 'utf8'));
const migrations = migrationUrls.map((url) => ({
  path: url.pathname,
  sql: readFileSync(url, 'utf8'),
}));

for (const [functionName, approvedColumns] of Object.entries(approved)) {
  const escapedName = functionName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const declaration = new RegExp(
    `create\\s+or\\s+replace\\s+function\\s+public\\.${escapedName}\\s*\\([\\s\\S]*?\\)\\s*` +
      `returns\\s+(?:table\\s*\\(([\\s\\S]*?)\\)|void)\\s*language`,
    'gi'
  );
  const declarations = migrations.flatMap((migration) => {
    const matches = [...migration.sql.matchAll(declaration)];
    if (matches.length > 1) {
      throw new Error(`${functionName} has ${matches.length} declarations in ${migration.path}.`);
    }
    return matches.map((match) => ({ match, path: migration.path, sql: migration.sql }));
  });
  if (declarations.length === 0) {
    throw new Error(`${functionName} has no declaration in the guarded migrations.`);
  }

  // Migration order is authoritative: a later CREATE OR REPLACE intentionally
  // supersedes the earlier signature and is the declaration shipped to Postgres.
  const { match: latest, path: latestPath, sql: latestSql } = declarations.at(-1);

  const actualColumns = latest[1]
    ? latest[1].split(',').map((column) => column.trim().split(/\s+/)[0])
    : [];
  if (JSON.stringify(actualColumns) !== JSON.stringify(approvedColumns)) {
    throw new Error(
      `${functionName} migration signature mismatch\n` +
      `expected ${JSON.stringify(approvedColumns)}\n` +
      `actual   ${JSON.stringify(actualColumns)}\n` +
      `source   ${latestPath}`
    );
  }

  const escapedAclName = functionName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const revokePattern = new RegExp(
    `revoke\\s+all\\s+on\\s+function\\s+public\\.${escapedAclName}\\s*\\([^;]*?\\)\\s+from\\s+([^;]+);`,
    'gi'
  );
  const aclSql = latestSql.slice(latest.index);
  const revokeMatches = [...aclSql.matchAll(revokePattern)];
  if (!revokeMatches.some((match) => /\bpublic\b/i.test(match[1]) && /\banon\b/i.test(match[1]))) {
    throw new Error(`${functionName} must revoke EXECUTE from public and anon.`);
  }

  const grantPattern = new RegExp(
    `grant\\s+execute\\s+on\\s+function\\s+public\\.${escapedAclName}\\s*\\([^;]*?\\)\\s+to\\s+([^;]+);`,
    'gi'
  );
  const grantMatches = [...aclSql.matchAll(grantPattern)];
  if (grantMatches.length === 0 || grantMatches.some((match) => match[1].trim().toLowerCase() !== 'authenticated')) {
    throw new Error(`${functionName} must grant EXECUTE only to authenticated.`);
  }
}

console.log(`Utility migration RPC signatures match ${manifestUrl.pathname}.`);
