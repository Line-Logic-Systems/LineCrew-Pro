import { readFileSync } from 'node:fs';

const manifestUrl = new URL('./approved-rpc-columns.json', import.meta.url);
const approved = JSON.parse(readFileSync(manifestUrl, 'utf8'));
const baseUrl = process.env.LINECREW_TEST_SUPABASE_URL;
const anonKey = process.env.LINECREW_TEST_ANON_KEY;
const email = process.env.LINECREW_TEST_UTILITY_EMAIL;
const password = process.env.LINECREW_TEST_UTILITY_PASSWORD;

if (![baseUrl, anonKey, email, password].every(Boolean)) {
  throw new Error('Test URL, anon key, and utility email/password environment variables are required.');
}

const authResponse = await fetch(`${baseUrl}/auth/v1/token?grant_type=password`, {
  method: 'POST',
  headers: { apikey: anonKey, 'content-type': 'application/json' },
  body: JSON.stringify({ email, password })
});
if (!authResponse.ok) throw new Error(`Utility sign-in failed (${authResponse.status}).`);
const { access_token: accessToken } = await authResponse.json();

async function rpc(name, body = {}) {
  const response = await fetch(`${baseUrl}/rest/v1/rpc/${name}`, {
    method: 'POST',
    headers: {
      apikey: anonKey,
      authorization: `Bearer ${accessToken}`,
      'content-type': 'application/json'
    },
    body: JSON.stringify(body)
  });
  const payload = await response.json();
  if (!response.ok) throw new Error(`${name} failed (${response.status}): ${JSON.stringify(payload)}`);
  return payload;
}

function assertKeys(functionName, row) {
  const actual = Object.keys(row).sort();
  const expected = [...approved[functionName]].sort();
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${functionName} runtime keys mismatch\nexpected ${JSON.stringify(expected)}\nactual   ${JSON.stringify(actual)}`);
  }
}

const me = await rpc('utility_me');
if (!Array.isArray(me) || me.length !== 1) throw new Error('utility_me must return exactly one row.');
assertKeys('utility_me', me[0]);

const jobs = await rpc('utility_list_jobs');
if (!Array.isArray(jobs) || jobs.length === 0) {
  throw new Error('Positive control failed: utility_list_jobs returned no jobs.');
}
for (const job of jobs) assertKeys('utility_list_jobs', job);

const progress = await rpc('utility_get_job_progress', { p_job_id: jobs[0].job_id });
if (!Array.isArray(progress) || progress.length === 0) {
  throw new Error('Positive control failed: selected shared job returned no progress rows.');
}
for (const row of progress) assertKeys('utility_get_job_progress', row);

console.log(`Runtime response keys match ${manifestUrl.pathname}.`);
