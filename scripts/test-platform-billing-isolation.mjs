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
  throw new Error("Safety stop: platform billing isolation tests require DISPOSABLE_ONLY confirmation.");
}

const baseUrl = process.env.SUPABASE_TEST_URL.replace(/\/$/, "");
const projectRef = process.env.SUPABASE_TEST_PROJECT_REF.trim();
const host = new URL(baseUrl).hostname;
if (!host.startsWith(`${projectRef}.`)) {
  throw new Error(`Safety stop: SUPABASE_TEST_URL does not match SUPABASE_TEST_PROJECT_REF (${projectRef}).`);
}
if (process.env.SUPABASE_PRODUCTION_PROJECT_REF === projectRef) {
  throw new Error("Safety stop: the configured test project matches production.");
}

const anonKey = process.env.SUPABASE_TEST_ANON_KEY;
const serviceKey = process.env.SUPABASE_TEST_SERVICE_ROLE_KEY;
const runId = `billing-isolation-${Date.now()}-${crypto.randomBytes(4).toString("hex")}`;
const password = `${crypto.randomBytes(18).toString("base64url")}Aa1!`;
const created = { users: [], companyIds: [] };

function assert(condition, message) {
  if (!condition) throw new Error(message);
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
  return result.data[0];
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
    body: { email, password, email_confirm: true, user_metadata: { billing_isolation_test: runId } },
  });
  assert(result.ok, `Unable to create ${label}: ${JSON.stringify(result.data)}`);
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
  assert(result.ok && result.data?.access_token, `Unable to sign in ${email}.`);
  return result.data.access_token;
}

async function userRest(token, table, query = "", options = {}) {
  return request(`/rest/v1/${table}${query ? `?${query}` : ""}`, {
    ...options,
    token,
    apikey: anonKey,
  });
}

async function rpc(token, name, body = {}) {
  return request(`/rest/v1/rpc/${name}`, {
    method: "POST",
    token,
    apikey: anonKey,
    body,
  });
}

function firstRow(data) {
  return Array.isArray(data) ? data[0] : data;
}

async function cleanup() {
  for (const companyId of created.companyIds) {
    await request(`/rest/v1/platform_owner_audit_events?company_id=eq.${companyId}`, { method: "DELETE" });
    await request(`/rest/v1/billing_events?company_id=eq.${companyId}`, { method: "DELETE" });
    await request(`/rest/v1/company_subscriptions?company_id=eq.${companyId}`, { method: "DELETE" });
  }
  for (const userId of created.users) {
    await request(`/rest/v1/platform_owners?user_id=eq.${userId}`, { method: "DELETE" });
    await request(`/rest/v1/profiles?id=eq.${userId}`, { method: "DELETE" });
  }
  for (const companyId of created.companyIds.reverse()) {
    await request(`/rest/v1/companies?id=eq.${companyId}`, { method: "DELETE" });
  }
  for (const userId of created.users.reverse()) {
    await request(`/auth/v1/admin/users/${userId}`, { method: "DELETE" });
  }
}

