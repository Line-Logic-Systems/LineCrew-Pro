import fs from 'node:fs';

const entries = fs.readdirSync('supabase/migrations', { withFileTypes:true });
const migrationFiles = entries.filter(entry => entry.isFile() && entry.name.endsWith('.sql')).map(entry => entry.name);
const rollbackFiles = migrationFiles.filter(name => /\.rollback\.sql$/i.test(name));
if(rollbackFiles.length){
  throw new Error(`Rollback scripts must not live in supabase/migrations: ${rollbackFiles.join(', ')}`);
}
const versions = new Map();
for(const file of migrationFiles){
  const match = file.match(/^(\d{14})_/);
  if(!match) throw new Error(`Migration filename must begin with a 14-digit version: ${file}`);
  const version = match[1];
  const prior = versions.get(version);
  if(prior) throw new Error(`Duplicate migration version ${version}: ${prior}, ${file}`);
  versions.set(version,file);
}
console.log(`Migration hygiene guard passed for ${migrationFiles.length} migrations.`);
