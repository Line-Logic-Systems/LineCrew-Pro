import fs from 'node:fs';

const html = fs.readFileSync('index.html', 'utf8');
const failures = [];
const assert = (condition, message) => {
  if (!condition) failures.push(message);
};

assert(html.includes('<!DOCTYPE html>') || html.includes('<!doctype html>'), 'Missing HTML doctype.');
assert(html.includes('/* LINECREW PRO SUPABASE */'), 'Missing main application script marker.');
assert(html.includes('id="authPage"'), 'Missing authentication page.');
assert(html.includes('id="dashboardPage"'), 'Missing dashboard page.');
assert(html.includes('id="productionPage"'), 'Missing production page.');
assert(html.includes('id="jobsPage"'), 'Missing jobs page.');
assert(html.includes('id="priceBooksPage"'), 'Missing Price Books page.');
assert(html.includes('id="teamPage"'), 'Missing Team page.');
assert(html.includes('id="safetyPage"'), 'Missing Safety/JSA page.');
assert(html.includes('id="safetyJsaHistoryCard"'), 'Missing compact completed JSA history control.');
assert(html.includes('id="safetyJsaRecordSelect"'), 'Missing single-record Foreman JSA picker.');
assert(html.includes("'Reset to Today'"), 'Foreman JSA filters must reset to the current day.');
assert(html.includes('createSafetyJsaHistoryCard'), 'Missing reusable JSA history renderer.');
assert(html.includes('Crew Name / Number'), 'Daily Report crew identifier must be clearly labeled.');
assert(
  html.includes('await sb.auth.getUser()') &&
    html.includes('await sb.auth.refreshSession()') &&
    html.includes("await sb.auth.signOut({scope:'local'})") &&
    html.includes('Your secure session expired after an account security update.'),
  'Startup must recover from locally cached sessions invalidated by a signing-key rotation.'
);
assert(
  html.includes("sb.functions.invoke('notify-pilot-feedback'") &&
    html.includes('body:{feedback_id:feedbackId}') &&
    html.includes('Your feedback was saved and emailed to Support.'),
  'Pilot feedback must save first and then invoke the authenticated support email notifier.'
);

// Weekend pilot critical-role markers. These do not replace server-side policy tests;
// they prevent accidental removal of required UI wiring during rapid changes.
for (const marker of [
  "owner:'Owner'",
  "admin:'Admin'",
  "superintendent:'Superintendent'",
  "gf:'General Foreman'",
  "foreman:'Foreman'",
  'linecrew_set_member_role',
  'linecrew_set_superintendent_permissions',
  'linecrew_claim_initial_owner'
]) {
  assert(html.includes(marker), `Missing critical role/team marker: ${marker}`);
}

// Flexible JSA/mobile capture and the in-app multi-page viewer are core pilot flows.
for (const marker of [
  'jsa-attachment-viewer',
  'openUploadedJsaFiles',
  'Upload Company JSA',
  'Take JSA Photo'
]) {
  assert(html.includes(marker), `Missing critical JSA/mobile marker: ${marker}`);
}

const ids = [...html.matchAll(/\sid=["']([^"']+)["']/g)].map(match => match[1]);
const duplicateIds = [...new Set(ids.filter((id, index) => ids.indexOf(id) !== index))];
assert(duplicateIds.length === 0, 'Duplicate HTML ids: ' + duplicateIds.join(', '));

const scriptStart = html.indexOf('/* LINECREW PRO SUPABASE */');
const scriptEnd = html.indexOf('</script>', scriptStart);
if (scriptStart >= 0 && scriptEnd > scriptStart) {
  const applicationCode = html.slice(scriptStart, scriptEnd);
  try {
    new Function(applicationCode);
  } catch (error) {
    failures.push('Application JavaScript syntax error: ' + error.message);
  }
}

