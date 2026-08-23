import fs from 'node:fs';

const failures = [];
const assert = (condition, message) => { if (!condition) failures.push(message); };

const mustExist = [
  'index.html',
  'vercel.json',
  'scripts/validate-app.mjs',
  'supabase/functions/linecrew-assistant/index.ts',
  'supabase/functions/send-team-invitation/index.ts',
  'supabase/migrations/20260818_owner_superintendent_roles.sql',
  'supabase/migrations/20260818_owner_superintendent_team_access.sql',
  'supabase/migrations/202608190100_owner_legacy_compatibility.sql',
  'supabase/migrations/202608190200_superintendent_legacy_compatibility.sql'
];
for (const file of mustExist) assert(fs.existsSync(file), `Missing ${file}`);

const index = fs.readFileSync('index.html', 'utf8');
const vercel = JSON.parse(fs.readFileSync('vercel.json', 'utf8'));
const assistant = fs.readFileSync('supabase/functions/linecrew-assistant/index.ts', 'utf8');
const teamInvitation = fs.readFileSync('supabase/functions/send-team-invitation/index.ts', 'utf8');
const roleMigration = fs.readFileSync('supabase/migrations/20260818_owner_superintendent_roles.sql', 'utf8');
const accessMigration = fs.readFileSync('supabase/migrations/20260818_owner_superintendent_team_access.sql', 'utf8');
const ownerCompat = fs.readFileSync('supabase/migrations/202608190100_owner_legacy_compatibility.sql', 'utf8');
const superintendentCompat = fs.readFileSync('supabase/migrations/202608190200_superintendent_legacy_compatibility.sql', 'utf8');

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
for (const [label, pattern] of publicSecretPatterns) assert(!pattern.test(index), `${label} appears in public index.html`);

assert(assistant.includes('client.auth.getUser()'), 'AI assistant must authenticate the caller.');
assert(assistant.includes('.select("company_id, role, active")'), 'AI assistant must load role and active status server-side.');
assert(assistant.includes('!["admin", "owner"].includes(role)'), 'AI assistant must reject every role except active Owner/Admin server-side.');
assert(assistant.includes('profile.active !== true'), 'AI assistant must reject suspended Admin profiles.');
assert(assistant.includes('.eq("company_id", companyId)'), 'AI assistant company data queries must be tenant-scoped.');
assert(!assistant.includes('Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")'), 'AI assistant should not use a service-role key for user-scoped reads.');
assert(assistant.includes('store: false'), 'AI responses must disable OpenAI application-state storage.');
assert(assistant.includes('history.slice(-10)'), 'AI assistant must bound conversational history.');
assert(index.includes("function userCanUseAssistant(){ return currentUserRole() === 'admin'; }"), 'AI assistant launcher must be Admin-only.');
assert(!index.includes("['ai_assistant','AI Assistant']"), 'AI assistant must not be configurable as a Superintendent capability.');

assert(teamInvitation.includes('Deno.env.get("RESEND_API_KEY")'), 'Team invitation sender must use the server-side Resend secret.');
assert(teamInvitation.includes('client.auth.getUser()'), 'Team invitation sender must authenticate the caller.');
assert(teamInvitation.includes('.select("company_id, role, role_permissions, active")'), 'Team invitation sender must load company authorization server-side.');
assert(teamInvitation.includes('profile.active !== true'), 'Team invitation sender must reject suspended profiles.');
assert(teamInvitation.includes('permissions.team_management !== false'), 'Superintendent team invitations must respect the team-management capability.');
assert(teamInvitation.includes('.eq("id", profile.company_id)'), 'Team invitation company data must be derived from the caller profile.');
assert(teamInvitation.includes('LineCrew Pro <invites@auth.linecrewpro.com>'), 'Team invitations must use the verified app sender.');
assert(teamInvitation.includes('reply_to: "support@linecrewpro.com"'), 'Team invitations need the company support reply-to address.');
assert(!teamInvitation.includes('SUPABASE_SERVICE_ROLE_KEY'), 'Team invitation sender must not bypass RLS with a service-role key.');
assert(index.includes("sb.functions.invoke('send-team-invitation'"), 'Team invitation button must invoke the secured server sender.');

