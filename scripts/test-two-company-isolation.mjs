#!/usr/bin/env node

import crypto from "node:crypto";

const required = [
  "SUPABASE_TEST_URL",
  "SUPABASE_TEST_ANON_KEY",
  "SUPABASE_TEST_SERVICE_ROLE_KEY",
  "SUPABASE_TEST_PROJECT_REF",
];

for (const name of required) {
  if (!process.env[name]) throw new Error(`Missing required environment variable: ${name}`);
}

if (process.env.LINECREW_ISOLATION_TEST_CONFIRM !== "DISPOSABLE_ONLY") {
  throw new Error(
    "Safety stop: set LINECREW_ISOLATION_TEST_CONFIRM=DISPOSABLE_ONLY only for a disposable Supabase test project.",
  );
}

const baseUrl = process.env.SUPABASE_TEST_URL.replace(/\/$/, "");
const projectRef = process.env.SUPABASE_TEST_PROJECT_REF.trim();
const host = new URL(baseUrl).hostname;

if (!host.startsWith(`${projectRef}.`)) {
  throw new Error(`Safety stop: SUPABASE_TEST_URL does not match SUPABASE_TEST_PROJECT_REF (${projectRef}).`);
}

if (process.env.SUPABASE_PRODUCTION_PROJECT_REF === projectRef) {
  throw new Error("Safety stop: the configured test project matches the production project reference.");
}

const anonKey = process.env.SUPABASE_TEST_ANON_KEY;
const serviceKey = process.env.SUPABASE_TEST_SERVICE_ROLE_KEY;
const runId = `isolation-${Date.now()}-${crypto.randomBytes(4).toString("hex")}`;
const password = `${crypto.randomBytes(18).toString("base64url")}Aa1!`;
const created = { users: [], companies: [], rows: [] };

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function isInactiveProfileDenial(result) {
  return (
    !result.ok &&
    [401, 403].includes(result.status) &&
    result.data?.code === "42501" &&
    result.data?.message === "LineCrew profile access is inactive."
  );
}