// Extension scripts are validated independently so additional script tags do not
// become part of the main inline application parse window.
if (fs.existsSync('expanded-jsa.js')) {
  const expandedJsaCode = fs.readFileSync('expanded-jsa.js', 'utf8');
  try {
    new Function(expandedJsaCode);
  } catch (error) {
    failures.push('Expanded JSA JavaScript syntax error: ' + error.message);
  }
  assert(
    expandedJsaCode.includes("load('timekeeping-input-v2.js"),
    'Foreman Crew Time must load Start/Stop, lunch, per diem, and equipment controls.'
  );
  const timekeepingInputCode = fs.readFileSync('timekeeping-input-v2.js', 'utf8');
  const timekeepingCode = fs.readFileSync('timekeeping.js', 'utf8');
  const roleWorkspaceCode = fs.readFileSync('role-workspace-polish.js', 'utf8');
  assert(
    expandedJsaCode.includes("'linecrew-timekeeping-input-v2'") &&
      timekeepingInputCode.includes("row.dataset.tkLaunchDetails==='1'&&detailIsComplete") &&
      timekeepingInputCode.includes('existingDetail?.remove()'),
    'Foreman Crew Time must prevent duplicate enhancement loads and repair incomplete first-load rows.'
  );
  assert(
    timekeepingCode.includes("row.dataset.tkLaunchDetails='1'") &&
      timekeepingCode.includes('class="tk-start tk-clock24"') &&
      timekeepingCode.includes('class="tk-stop tk-clock24"') &&
      timekeepingCode.includes('class="tk-lunch"') &&
      timekeepingCode.includes('class="tk-equipment"') &&
      timekeepingCode.includes('class="tk-per-diem"'),
    'Core Foreman Crew Time rows must render every military-time control before enhancement or refresh.'
  );
  assert(
    !roleWorkspaceCode.includes("Enter each crew member's Regular and OT hours"),
    'Role workspace polish must not restore the obsolete Regular/OT Crew Time instructions.'
  );
  assert(
    expandedJsaCode.includes("load('leadership-my-time.js"),
    'GF, Superintendent, Admin, and Owner My Time must load with Timekeeping.'
  );
}

if (fs.existsSync('leadership-my-time.js')) {
  const leadershipMyTimeCode = fs.readFileSync('leadership-my-time.js', 'utf8');
  try {
    new Function(leadershipMyTimeCode);
  } catch (error) {
    failures.push('Leadership My Time JavaScript syntax error: ' + error.message);
  }
  assert(
    leadershipMyTimeCode.includes("rpc('upsert_my_leadership_time'") &&
      leadershipMyTimeCode.includes('Recent My Time'),
    'Leadership My Time must save through the guarded RPC and show recent entries.'
  );
}

if (fs.existsSync('jsa-signatures.js')) {
  const signatureCode = fs.readFileSync('jsa-signatures.js', 'utf8');
  assert(
    signatureCode.includes('setPointerCapture') &&
      signatureCode.includes("'touchmove'") &&
      signatureCode.includes('passive:false'),
    'JSA signature pads must capture drawing gestures without scrolling the page.'
  );
}

if (fs.existsSync('role-workspace-polish.js')) {
  const roleWorkspaceCode = fs.readFileSync('role-workspace-polish.js', 'utf8');
  try {
    new Function(roleWorkspaceCode);
  } catch (error) {
    failures.push('Role workspace JavaScript syntax error: ' + error.message);
  }
  assert(
    roleWorkspaceCode.includes('tilesNeedReordering'),
    'Role workspace must avoid continuously re-appending dashboard tiles.'
  );
  assert(
    roleWorkspaceCode.includes('observer?.disconnect()') &&
      roleWorkspaceCode.includes('finally{') &&
      roleWorkspaceCode.includes('observe();'),
    'Role workspace must not observe its own dashboard mutations.'
  );
}

const forbiddenSecrets = [
  ['Supabase service-role key reference', /service[_-]?role/i],
  ['OpenAI API key reference', /OPENAI_API_KEY|sk-proj-/],
  ['Supabase secret key', /sb_secret_/i]
];
for (const [label, pattern] of forbiddenSecrets) {
  assert(!pattern.test(html), label + ' found in public index.html.');
}

if (failures.length) {
  console.error('LineCrew Pro validation failed:');
  failures.forEach(failure => console.error('- ' + failure));
  process.exit(1);
}

console.log('LineCrew Pro validation passed.');
console.log('- JavaScript syntax is valid');
console.log('- Required application pages are present');
console.log('- Owner/Admin/Superintendent/GF/Foreman team wiring is present');
console.log('- Flexible JSA camera/viewer wiring is present');
console.log('- HTML ids are unique');
console.log('- No known server-side secret patterns are exposed');
