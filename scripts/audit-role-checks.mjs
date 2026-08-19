import fs from 'node:fs';
import path from 'node:path';

const files = ['index.html'];
const migrationDir = 'supabase/migrations';
for (const name of fs.readdirSync(migrationDir)) {
  if (name.endsWith('.sql')) files.push(path.join(migrationDir, name));
}
const functionDir = 'supabase/functions';
if (fs.existsSync(functionDir)) {
  for (const fn of fs.readdirSync(functionDir)) {
    const p = path.join(functionDir, fn, 'index.ts');
    if (fs.existsSync(p)) files.push(p);
  }
}

const patterns = [
  /role[^\n]{0,80}admin/ig,
  /admin[^\n]{0,80}role/ig,
  /\['admin'[^\n]*/ig,
  /===\s*['"]admin['"]/ig,
  /<>\s*['"]admin['"]/ig,
  /!=+\s*['"]admin['"]/ig,
  /only[^\n]{0,100}admin/ig,
  /userIsCompanyAdmin\(\)/g
];

let out = '# LineCrew Pro role compatibility audit\n\n';
out += 'Generated from the staged Owner/Superintendent branch. These are candidate legacy Admin checks to review before production activation.\n\n';
for (const file of files) {
  const text = fs.readFileSync(file, 'utf8');
  const lines = text.split(/\r?\n/);
  const hits = [];
  lines.forEach((line, i) => {
    if (patterns.some(p => { p.lastIndex = 0; return p.test(line); })) {
      hits.push(`${i + 1}: ${line.trim()}`);
    }
  });
  if (hits.length) {
    out += `## ${file}\n\n`;
    for (const hit of hits) out += `- \`${hit.replaceAll('`','\\`')}\`\n`;
    out += '\n';
  }
}
fs.writeFileSync('docs/ROLE_AUDIT.md', out);
console.log('Wrote docs/ROLE_AUDIT.md');