async function main() {
  console.log(`Starting guarded platform billing isolation test (${runId}).`);

  const [userA, userB] = await Promise.all([createUser("company-a"), createUser("company-b")]);
  const companyA = await serviceInsert("companies", { name: `${runId} Company A`, created_by: userA.id });
  const companyB = await serviceInsert("companies", { name: `${runId} Company B`, created_by: userB.id });
  created.companyIds.push(companyA.id, companyB.id);

  await serviceInsert("profiles", { id: userA.id, company_id: companyA.id, full_name: "Billing Admin A", role: "admin", active: true });
  await serviceInsert("profiles", { id: userB.id, company_id: companyB.id, full_name: "Billing Admin B", role: "admin", active: true });

  await request(`/rest/v1/company_subscriptions?company_id=eq.${companyA.id}`, { method: "DELETE" });
  await request(`/rest/v1/company_subscriptions?company_id=eq.${companyB.id}`, { method: "DELETE" });
  await serviceInsert("company_subscriptions", {
    company_id: companyA.id,
    plan_code: "billing-test-a",
    monthly_price_cents: 11100,
    status: "active",
    access_enabled: true,
    provider: "manual",
  });
  await serviceInsert("company_subscriptions", {
    company_id: companyB.id,
    plan_code: "billing-test-b",
    monthly_price_cents: 22200,
    status: "active",
    access_enabled: true,
    provider: "manual",
  });

  const [tokenA, tokenB] = await Promise.all([signIn(userA.email), signIn(userB.email)]);

  const ownerA = await rpc(tokenA, "is_platform_owner");
  const ownerB = await rpc(tokenB, "is_platform_owner");
  assert(ownerA.ok && ownerA.data === false, "SECURITY FAILURE: ordinary company Admin A became a platform owner.");
  assert(ownerB.ok && ownerB.data === false, "SECURITY FAILURE: ordinary company Admin B became a platform owner.");

  const deniedDashboard = await rpc(tokenA, "platform_owner_company_dashboard");
  assert(!deniedDashboard.ok, "SECURITY FAILURE: ordinary company Admin opened the platform owner dashboard.");

  const directSubscriptionRead = await userRest(tokenA, "company_subscriptions", "select=company_id,plan_code");
  assert(!directSubscriptionRead.ok, "SECURITY FAILURE: authenticated browser user directly read company_subscriptions.");
  const directBillingEventRead = await userRest(tokenA, "billing_events", "select=id");
  assert(!directBillingEventRead.ok, "SECURITY FAILURE: authenticated browser user directly read billing_events.");

  const selfGrant = await userRest(tokenA, "platform_owners", "", {
    method: "POST",
    body: { user_id: userA.id },
    prefer: "return=representation",
  });
  assert(!selfGrant.ok, "SECURITY FAILURE: company Admin self-granted platform-owner access.");

  const summaryA = await rpc(tokenA, "my_company_billing_summary");
  const summaryB = await rpc(tokenB, "my_company_billing_summary");
  assert(summaryA.ok, `Company A billing summary failed: ${JSON.stringify(summaryA.data)}`);
  assert(summaryB.ok, `Company B billing summary failed: ${JSON.stringify(summaryB.data)}`);
  assert(firstRow(summaryA.data)?.plan_code === "billing-test-a", "Company A did not receive its own billing plan.");
  assert(firstRow(summaryA.data)?.monthly_price_cents === 11100, "Company A billing amount is incorrect.");
  assert(firstRow(summaryB.data)?.plan_code === "billing-test-b", "Company B did not receive its own billing plan.");
  assert(firstRow(summaryB.data)?.monthly_price_cents === 22200, "Company B billing amount is incorrect.");

  const accessA = await rpc(tokenA, "my_company_subscription_access");
  const accessB = await rpc(tokenB, "my_company_subscription_access");
  assert(firstRow(accessA.data)?.company_id === companyA.id, "Company A subscription-access RPC crossed tenants.");
  assert(firstRow(accessB.data)?.company_id === companyB.id, "Company B subscription-access RPC crossed tenants.");

  await serviceInsert("platform_owners", { user_id: userA.id });
  const explicitOwnerA = await rpc(tokenA, "is_platform_owner");
  assert(explicitOwnerA.ok && explicitOwnerA.data === true, "Explicit test platform-owner allowlist did not work.");

  const ownerDashboard = await rpc(tokenA, "platform_owner_company_dashboard");
  assert(ownerDashboard.ok && Array.isArray(ownerDashboard.data), `Allowlisted owner dashboard failed: ${JSON.stringify(ownerDashboard.data)}`);
  const dashboardA = ownerDashboard.data.find(row => row.company_id === companyA.id);
  const dashboardB = ownerDashboard.data.find(row => row.company_id === companyB.id);
  assert(dashboardA?.plan_code === "billing-test-a", "Owner dashboard did not report company A correctly.");
  assert(dashboardB?.plan_code === "billing-test-b", "Owner dashboard did not report company B correctly.");

  const ownerUpdateB = await rpc(tokenA, "platform_owner_set_subscription", {
    p_company_id: companyB.id,
    p_plan_code: "billing-test-b-updated",
    p_monthly_price_cents: 33300,
    p_status: "active",
    p_access_override: false,
    p_trial_ends_at: null,
    p_notes: `${runId} owner test`,
  });
  assert(ownerUpdateB.ok, `Allowlisted owner could not update company B: ${JSON.stringify(ownerUpdateB.data)}`);

  const updatedB = await rpc(tokenB, "my_company_billing_summary");
  const unchangedA = await rpc(tokenA, "my_company_billing_summary");
  assert(firstRow(updatedB.data)?.plan_code === "billing-test-b-updated", "Owner update did not reach the selected company.");
  assert(firstRow(updatedB.data)?.monthly_price_cents === 33300, "Owner update did not save selected company price.");
  assert(firstRow(updatedB.data)?.access_enabled === false, "Owner force-block override was not reflected in effective access.");
  assert(firstRow(unchangedA.data)?.plan_code === "billing-test-a", "SECURITY FAILURE: owner update to company B changed company A.");

  const audit = await request(`/rest/v1/platform_owner_audit_events?company_id=eq.${companyB.id}&action=eq.subscription_settings_updated&select=id`);
  assert(audit.ok && audit.data.length >= 1, "Platform owner subscription change did not create an audit event.");

  await servicePatch("profiles", userB.id, { role: "foreman" });
  const foremanBilling = await rpc(tokenB, "my_company_billing_summary");
  assert(!foremanBilling.ok, "SECURITY FAILURE: Foreman accessed company Admin billing summary.");
  const foremanAccess = await rpc(tokenB, "my_company_subscription_access");
  assert(foremanAccess.ok && firstRow(foremanAccess.data)?.company_id === companyB.id, "Active Foreman could not receive safe own-company access state.");

  await request(`/rest/v1/platform_owners?user_id=eq.${userA.id}`, { method: "DELETE" });
  const removedOwner = await rpc(tokenA, "is_platform_owner");
  assert(removedOwner.ok && removedOwner.data === false, "Removed platform owner retained owner authorization.");
  const dashboardAfterRemoval = await rpc(tokenA, "platform_owner_company_dashboard");
  assert(!dashboardAfterRemoval.ok, "SECURITY FAILURE: removed platform owner retained dashboard access.");

  console.log("PASS: billing tables are browser-private; company billing summaries stay tenant-scoped; Foremen cannot open Admin billing; platform-owner power requires explicit allowlisting and is removed immediately when the allowlist row is deleted.");
}

try {
  await main();
} finally {
  await cleanup();
}
