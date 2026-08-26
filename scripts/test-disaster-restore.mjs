#!/usr/bin/env node
import crypto from 'node:crypto';

const required = ['SUPABASE_TEST_URL', 'SUPABASE_TEST_ANON_KEY', 'SUPABASE_TEST_SERVICE_ROLE_KEY', 'SUPABASE_TEST_PROJECT_REF'];
for (const name of required) if (!process.env[name]) throw new Error(`Missing required environment variable: ${name}`);
if (process.env.LINECREW_RESTORE_TEST_CONFIRM !== 'DISPOSABLE_ONLY') {
  throw new Error('Safety stop: this drill requires LINECREW_RESTORE_TEST_CONFIRM=DISPOSABLE_ONLY.');
}

const baseUrl = process.env.SUPABASE_TEST_URL.replace(/\/$/, '');
const projectRef = process.env.SUPABASE_TEST_PROJECT_REF.trim();
if (!new URL(baseUrl).hostname.startsWith(`${projectRef}.`)) throw new Error('Safety stop: test URL and project reference do not match.');
if (projectRef === process.env.SUPABASE_PRODUCTION_PROJECT_REF) throw new Error('Safety stop: restore target is the production project.');

const anonKey = process.env.SUPABASE_TEST_ANON_KEY;
const serviceKey = process.env.SUPABASE_TEST_SERVICE_ROLE_KEY;
const runId = `restore-${Date.now()}-${crypto.randomBytes(4).toString('hex')}`;
const password = `${crypto.randomBytes(18).toString('base64url')}Aa1!`;
const created = { users: [], companies: [], objectPath: null };
const pdf = Buffer.from('%PDF-1.4\n% LineCrew disposable restore drill\n1 0 obj<</Type/Catalog>>endobj\n%%EOF\n');
const fileHash = crypto.createHash('sha256').update(pdf).digest('hex');

