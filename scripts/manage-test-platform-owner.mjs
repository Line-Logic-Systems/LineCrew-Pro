#!/usr/bin/env node

const required = [
  "SUPABASE_TEST_URL",
  "SUPABASE_TEST_SERVICE_ROLE_KEY",
  "SUPABASE_TEST_PROJECT_REF",
  "SUPABASE_PRODUCTION_PROJECT_REF",
  "PLATFORM_OWNER_EMAIL",
  "PLATFORM_OWNER_ACTION",
  "LINECREW_ISOLATION_TEST_CONFIRM",
];
for (const name of required) {
  if (!process.env[name]) throw new Error(`Missing required environment variable: ${name}`);
}

if (process.env.LINECREW_ISOLATION_TEST_CONFIRM !== "DISPOSABLE_ONLY") {
  throw new Error("Safety stop: test platform-owner management requires DISPOSABLE_ONLY confirmation.");
}

const baseUrl = process.env.SUPABASE_TEST_URL.replace(/\/$/, "");
const projectRef = process.env.SUPABASE_TEST_PROJECT_REF.trim();
const productionRef = process.env.SUPABASE_PRODUCTION_PROJECT_REF.trim();
const host = new URL(baseUrl).hostname;
if (!host.startsWith(`${projectRef}.`)) {
  throw new Error(`Safety stop: SUPABASE_TEST_URL does not match SUPABASE_TEST_PROJECT_REF (${projectRef}).`);
}
if (projectRef === productionRef) {
  throw new Error("Safety stop: the configured test project matches production.");
}

const email = process.env.PLATFORM_OWNER_EMAIL.trim().toLowerCase();
if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
  throw new Error("PLATFORM_OWNER_EMAIL is not a valid email address.");
}
const action = process.env.PLATFORM_OWNER_ACTION.trim().toLowerCase();
if (!['grant','revoke'].includes(action)) {
  throw new Error("PLATFORM_OWNER_ACTION must be grant or revoke.");
}

const serviceKey = process.env.SUPABASE_TEST_SERVICE_ROLE_KEY;

async function request(path, { method = "GET", body, prefer } = {}) {
  const response = await fetch(`${baseUrl}${path}`, {
    method,
    headers: {
      apikey: serviceKey,
      Authorization: `Bearer ${serviceKey}`,
      ...(body === undefined ? {} : { "Content-Type": "application/json" }),
      ...(prefer ? { Prefer: prefer } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  let data = null;
  if (text) {
    try { data = JSON.parse(text); } catch { data = text; }
  }
  return { ok: response.ok, status: response.status, data };
}

async function findUserByEmail() {
  for (let page = 1; page <= 20; page += 1) {
    const result = await request(`/auth/v1/admin/users?page=${page}&per_page=100`);
    if (!result.ok) throw new Error(`Unable to list test Auth users: ${JSON.stringify(result.data)}`);
    const users = Array.isArray(result.data?.users) ? result.data.users : [];
    const match = users.find(user => String(user.email || '').toLowerCase() === email);
    if (match) return match;
    if (users.length < 100) break;
  }
  throw new Error(`No Auth user with email ${email} exists in the configured test Supabase project.`);
}

const user = await findUserByEmail();

if (action === 'grant') {
  const result = await request('/rest/v1/platform_owners?on_conflict=user_id', {
    method: 'POST',
    body: { user_id: user.id },
    prefer: 'resolution=merge-duplicates,return=representation',
  });
  if (!result.ok) throw new Error(`Unable to grant test platform-owner access: ${JSON.stringify(result.data)}`);
} else {
  const result = await request(`/rest/v1/platform_owners?user_id=eq.${encodeURIComponent(user.id)}`, {
    method: 'DELETE',
    prefer: 'return=representation',
  });
  if (!result.ok) throw new Error(`Unable to revoke test platform-owner access: ${JSON.stringify(result.data)}`);
}

const verify = await request(`/rest/v1/platform_owners?user_id=eq.${encodeURIComponent(user.id)}&select=user_id`);
if (!verify.ok) throw new Error(`Unable to verify platform-owner state: ${JSON.stringify(verify.data)}`);
const granted = Array.isArray(verify.data) && verify.data.some(row => row.user_id === user.id);
if (action === 'grant' && !granted) throw new Error('Grant verification failed.');
if (action === 'revoke' && granted) throw new Error('Revoke verification failed.');

console.log(`PASS: ${action} test platform-owner access for ${email} in disposable project ${projectRef}.`);
