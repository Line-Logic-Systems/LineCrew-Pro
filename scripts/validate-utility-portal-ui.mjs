import fs from 'node:fs';

const app = fs.readFileSync('index.html', 'utf8');
const portal = fs.readFileSync('utility-portal-management.js', 'utf8');
const shell = fs.readFileSync('service-worker.js', 'utf8');
const sendInvitation = fs.readFileSync('supabase/functions/send-utility-invitation/index.ts', 'utf8');
const completeInvitation = fs.readFileSync('supabase/functions/complete-utility-invitation-signup/index.ts', 'utf8');
const failures = [];
const assert = (condition, message) => { if (!condition) failures.push(message); };

for (const id of [
  'utilityPortalTile', 'utilityPortalPage', 'utilityOrganizationList',
  'utilityRepresentativeList', 'utilityGrantList', 'utilityActivityList',
  'utilityViewerPage', 'utilityViewerJobs', 'utilityViewerJobDetail'
]) {
  assert(app.includes(`id="${id}"`), `Missing Utility Portal element: ${id}`);
}

assert(app.includes('utility-portal-management.js?v=20260908a'), 'Utility Portal script is not loaded by the app.');
assert(shell.includes("'linecrew-pro-shell-v96'"), 'Utility Portal requires the current offline shell.');
assert(shell.includes("'/utility-portal-management.js?v=20260908a'"), 'Utility Portal script is missing from the offline shell.');
assert(portal.includes("p_include_inactive: false"), 'Utility Portal management must hide inactive historical organizations.');
assert(app.includes('pendingInviteToken || pendingUtilityInviteToken'), 'Utility invitations are not integrated into startup routing.');
assert(app.includes('LineCrewUtilityPortal.completeInvitation'), 'Utility invitation signup is not wired.');
assert(app.includes('LineCrewUtilityPortal?.tryLoadViewer'), 'Utility representative routing is not wired.');
assert(
  app.includes("}\n}\nif(page === 'utilityPortalPage'){\nawait window.LineCrewUtilityPortal?.loadManagement?.();\n}\n}"),
  'Utility Portal management must load automatically at the top-level page navigation boundary.'
);

for (const rpc of [
  'utility_list_organizations', 'utility_list_representatives',
  'utility_contract_visibility_state', 'utility_activity_feed',
  'utility_unassigned_job_count', 'utility_create_organization_with_grants',
  'utility_add_contract_grants', 'utility_set_grant_show_quantities',
  'utility_revoke_contract_grant', 'utility_cancel_invitation',
  'utility_me', 'utility_list_jobs', 'utility_get_job_progress'
]) {
  assert(portal.includes(`'${rpc}'`), `Utility Portal does not call ${rpc}.`);
}

assert(!/p_company_id\s*:|p_user_id\s*:|p_invite_token_hash\s*:/.test(portal), 'Utility Portal must not send tenant ids, user ids, or token hashes to RPCs.');
assert(!portal.includes('invite_token_hash'), 'Utility Portal must never read or render invitation token hashes.');
assert(!portal.includes('price_book'), 'Utility Portal must not read contract pricing.');
assert(portal.includes(".eq('company_id', currentProfile.company_id)"), 'Contract choices must be scoped to the signed-in company.');
assert(sendInvitation.includes('crypto.getRandomValues(new Uint8Array(32))'), 'Invitation tokens must be cryptographically random.');
assert(sendInvitation.includes('crypto.subtle.digest("SHA-256"'), 'Invitation tokens must be hashed before database storage.');
assert(sendInvitation.includes('const applicationOrigin = origin && allowedOrigins.has(origin)'), 'Invitation URLs must use only an allowlisted application origin.');
assert(sendInvitation.includes('if (isTestProject)'), 'Local invitation origins must be limited to the test project.');
assert(completeInvitation.includes('if (isTestProject)'), 'Local signup origins must be limited to the test project.');
assert(shell.includes("url.searchParams.has('invite')") && shell.includes("url.searchParams.has('utilityInvite')"), 'Invitation URLs must never be cached.');
assert(portal.includes('item.organization_name'), 'Company-wide activity must identify its utility organization.');
assert(portal.includes('approved_retirement_quantity'), 'Shared retirement quantities must be rendered.');
assert(!completeInvitation.includes('invite_token_hash: rawToken'), 'Raw invitation tokens must not be stored.');

try { new Function(portal); } catch (error) { failures.push(`Utility Portal JavaScript syntax error: ${error.message}`); }

if (failures.length) {
  console.error('Utility Portal UI validation failed:\n- ' + failures.join('\n- '));
  process.exit(1);
}

console.log('Utility Portal UI validation passed.');
console.log('- Contractor management and representative read-only views are wired');
console.log('- Invitation signup and offline shell integration are present');
console.log('- No company override, token hash, or pricing path is exposed');