for (const role of ['foreman', 'gf', 'superintendent', 'admin', 'owner']) assert(roleMigration.includes(`'${role}'`), `Role migration is missing ${role}.`);
assert(roleMigration.includes('drop constraint if exists profiles_role_supported'), 'Role migration must replace the legacy three-role constraint.');
assert(roleMigration.includes('linecrew_claim_initial_owner'), 'Role migration must provide a safe initial Owner claim path.');
assert(roleMigration.includes('linecrew_set_member_role'), 'Role migration must centralize role changes.');
assert(roleMigration.includes('Only an Owner can manage Owner or Admin roles'), 'Admins must not be able to manage Owners or peer Admins.');
assert(roleMigration.includes('Assign another Owner before removing the last Owner'), 'The last Owner must be protected from removal.');
assert(roleMigration.includes('A Superintendent can manage General Foreman and Foreman roles only'), 'Superintendent delegated role management must stop above GF/Foreman.');
assert(roleMigration.includes("role_permissions ->> 'role_management'"), 'Superintendent role-management capability must be enforced server-side.');
assert(roleMigration.includes('linecrew_set_superintendent_permissions'), 'Superintendent permission overrides must be server-enforced.');
assert(roleMigration.includes("jsonb_typeof(item.value) <> 'boolean'"), 'Superintendent overrides must accept boolean values only.');
assert(roleMigration.includes('actor.active is not true'), 'Role-management RPCs must reject suspended leadership profiles.');
assert(roleMigration.includes('and p.active is true'), 'Capability checks must reject suspended profiles.');

assert(accessMigration.includes('set_company_member_active'), 'Team access changes need a secured hierarchy RPC.');
assert(accessMigration.includes("target_role in ('owner','admin')"), 'Admins must not suspend Owners or peer Admins.');
assert(accessMigration.includes("target_role not in ('foreman','gf')"), 'Superintendents must not suspend peers or higher roles.');
assert(accessMigration.includes('Assign another active Owner before suspending the last Owner'), 'The final active Owner must be protected from suspension.');

assert(ownerCompat.includes("'owner'"), 'Legacy secured RPCs must recognize Owner.');
assert(superintendentCompat.includes('linecrew_has_capability'), 'Legacy Superintendent RPC compatibility must be capability-gated.');
for (const cap of ['jobs','job_packages','production_review','reporting','storm_mode','safety_records','actual_pricing','price_books','company_settings','team_management']) {
  assert(superintendentCompat.includes(`'${cap}'`), `Superintendent compatibility is missing ${cap}.`);
}
assert(superintendentCompat.includes("v_role = 'superintendent' and public.linecrew_has_capability('actual_pricing')"), 'Actual pricing visibility must remain independently gated for Superintendents.');

for (const marker of [
  "['owner','admin'].includes(currentUserRole())",
  "role === 'superintendent'",
  "linecrew_set_member_role",
  "linecrew_set_superintendent_permissions",
  "linecrew_claim_initial_owner",
  "userCanManageCustomersContracts()",
  "userCanManagePriceBooks()",
  "userCanManageJobPackages()",
  "userCanReviewProduction()",
  "userCanUseReporting()",
  "userCanManageStormMode()",
  "userCanUseAssistant()"
]) assert(index.includes(marker), `Role-aware frontend marker missing: ${marker}`);

for (const marker of [
  'id="emailTeamInviteBtn"',
  'Invitation sent from invites@auth.linecrewpro.com.',
  'id="newPriceBookImportFile"',
  'Save Price Book &amp; Continue',
  'await handlePriceBookImportFile(selectedImportFile)',
  'Review the unit-pricing preview'
]) assert(index.includes(marker), `Onboarding workflow marker missing: ${marker}`);

if (failures.length) {
  console.error('Production readiness validation failed:');
  failures.forEach(failure => console.error(`- ${failure}`));
  process.exit(1);
}

console.log('Production readiness validation passed.');
console.log('- Vercel security headers and secret checks passed');
console.log('- Active Owner/Admin-only AI authorization present');
console.log('- Owner/Admin/Superintendent hierarchy protections present');
console.log('- Suspended leadership profiles cannot use role/capability management');
console.log('- Legacy Owner compatibility present');
console.log('- Capability-aware Superintendent legacy RPC compatibility present');
console.log('- Actual pricing remains independently gated');
console.log('- Team, job, package, reporting, storm and assistant UI capability wiring present');
console.log('- Authenticated Resend team invitations and first-run Price Book uploads present');