function assert(condition, message) { if (!condition) throw new Error(message); }
async function parse(response) {
  const text = await response.text();
  if (!text) return null;
  try { return JSON.parse(text); } catch { return text; }
}
async function request(path, { method = 'GET', token = serviceKey, apikey = serviceKey, body, prefer } = {}) {
  const response = await fetch(`${baseUrl}${path}`, {
    method,
    headers: {
      apikey, Authorization: `Bearer ${token}`,
      ...(body === undefined ? {} : { 'Content-Type': 'application/json' }),
      ...(prefer ? { Prefer: prefer } : {}),
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  return { ok: response.ok, status: response.status, data: await parse(response) };
}
async function insert(table, row) {
  const result = await request(`/rest/v1/${table}`, { method: 'POST', body: row, prefer: 'return=representation' });
  assert(result.ok && result.data?.length === 1, `Insert failed for ${table}: ${JSON.stringify(result.data)}`);
  return result.data[0];
}
async function update(table, query, row) {
  const result = await request(`/rest/v1/${table}?${query}`, { method: 'PATCH', body: row, prefer: 'return=representation' });
  assert(result.ok && result.data?.length === 1, `Update failed for ${table}: ${JSON.stringify(result.data)}`);
  return result.data[0];
}
async function createUser(label) {
  const email = `${runId}-${label}@example.invalid`;
  const result = await request('/auth/v1/admin/users', { method: 'POST', body: { email, password, email_confirm: true } });
  assert(result.ok, `Unable to create restore-test user: ${JSON.stringify(result.data)}`);
  created.users.push(result.data.id);
  return { id: result.data.id, email };
}
async function signIn(email) {
  const result = await request('/auth/v1/token?grant_type=password', {
    method: 'POST', token: anonKey, apikey: anonKey, body: { email, password },
  });
  assert(result.ok && result.data?.access_token, `Unable to sign in ${email}`);
  return result.data.access_token;
}
async function storageUpload(objectPath, bytes) {
  const encoded = objectPath.split('/').map(encodeURIComponent).join('/');
  const response = await fetch(`${baseUrl}/storage/v1/object/jsa-uploads/${encoded}`, {
    method: 'POST',
    headers: { apikey: serviceKey, Authorization: `Bearer ${serviceKey}`, 'Content-Type': 'application/pdf', 'x-upsert': 'true' },
    body: bytes,
  });
  assert(response.ok, `Storage upload failed: ${await response.text()}`);
}
async function storageDownload(objectPath, token, apikey) {
  const encoded = objectPath.split('/').map(encodeURIComponent).join('/');
  const response = await fetch(`${baseUrl}/storage/v1/object/authenticated/jsa-uploads/${encoded}`, {
    headers: { apikey, Authorization: `Bearer ${token}` },
  });
  return { ok: response.ok, status: response.status, bytes: response.ok ? Buffer.from(await response.arrayBuffer()) : null };
}
async function storageDelete(objectPath) {
  return request('/storage/v1/object/jsa-uploads', { method: 'DELETE', body: { prefixes: [objectPath] } });
}

async function cleanup() {
  if (created.objectPath) await storageDelete(created.objectPath);
  for (const id of created.companies.reverse()) await request(`/rest/v1/companies?id=eq.${id}`, { method: 'DELETE' });
  for (const id of created.users.reverse()) await request(`/auth/v1/admin/users/${id}`, { method: 'DELETE' });
}

async function main() {
  console.log(`Starting production-blocked restore drill ${runId}.`);
  const userA = await createUser('a');
  const userB = await createUser('b');
  const companyA = await insert('companies', { name: `${runId} Company A`, created_by: userA.id });
  const companyB = await insert('companies', { name: `${runId} Company B`, created_by: userB.id });
  created.companies.push(companyA.id, companyB.id);
  const subscriptionA = await update('company_subscriptions', `company_id=eq.${companyA.id}`, {
    plan_code: 'pilot', status: 'trialing',
    access_enabled: true, access_override: true, provider: 'manual',
    notes: 'Disposable recovery isolation test',
  });
  await update('company_subscriptions', `company_id=eq.${companyB.id}`, {
    plan_code: 'pilot', status: 'trialing',
    access_enabled: true, access_override: true, provider: 'manual',
    notes: 'Disposable recovery isolation test',
  });
  const profileA = await insert('profiles', { id: userA.id, company_id: companyA.id, full_name: 'Restore Foreman A', role: 'foreman', active: true });
  await insert('profiles', { id: userB.id, company_id: companyB.id, full_name: 'Restore Foreman B', role: 'foreman', active: true });
  const customerA = await insert('customers', { company_id: companyA.id, name: `${runId} Preserved Customer`, notes: 'must survive restore' });
  const priceBookA = await insert('price_books', { company_id: companyA.id, name: `${runId} Price Book` });
  const jobA = await insert('jobs', {
    company_id: companyA.id, job_number: `${runId}-JOB`, job_name: 'Restore Drill Job',
    created_by: userA.id, price_book_id: priceBookA.id,
  });
  const jsaA = await insert('daily_report_jsas', {
    company_id: companyA.id, daily_report_id: null, job_id: jobA.id, created_by: userA.id,
    work_date: new Date().toISOString().slice(0, 10), crew_name: 'Restore Drill Crew',
    job_briefing: 'Synthetic restore test', hazards: 'Synthetic restore test',
    controls: 'Synthetic restore test', ppe: 'Synthetic restore test',
    emergency_plan: 'Synthetic restore test', crew_members: 'Synthetic restore test', jsa_source: 'upload',
  });
  const snapshot = {
    company: { id: companyA.id, name: companyA.name, created_by: companyA.created_by },
    profile: { id: profileA.id, company_id: profileA.company_id, full_name: profileA.full_name, role: profileA.role, active: profileA.active },
    subscription: {
      id: subscriptionA.id, company_id: subscriptionA.company_id, plan_code: subscriptionA.plan_code,
      status: subscriptionA.status, access_enabled: subscriptionA.access_enabled,
      access_override: subscriptionA.access_override, provider: subscriptionA.provider, notes: subscriptionA.notes,
    },
    customer: { id: customerA.id, company_id: customerA.company_id, name: customerA.name, notes: customerA.notes },
    priceBook: { id: priceBookA.id, company_id: priceBookA.company_id, name: priceBookA.name },
    job: {
      id: jobA.id, company_id: jobA.company_id, job_number: jobA.job_number, job_name: jobA.job_name,
      created_by: jobA.created_by, price_book_id: jobA.price_book_id,
    },
    jsa: {
      id: jsaA.id, company_id: jsaA.company_id, daily_report_id: null, job_id: jsaA.job_id,
      created_by: jsaA.created_by, work_date: jsaA.work_date, crew_name: jsaA.crew_name,
      job_briefing: jsaA.job_briefing, hazards: jsaA.hazards, controls: jsaA.controls,
      ppe: jsaA.ppe, emergency_plan: jsaA.emergency_plan, crew_members: jsaA.crew_members,
      jsa_source: jsaA.jsa_source,
    },
  };
  created.objectPath = `${companyA.id}/${jsaA.id}/${runId}.pdf`;
  await storageUpload(created.objectPath, pdf);

  const deleteResult = await request(`/rest/v1/companies?id=eq.${companyA.id}`, { method: 'DELETE', prefer: 'return=representation' });
  assert(deleteResult.ok && deleteResult.data?.length === 1, 'Unable to simulate company-data loss.');
  const deleteObject = await storageDelete(created.objectPath);
  assert(deleteObject.ok, `Unable to simulate file loss: ${JSON.stringify(deleteObject.data)}`);

  await insert('companies', snapshot.company);
  const removeGeneratedSubscription = await request(
    `/rest/v1/company_subscriptions?company_id=eq.${companyA.id}`,
    { method: 'DELETE', prefer: 'return=representation' },
  );
  assert(
    removeGeneratedSubscription.ok && removeGeneratedSubscription.data?.length === 1,
    `Unable to replace automatically generated recovery subscription: ${JSON.stringify(removeGeneratedSubscription.data)}`,
  );
  const restoredSubscription = await insert('company_subscriptions', snapshot.subscription);
  await insert('profiles', snapshot.profile);
  const restoredCustomer = await insert('customers', snapshot.customer);
  await insert('price_books', snapshot.priceBook);
  await insert('jobs', snapshot.job);
  await insert('daily_report_jsas', snapshot.jsa);
  await storageUpload(created.objectPath, pdf);
  assert(restoredSubscription.access_override === true, 'Restored company-access subscription changed.');
  assert(restoredCustomer.notes === 'must survive restore', 'Restored customer content changed.');

  const [tokenA, tokenB] = await Promise.all([signIn(userA.email), signIn(userB.email)]);
  const own = await request(`/rest/v1/customers?id=eq.${customerA.id}&select=id,name,notes`, { token: tokenA, apikey: anonKey });
  const foreign = await request(`/rest/v1/customers?id=eq.${customerA.id}&select=id`, { token: tokenB, apikey: anonKey });
  assert(own.ok && own.data?.length === 1, `Restored company cannot read its own customer: status=${own.status} response=${JSON.stringify(own.data)}`);
  assert(foreign.ok && Array.isArray(foreign.data) && foreign.data.length === 0, 'SECURITY FAILURE: restored data crossed company boundaries.');

  const ownFile = await storageDownload(created.objectPath, tokenA, anonKey);
  const foreignFile = await storageDownload(created.objectPath, tokenB, anonKey);
  assert(ownFile.ok && crypto.createHash('sha256').update(ownFile.bytes).digest('hex') === fileHash, 'Restored file is missing or corrupted.');
  assert(!foreignFile.ok, 'SECURITY FAILURE: another company downloaded the restored file.');
  console.log('PASS: company rows and private file were deleted, restored, hash-verified, and remained tenant-isolated.');
}

try { await main(); } finally { await cleanup(); }