async function request(path, { method = "GET", token = serviceKey, apikey = serviceKey, body, prefer } = {}) {
  const response = await fetch(`${baseUrl}${path}`, {
    method,
    headers: {
      apikey,
      Authorization: `Bearer ${token}`,
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

async function serviceInsert(table, row) {
  const result = await request(`/rest/v1/${table}`, {
    method: "POST",
    body: row,
    prefer: "return=representation",
  });
  assert(result.ok, `Unable to seed ${table}: ${JSON.stringify(result.data)}`);
  const inserted = result.data[0];
  created.rows.push({ table, id: inserted.id });
  return inserted;
}

async function servicePatch(table, id, changes) {
  const result = await request(`/rest/v1/${table}?id=eq.${id}`, {
    method: "PATCH",
    body: changes,
    prefer: "return=representation",
  });
  assert(result.ok, `Unable to update ${table}: ${JSON.stringify(result.data)}`);
  return result.data;
}

async function createUser(label) {
  const email = `${runId}-${label}@example.invalid`;
  const result = await request("/auth/v1/admin/users", {
    method: "POST",
    body: { email, password, email_confirm: true, user_metadata: { isolation_test: runId } },
  });
  assert(result.ok, `Unable to create ${label} test user: ${JSON.stringify(result.data)}`);
  created.users.push(result.data.id);
  return { id: result.data.id, email };
}

async function signIn(email) {
  const result = await request("/auth/v1/token?grant_type=password", {
    method: "POST",
    token: anonKey,
    apikey: anonKey,
    body: { email, password },
  });
  assert(result.ok && result.data?.access_token, `Unable to sign in ${email}`);
  return result.data.access_token;
}

async function userRest(token, table, query = "", options = {}) {
  return request(`/rest/v1/${table}${query ? `?${query}` : ""}`, {
    ...options,
    token,
    apikey: anonKey,
  });
}

function selectColumnsFor(table) {
  return table === "companies" ? "id" : "id,company_id";
}

async function expectOwnRow(token, table, id) {
  const result = await userRest(token, table, `id=eq.${id}&select=${selectColumnsFor(table)}`);
  assert(result.ok, `Same-company ${table} read failed: ${JSON.stringify(result.data)}`);
  assert(result.data.length === 1 && result.data[0].id === id, `Same-company ${table} row was not visible.`);
}

async function expectForeignHidden(token, table, id) {
  const result = await userRest(token, table, `id=eq.${id}&select=${selectColumnsFor(table)}`);
  assert(result.ok, `Cross-company ${table} read returned an unexpected API error: ${JSON.stringify(result.data)}`);
  assert(Array.isArray(result.data) && result.data.length === 0, `SECURITY FAILURE: cross-company ${table} row was visible.`);
}

async function cleanup() {
  const tableOrder = ["daily_reports", "jobs", "price_books", "customers", "profiles", "companies"];
  for (const table of tableOrder) {
    const ids = created.rows.filter((row) => row.table === table).map((row) => row.id).reverse();
    for (const id of ids) {
      await request(`/rest/v1/${table}?id=eq.${id}`, { method: "DELETE", prefer: "return=minimal" });
    }
  }
  for (const id of created.users.reverse()) {
    await request(`/auth/v1/admin/users/${id}`, { method: "DELETE" });
  }
}

async function main() {
  console.log(`Starting guarded two-company isolation test (${runId}).`);
  const [userA, userB] = await Promise.all([createUser("company-a"), createUser("company-b")]);

  const companyA = await serviceInsert("companies", { name: `${runId} Company A`, created_by: userA.id });
  created.companies.push(companyA.id);
  const companyB = await serviceInsert("companies", { name: `${runId} Company B`, created_by: userB.id });
  created.companies.push(companyB.id);
  await serviceInsert("profiles", { id: userA.id, company_id: companyA.id, full_name: "Isolation Admin A", role: "admin" });
  await serviceInsert("profiles", { id: userB.id, company_id: companyB.id, full_name: "Isolation Admin B", role: "admin" });

  const customerA = await serviceInsert("customers", { company_id: companyA.id, name: `${runId} Customer A` });
  const customerB = await serviceInsert("customers", { company_id: companyB.id, name: `${runId} Customer B` });
  const priceBookA = await serviceInsert("price_books", { company_id: companyA.id, name: `${runId} Price Book A` });
  const priceBookB = await serviceInsert("price_books", { company_id: companyB.id, name: `${runId} Price Book B` });
  const jobA = await serviceInsert("jobs", { company_id: companyA.id, job_number: `${runId}-A`, job_name: "Isolation Job A", created_by: userA.id, price_book_id: priceBookA.id });
  const jobB = await serviceInsert("jobs", { company_id: companyB.id, job_number: `${runId}-B`, job_name: "Isolation Job B", created_by: userB.id, price_book_id: priceBookB.id });
  const reportA = await serviceInsert("daily_reports", { company_id: companyA.id, job_id: jobA.id, foreman_id: userA.id, report_date: new Date().toISOString().slice(0, 10), foreman_name: "Isolation Admin A" });
  const reportB = await serviceInsert("daily_reports", { company_id: companyB.id, job_id: jobB.id, foreman_id: userB.id, report_date: new Date().toISOString().slice(0, 10), foreman_name: "Isolation Admin B" });

  const [tokenA, tokenB] = await Promise.all([signIn(userA.email), signIn(userB.email)]);
  const resourcesA = { companies: companyA, profiles: { id: userA.id }, customers: customerA, price_books: priceBookA, jobs: jobA, daily_reports: reportA };
  const resourcesB = { companies: companyB, profiles: { id: userB.id }, customers: customerB, price_books: priceBookB, jobs: jobB, daily_reports: reportB };

  for (const [table, row] of Object.entries(resourcesA)) await expectOwnRow(tokenA, table, row.id);
  for (const [table, row] of Object.entries(resourcesB)) await expectOwnRow(tokenB, table, row.id);
  for (const [table, row] of Object.entries(resourcesB)) await expectForeignHidden(tokenA, table, row.id);
  for (const [table, row] of Object.entries(resourcesA)) await expectForeignHidden(tokenB, table, row.id);

  const ownInsert = await userRest(tokenA, "customers", "", {
    method: "POST",
    body: { company_id: companyA.id, name: `${runId} Authorized Insert` },
    prefer: "return=representation",
  });
  assert(ownInsert.ok && ownInsert.data.length === 1, "Authorized same-company customer insert failed.");
  created.rows.push({ table: "customers", id: ownInsert.data[0].id });

  const spoofInsert = await userRest(tokenA, "customers", "", {
    method: "POST",
    body: { company_id: companyB.id, name: `${runId} Spoofed Insert` },
    prefer: "return=representation",
  });
  assert(!spoofInsert.ok, "SECURITY FAILURE: user A inserted a customer into company B.");

  const crossUpdate = await userRest(tokenA, "customers", `id=eq.${customerB.id}`, {
    method: "PATCH",
    body: { notes: `${runId} cross-company update` },
    prefer: "return=representation",
  });
  assert(crossUpdate.ok && crossUpdate.data.length === 0, "SECURITY FAILURE: cross-company update affected a row.");

  const crossDelete = await userRest(tokenA, "jobs", `id=eq.${jobB.id}`, {
    method: "DELETE",
    prefer: "return=representation",
  });
  assert(crossDelete.ok && crossDelete.data.length === 0, "SECURITY FAILURE: cross-company delete affected a row.");
  const verifyJobB = await request(`/rest/v1/jobs?id=eq.${jobB.id}&select=id`);
  assert(verifyJobB.ok && verifyJobB.data.length === 1, "SECURITY FAILURE: foreign job no longer exists after delete attempt.");

  const deactivatedProfile = await servicePatch("profiles", userA.id, { active: false });
  assert(
    Array.isArray(deactivatedProfile) &&
      deactivatedProfile.length === 1 &&
      deactivatedProfile[0].active === false,
    `Test setup failed to suspend profile: ${JSON.stringify(deactivatedProfile)}`,
  );

  const inactiveGate = await userRest(tokenA, "rpc/current_user_has_active_profile", "", {
    method: "POST",
    body: {},
  });
  assert(
    (inactiveGate.ok && inactiveGate.data === false) || isInactiveProfileDenial(inactiveGate),
    `SECURITY FAILURE: active-profile gate remained open after suspension: ${JSON.stringify(inactiveGate.data)}`,
  );

  const inactiveTenant = await userRest(tokenA, "rpc/my_company_id", "", {
    method: "POST",
    body: {},
  });
  assert(
    (inactiveTenant.ok && inactiveTenant.data === null) || isInactiveProfileDenial(inactiveTenant),
    `SECURITY FAILURE: inactive profile still resolved tenant context: ${JSON.stringify(inactiveTenant.data)}`,
  );

  const inactiveRead = await userRest(tokenA, "customers", `id=eq.${customerA.id}&select=id`);
  assert(
    (inactiveRead.ok && Array.isArray(inactiveRead.data) && inactiveRead.data.length === 0) ||
      isInactiveProfileDenial(inactiveRead),
    `SECURITY FAILURE: inactive profile retained tenant access: ${JSON.stringify(inactiveRead.data)}`,
  );
  await servicePatch("profiles", userA.id, { active: true });

  console.log("PASS: same-company access works; cross-company reads and mutations are blocked; inactive profiles are locked out.");
}

try {
  await main();
} finally {
  await cleanup();
}
