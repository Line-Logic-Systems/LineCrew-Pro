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
if (!host.startsWith(`${projectRef}.`)) throw new Error(`Safety stop: SUPABASE_TEST_URL does not match SUPABASE_TEST_PROJECT_REF (${projectRef}).`);
if (process.env.SUPABASE_PRODUCTION_PROJECT_REF === projectRef) throw new Error("Safety stop: the configured test project matches production.");

const anonKey = process.env.SUPABASE_TEST_ANON_KEY;
const serviceKey = process.env.SUPABASE_TEST_SERVICE_ROLE_KEY;
const runId = `billing-isolation-${Date.now()}-${crypto.randomBytes(4).toString("hex")}`;
const password = `${crypto.randomBytes(18).toString("base64url")}Aa1!`;
const created = { users: [], companyIds: [] };

function assert(condition, message) { if (!condition) throw new Error(message); }

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
  if (text) { try { data = JSON.parse(text); } catch { data = text; } }
  return { ok: response.ok, status: response.status, data };
}

async function serviceInsert(table, row) {
  const result = await request(`/rest/v1/${table}`, { method: "POST", body: row, prefer: "return=representation" });
  assert(result.ok, `Unable to seed ${table}: ${JSON.stringify(result.data)}`);
  return result.data[0];
}
async function servicePatch(table, id, changes) {
  const result = await request(`/rest/v1/${table}?id=eq.${id}`, { method: "PATCH", body: changes, prefer: "return=representation" });
  assert(result.ok, `Unable to update ${table}: ${JSON.stringify(result.data)}`);
  return result.data;
}
async function serviceRpc(name, body = {}) {
  return request(`/rest/v1/rpc/${name}`, { method: "POST", body });
}

async function createUser(label) {
  const email = `${runId}-${label}@example.invalid`;
  const result = await request("/auth/v1/admin/users", { method: "POST", body: { email, password, email_confirm: true, user_metadata: { billing_isolation_test: runId } } });
  assert(result.ok, `Unable to create ${label}: ${JSON.stringify(result.data)}`);
  created.users.push(result.data.id);
  return { id: result.data.id, email };
}
async function signIn(email) {
  const result = await request("/auth/v1/token?grant_type=password", { method: "POST", token: anonKey, apikey: anonKey, body: { email, password } });
  assert(result.ok && result.data?.access_token, `Unable to sign in ${email}.`);
  return result.data.access_token;
}
function decodeBase32(value) {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  let bits = "";
  for (const character of value.toUpperCase().replace(/=+$/u, "")) {
    const index = alphabet.indexOf(character);
    assert(index >= 0, "Authenticator enrollment returned an invalid TOTP secret.");
    bits += index.toString(2).padStart(5, "0");
  }
  const bytes = [];
  for (let offset = 0; offset + 8 <= bits.length; offset += 8) {
    bytes.push(Number.parseInt(bits.slice(offset, offset + 8), 2));
  }
  return Buffer.from(bytes);
}
function totpCode(secret) {
  const counter = Math.floor(Date.now() / 30_000);
  const buffer = Buffer.alloc(8);
  buffer.writeBigUInt64BE(BigInt(counter));
  const digest = crypto.createHmac("sha1", decodeBase32(secret)).update(buffer).digest();
  const offset = digest[digest.length - 1] & 0x0f;
  const value = (digest.readUInt32BE(offset) & 0x7fffffff) % 1_000_000;
  return String(value).padStart(6, "0");
}
async function signInAtAal2(email) {
  const aal1Token = await signIn(email);
  const enrolled = await request("/auth/v1/factors", {
    method: "POST",
    token: aal1Token,
    apikey: anonKey,
    body: { factor_type: "totp", friendly_name: `${runId}-ci` },
  });
  assert(enrolled.ok && enrolled.data?.id && enrolled.data?.totp?.secret, `Unable to enroll MFA for ${email}: ${JSON.stringify(enrolled.data)}`);
  const challenged = await request(`/auth/v1/factors/${enrolled.data.id}/challenge`, {
    method: "POST",
    token: aal1Token,
    apikey: anonKey,
    body: {},
  });
  assert(challenged.ok && challenged.data?.id, `Unable to challenge MFA for ${email}: ${JSON.stringify(challenged.data)}`);
  const verified = await request(`/auth/v1/factors/${enrolled.data.id}/verify`, {
    method: "POST",
    token: aal1Token,
    apikey: anonKey,
    body: { challenge_id: challenged.data.id, code: totpCode(enrolled.data.totp.secret) },
  });
  assert(verified.ok && verified.data?.access_token, `Unable to verify MFA for ${email}: ${JSON.stringify(verified.data)}`);
  return verified.data.access_token;
}
async function userRest(token, table, query = "", options = {}) {
  return request(`/rest/v1/${table}${query ? `?${query}` : ""}`, { ...options, token, apikey: anonKey });
}
async function rpc(token, name, body = {}) {
  return request(`/rest/v1/rpc/${name}`, { method: "POST", token, apikey: anonKey, body });
}
function firstRow(data) { return Array.isArray(data) ? data[0] : data; }
function isoDateOffset(days) { const d = new Date(); d.setUTCDate(d.getUTCDate() + days); return d.toISOString().slice(0, 10); }

