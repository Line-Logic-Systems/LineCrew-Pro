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
  try {
    new Function(fs.readFileSync('expanded-jsa.js', 'utf8'));
  } catch (error) {
    failures.push('Expanded JSA JavaScript syntax error: ' + error.message);
  }
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
