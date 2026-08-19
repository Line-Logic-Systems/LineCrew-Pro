import fs from 'node:fs';

const failures = [];
const assert = (condition, message) => { if (!condition) failures.push(message); };

const mustExist = [
  'index.html',
  'vercel.json',
  'scripts/validate-app.mjs',
  'supabase/functions/linecrew-assistant/index.ts',
  'supabase/migrations/20260818_owner_superintendent_roles.sql'
];
for (const file of mustExist) assert(fs.existsSync(file), `Missing ${file}`);

const index = fs.readFileSync('index.html', 'utf8');
const vercel = JSON.parse(fs.readFileSync('vercel.json', 'utf8'));
const assistant = fs.readFileSync('supabase/functions/linecrew-assistant/index.ts', 'utf8');
const roleMigration = fs.readFileSync('supabase/migrations/20260818_owner_superintendent_roles.sql', 'utf8');

const vercelText = JSON.stringify(vercel);
for (const header of ['X-Content-Type-Options','X-Frame-Options','Referrer-Policy','X-Robots-Tag','Content-Security-Policy','Strict-Transport-Security']) {
  assert(vercelText.includes(header), `Missing production response header: ${header}`);
}
assert(vercelText.includes("frame-ancestors 'none'"), 'App must prevent framing/clickjacking.');
assert(vercelText.includes('noindex, nofollow'), 'Operational app should not be indexed by search engines.');

const publicSecretPatterns = [
  ['OpenAI secret key', /sk-(?:proj-)?[A-Za-z0-9_-]{20,}/],
  ['Supabase secret key', /sb_secret_[A-Za-z0-9_-]+/i],
  ['Supabase service role JWT marker', /service[_-]?role[^\n]{0,80}eyJ/i],
  ['Private key', /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/]
];
for (const [label, pattern] of publicSecretPatterns) {
  assert(!pattern.test(index), `${label} appears in public index.html`);
}

assert(assistant.includes('client.auth.getUser()'), 'AI assistant must authenticate the caller.');
assert(assistant.includes('.select("company_id, role, role_permissions")'), 'AI assistant must load role and permission overrides server-side.');
assert(assistant.includes('role === "owner"'), 'Owner must be authorized for the company assistant.');
assert(assistant.includes('role === "admin"'), 'Admin must be authorized for the company assistant.');
assert(assistant.includes('role === "superintendent"'), 'Superintendent authorization must be evaluated server-side.');
assert(assistant.includes('permissions.ai_assistant !== false'), 'Superintendent AI access must honor the ai_assistant permission override.');
assert(assistant.includes('.eq("company_id", companyId)'), 'AI assistant company data queries must be tenant-scoped.');
assert(!assistant.includes('Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")'), 'AI assistant should not use a service-role key for user-scoped reads.');

for (const role of ['foreman', 'gf', 'superintendent', 'admin', 'owner']) {
  assert(roleMigration.includes(`'${role}'`), `Role migration is missing ${role}.`);
}
assert(roleMigration.includes('drop constraint if exists profiles_role_supported'), 'Role migration must replace the legacy three-role constraint.');
assert(roleMigration.includes('linecrew_claim_initial_owner'), 'Role migration must provide a safe initial Owner claim path.');
assert(roleMigration.includes('linecrew_set_member_role'), 'Role migration must centralize role changes.');
assert(roleMigration.includes('Only an Owner can manage Owner or Admin roles'), 'Admins must not be able to manage Owners or peer Admins.');
assert(roleMigration.includes('Assign another Owner before removing the last Owner'), 'The last Owner must be protected from removal.');
assert(roleMigration.includes('set_company_member_role'), 'The legacy Team-screen RPC must be routed through the new role hierarchy.');
assert(roleMigration.includes('linecrew_set_superintendent_permissions'), 'Superintendent permission overrides must be server-enforced.');
assert(roleMigration.includes('company_id = actor.company_id'), 'Role mutations must remain company-scoped.');

if (failures.length) {
  console.error('Production readiness validation failed:');
  failures.forEach(failure => console.error(`- ${failure}`));
  process.exit(1);
}

console.log('Production readiness validation passed.');
console.log('- Vercel security headers present');
console.log('- Public app shell contains no known server-side secret patterns');
console.log('- Owner/Admin/permitted-Superintendent AI authorization present');
console.log('- AI company queries remain tenant-scoped');
console.log('- Owner/Admin/Superintendent hierarchy protections present');