async function cleanup() {
  for (const companyId of created.companyIds) {
    await request(`/rest/v1/company_crew_usage_daily?company_id=eq.${companyId}`, { method: "DELETE" });
    await request(`/rest/v1/platform_owner_audit_events?company_id=eq.${companyId}`, { method: "DELETE" });
    await request(`/rest/v1/billing_events?company_id=eq.${companyId}`, { method: "DELETE" });
    await request(`/rest/v1/company_subscriptions?company_id=eq.${companyId}`, { method: "DELETE" });
  }
  for (const userId of created.users) {
    await request(`/rest/v1/platform_owners?user_id=eq.${userId}`, { method: "DELETE" });
    await request(`/rest/v1/profiles?id=eq.${userId}`, { method: "DELETE" });
  }
  for (const companyId of created.companyIds.reverse()) await request(`/rest/v1/companies?id=eq.${companyId}`, { method: "DELETE" });
  for (const userId of created.users.reverse()) await request(`/auth/v1/admin/users/${userId}`, { method: "DELETE" });
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
  await serviceInsert("company_subscriptions", { company_id: companyA.id, plan_code: "starter", monthly_price_cents: 49900, status: "active", access_enabled: true, provider: "manual", included_crew_limit: 5 });
  await serviceInsert("company_subscriptions", { company_id: companyB.id, plan_code: "business", monthly_price_cents: 74900, status: "active", access_enabled: true, provider: "manual", included_crew_limit: 10 });

  const [tokenA, tokenB] = await Promise.all([signInAtAal2(userA.email), signInAtAal2(userB.email)]);

  // These maintenance RPCs accept an explicit company UUID and must remain
  // service-role only. A company token must not be able to inspect or poison a
  // different company's rolling billing usage.
  const injectedDate = isoDateOffset(-20);
  const deniedCapture = await rpc(tokenA, "capture_company_crew_usage", {
    p_company_id: companyB.id,
    p_usage_date: injectedDate,
  });
  assert(!deniedCapture.ok, "SECURITY FAILURE: company A captured company B crew usage.");
  const deniedRecalc = await rpc(tokenA, "recalculate_company_crew_overage", {
    p_company_id: companyB.id,
  });
  assert(!deniedRecalc.ok, "SECURITY FAILURE: company A recalculated company B billing state.");
  const deniedCaptureAll = await rpc(tokenA, "capture_all_company_crew_usage", {
    p_usage_date: injectedDate,
  });
  assert(!deniedCaptureAll.ok, "SECURITY FAILURE: a company token ran the platform-wide usage job.");
  const injectedUsage = await request(`/rest/v1/company_crew_usage_daily?company_id=eq.${companyB.id}&usage_date=eq.${injectedDate}&select=company_id`);
  assert(injectedUsage.ok && injectedUsage.data.length === 0, "SECURITY FAILURE: denied crew-usage call still injected a victim usage row.");

  const ownerA = await rpc(tokenA, "is_platform_owner");
  const ownerB = await rpc(tokenB, "is_platform_owner");
  assert(ownerA.ok && ownerA.data === false, "SECURITY FAILURE: ordinary company Admin A became a platform owner.");
  assert(ownerB.ok && ownerB.data === false, "SECURITY FAILURE: ordinary company Admin B became a platform owner.");
  const deniedDashboard = await rpc(tokenA, "platform_owner_company_dashboard");
  assert(!deniedDashboard.ok, "SECURITY FAILURE: ordinary company Admin opened the platform owner dashboard.");

  const directSubscriptionRead = await userRest(tokenA, "company_subscriptions", "select=company_id,plan_code");
  assert(!directSubscriptionRead.ok, "SECURITY FAILURE: authenticated browser user directly read company_subscriptions.");
  const directCrewUsageRead = await userRest(tokenA, "company_crew_usage_daily", "select=company_id,usage_date");
  assert(!directCrewUsageRead.ok, "SECURITY FAILURE: authenticated browser user directly read company_crew_usage_daily.");
  const directBillingEventRead = await userRest(tokenA, "billing_events", "select=id");
  assert(!directBillingEventRead.ok, "SECURITY FAILURE: authenticated browser user directly read billing_events.");

  const selfGrant = await userRest(tokenA, "platform_owners", "", { method: "POST", body: { user_id: userA.id }, prefer: "return=representation" });
  assert(!selfGrant.ok, "SECURITY FAILURE: company Admin self-granted platform-owner access.");

  const summaryA = await rpc(tokenA, "my_company_billing_summary");
  const summaryB = await rpc(tokenB, "my_company_billing_summary");
  assert(summaryA.ok, `Company A billing summary failed: ${JSON.stringify(summaryA.data)}`);
  assert(summaryB.ok, `Company B billing summary failed: ${JSON.stringify(summaryB.data)}`);
  assert(firstRow(summaryA.data)?.plan_code === "starter", "Company A did not receive its own billing plan.");
  assert(firstRow(summaryA.data)?.monthly_price_cents === 49900, "Company A billing amount is incorrect.");
  assert(firstRow(summaryB.data)?.plan_code === "business", "Company B did not receive its own billing plan.");
  assert(firstRow(summaryB.data)?.monthly_price_cents === 74900, "Company B billing amount is incorrect.");

  // A Starter company may retain any number of inactive historical crews,
  // but the database must reject a sixth active crew even through service/API
  // writes. This proves the limit is not only a browser warning.
  for (let index = 1; index <= 5; index += 1) {
    await serviceInsert("crews", { company_id: companyA.id, name: `${runId} Active Crew ${index}`, active: true });
  }
  const sixthCrew = await request("/rest/v1/crews", {
    method: "POST",
    body: { company_id: companyA.id, name: `${runId} Active Crew 6`, active: true },
    prefer: "return=representation",
  });
  assert(!sixthCrew.ok, "BILLING FAILURE: Starter company activated a sixth crew.");
  assert(String(sixthCrew.data?.message || "").includes("up to 5 active crews"), "Crew-limit rejection did not explain the Starter limit.");
  await serviceInsert("crews", { company_id: companyA.id, name: `${runId} Historical Crew`, active: false });

  const accessA = await rpc(tokenA, "my_company_subscription_access");
  const accessB = await rpc(tokenB, "my_company_subscription_access");
  assert(firstRow(accessA.data)?.company_id === companyA.id, "Company A subscription-access RPC crossed tenants.");
  assert(firstRow(accessB.data)?.company_id === companyB.id, "Company B subscription-access RPC crossed tenants.");

  await serviceInsert("platform_owners", { user_id: userA.id });
  const explicitOwnerA = await rpc(tokenA, "is_platform_owner");
  assert(explicitOwnerA.ok && explicitOwnerA.data === true, "Explicit test platform-owner allowlist did not work.");
  const ownerDashboard = await rpc(tokenA, "platform_owner_company_dashboard");
  assert(ownerDashboard.ok && Array.isArray(ownerDashboard.data), `Allowlisted owner dashboard failed: ${JSON.stringify(ownerDashboard.data)}`);
  assert(ownerDashboard.data.find(row => row.company_id === companyA.id)?.plan_code === "starter", "Owner dashboard did not report company A correctly.");
  assert(ownerDashboard.data.find(row => row.company_id === companyB.id)?.plan_code === "business", "Owner dashboard did not report company B correctly.");

  const ownerUpdateB = await rpc(tokenA, "platform_owner_set_subscription", {
    p_company_id: companyB.id,
    p_plan_code: "pro",
    p_monthly_price_cents: 1,
    p_status: "active",
    p_access_override: false,
    p_trial_ends_at: null,
    p_notes: `${runId} owner test`,
  });
  assert(ownerUpdateB.ok, `Allowlisted owner could not update company B: ${JSON.stringify(ownerUpdateB.data)}`);
  const updatedB = await rpc(tokenB, "my_company_billing_summary");
  const unchangedA = await rpc(tokenA, "my_company_billing_summary");
  assert(firstRow(updatedB.data)?.plan_code === "pro", "Owner update did not reach the selected company.");
  assert(firstRow(updatedB.data)?.monthly_price_cents === 119900, "Server did not enforce approved Pro list price.");
  assert(firstRow(updatedB.data)?.access_enabled === false, "Owner force-block override was not reflected in effective access.");
  assert(firstRow(unchangedA.data)?.plan_code === "starter", "SECURITY FAILURE: owner update to company B changed company A.");

  const audit = await request(`/rest/v1/platform_owner_audit_events?company_id=eq.${companyB.id}&action=eq.subscription_settings_updated&select=id`);
  assert(audit.ok && audit.data.length >= 1, "Platform owner subscription change did not create an audit event.");

  // Anti-gaming tier test: five over-limit days, a gap, then day six remains grace;
  // day seven requires upgrade. Gaps/removal do not reset the rolling 30-day total.
  for (const offset of [-10, -9, -8, -7, -6, -3]) {
    await serviceInsert("company_crew_usage_daily", { company_id: companyA.id, usage_date: isoDateOffset(offset), peak_active_crews: 6, storm_crews: 0, peak_billable_crews: 6 });
  }
  let recalc = await serviceRpc("recalculate_company_crew_overage", { p_company_id: companyA.id });
  assert(recalc.ok, `Crew overage recalc failed: ${JSON.stringify(recalc.data)}`);
  assert(firstRow(recalc.data)?.rolling_overage_crew_days === 6, "Six rolling overage crew-days were not counted correctly.");
  assert(firstRow(recalc.data)?.overage_status === "grace", "Six rolling overage crew-days should still be in grace.");

  await serviceInsert("company_crew_usage_daily", { company_id: companyA.id, usage_date: isoDateOffset(-2), peak_active_crews: 6, storm_crews: 0, peak_billable_crews: 6 });
  recalc = await serviceRpc("recalculate_company_crew_overage", { p_company_id: companyA.id });
  assert(recalc.ok, `Crew overage recalc after seventh crew-day failed: ${JSON.stringify(recalc.data)}`);
  assert(firstRow(recalc.data)?.rolling_overage_crew_days === 7, "Seventh rolling overage crew-day was not retained after an off-gap.");
  assert(firstRow(recalc.data)?.overage_status === "upgrade_required", "Seventh rolling overage crew-day should require an upgrade.");
  assert(firstRow(recalc.data)?.recommended_plan === "linecrew", "Legacy overage should recommend the licensed-crew plan.");

  const summaryAfterOverage = await rpc(tokenA, "my_company_billing_summary");
  assert(firstRow(summaryAfterOverage.data)?.crew_overage_status === "upgrade_required", "Company Admin billing did not expose crew tier upgrade status.");
  assert(firstRow(summaryAfterOverage.data)?.recommended_plan_code === "linecrew", "Company Admin billing did not expose the licensed-crew plan recommendation.");

  await servicePatch("profiles", userB.id, { role: "foreman" });
  const foremanBilling = await rpc(tokenB, "my_company_billing_summary");
  assert(!foremanBilling.ok, "SECURITY FAILURE: Foreman accessed company Admin billing summary.");
  const foremanAccess = await rpc(tokenB, "my_company_subscription_access");
  assert(!foremanAccess.ok, "SECURITY FAILURE: force-blocked company Foreman retained application access.");

  await request(`/rest/v1/platform_owners?user_id=eq.${userA.id}`, { method: "DELETE" });
  const removedOwner = await rpc(tokenA, "is_platform_owner");
  assert(removedOwner.ok && removedOwner.data === false, "Removed platform owner retained owner authorization.");
  const dashboardAfterRemoval = await rpc(tokenA, "platform_owner_company_dashboard");
  assert(!dashboardAfterRemoval.ok, "SECURITY FAILURE: removed platform owner retained dashboard access.");

  console.log("PASS: billing tables stay browser-private; tenant billing is isolated; approved list pricing and active crew caps are server-enforced; inactive crew history is preserved; six rolling overage crew-days are allowed while the seventh survives crew cycling and requires upgrade; Foremen cannot open Admin billing; platform-owner power requires explicit allowlisting.");
}

try { await main(); } finally { await cleanup(); }
