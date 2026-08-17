import fs from 'node:fs';

const html = fs.readFileSync('index.html', 'utf8');
const failures = [];
const assert = (condition, message) => {
  if (!condition) failures.push(message);
};

assert(html.includes('<!DOCTYPE html>') || html.includes('<!doctype html>'), 'Missing HTML doctype.');
assert(html.includes('/* LINECREW PRO SUPABASE */'), 'Missing main application script marker.');
assert(html.includes('id="loginPage"'), 'Missing login page.');
assert(html.includes('id="dashboardPage"'), 'Missing dashboard page.');
assert(html.includes('id="productionPage"'), 'Missing production page.');
assert(html.includes('id="jobsPage"'), 'Missing jobs page.');
assert(html.includes('id="priceBooksPage"'), 'Missing Price Books page.');
assert(html.includes('id="teamPage"'), 'Missing Team page.');
assert(html.includes('id="safetyPage"'), 'Missing Safety/JSA page.');

const ids = [...html.matchAll(/\sid=["']([^"']+)["']/g)].map(match => match[1]);
const duplicateIds = [...new Set(ids.filter((id, index) => ids.indexOf(id) !== index))];
assert(duplicateIds.length === 0, 'Duplicate HTML ids: ' + duplicateIds.join(', '));

const scriptStart = html.indexOf('/* LINECREW PRO SUPABASE */');
const scriptEnd = html.lastIndexOf('</script>');
if (scriptStart >= 0 && scriptEnd > scriptStart) {
  const applicationCode = html.slice(scriptStart, scriptEnd);
  try {
    new Function(applicationCode);
  } catch (error) {
    failures.push('Application JavaScript syntax error: ' + error.message);
  }
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
console.log('- HTML ids are unique');
console.log('- No known server-side secret patterns are exposed');
