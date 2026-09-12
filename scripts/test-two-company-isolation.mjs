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
  for (const id of created.rows.filter((row) => row.table === "daily_reports").map((row) => row.id)) {
    await request(`/rest/v1/daily_reports?id=eq.${id}`, {
      method: "PATCH",
      body: { status: "rejected" },
      prefer: "return=minimal",
    });
  }
  // Entries created server-side by save_daily_report_crew_time and the
  // leadership RPCs are not in `created.rows`, and the daily_reports FK is
  // ON DELETE SET NULL rather than CASCADE, so sweep them by employee before
  // the id-based pass or the timekeeping_employees delete hits an FK.
  for (const employeeId of created.rows.filter((row) => row.table === "timekeeping_employees").map((row) => row.id)) {
    await request(`/rest/v1/timekeeping_entries?employee_id=eq.${employeeId}`, { method: "DELETE", prefer: "return=minimal" });
  }
  const tableOrder = [
    "timekeeping_entries",
    "timekeeping_employees",
    "storm_mode_assignments",
    "job_package_authorized_units",
    "job_package_work_points",
    "job_packages",
    "price_book_items",
    "daily_reports",
    "jobs",
    "contracts",
    "price_books",
    "customers",
    "profiles",
    "companies",
  ];
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
  const [userA, userB, managerA] = await Promise.all([createUser("company-a"), createUser("company-b"), createUser("manager-a")]);

  const companyA = await serviceInsert("companies", { name: `${runId} Company A`, created_by: userA.id });
  created.companies.push(companyA.id);
  const companyB = await serviceInsert("companies", { name: `${runId} Company B`, created_by: userB.id });
  created.companies.push(companyB.id);
  await serviceInsert("profiles", { id: userA.id, company_id: companyA.id, full_name: "Isolation Admin A", role: "admin" });
  await serviceInsert("profiles", { id: userB.id, company_id: companyB.id, full_name: "Isolation Admin B", role: "admin" });
  await serviceInsert("profiles", { id: managerA.id, company_id: companyA.id, full_name: "Isolation Manager A", role: "manager" });

  const customerA = await serviceInsert("customers", { company_id: companyA.id, name: `${runId} Customer A` });
  const customerB = await serviceInsert("customers", { company_id: companyB.id, name: `${runId} Customer B` });
  const priceBookA = await serviceInsert("price_books", { company_id: companyA.id, name: `${runId} Price Book A` });
  const priceBookB = await serviceInsert("price_books", { company_id: companyB.id, name: `${runId} Price Book B` });
  const priceBookItemA = await serviceInsert("price_book_items", { company_id: companyA.id, price_book_id: priceBookA.id, item_code: `${runId}-UNIT-A`, item_name: "Isolation Unit A" });
  const priceBookItemB = await serviceInsert("price_book_items", { company_id: companyB.id, price_book_id: priceBookB.id, item_code: `${runId}-UNIT-B`, item_name: "Isolation Unit B" });
  const jobA = await serviceInsert("jobs", { company_id: companyA.id, job_number: `${runId}-A`, job_name: "Isolation Job A", created_by: userA.id, price_book_id: priceBookA.id });
  const jobB = await serviceInsert("jobs", { company_id: companyB.id, job_number: `${runId}-B`, job_name: "Isolation Job B", created_by: userB.id, price_book_id: priceBookB.id });
  const contractA = await serviceInsert("contracts", { company_id: companyA.id, customer_id: customerA.id, contract_name: "Isolation Contract A" });
  const contractB = await serviceInsert("contracts", { company_id: companyB.id, customer_id: customerB.id, contract_name: "Isolation Contract B" });
  const priorPackageA = await serviceInsert("job_packages", { company_id: companyA.id, job_id: jobA.id, contract_id: contractA.id, package_name: "Isolation Package A revision 1", created_by: userA.id });
  const currentPackageA = await serviceInsert("job_packages", { company_id: companyA.id, job_id: jobA.id, contract_id: contractA.id, package_name: "Isolation Package A revision 2", created_by: userA.id });
  await servicePatch("job_packages", currentPackageA.id, { supersedes_package_id: priorPackageA.id });
  const packageB = await serviceInsert("job_packages", { company_id: companyB.id, job_id: jobB.id, contract_id: contractB.id, package_name: "Isolation Package B", created_by: userB.id });
  const priorWorkPointA = await serviceInsert("job_package_work_points", { company_id: companyA.id, job_package_id: priorPackageA.id, job_id: jobA.id, work_point_code: "WP-1", created_by: userA.id });
  const currentWorkPointA = await serviceInsert("job_package_work_points", { company_id: companyA.id, job_package_id: currentPackageA.id, job_id: jobA.id, work_point_code: "WP-1", created_by: userA.id });
  const workPointB = await serviceInsert("job_package_work_points", { company_id: companyB.id, job_package_id: packageB.id, job_id: jobB.id, work_point_code: "PRIVATE-WP-B", created_by: userB.id });
  await serviceInsert("job_package_authorized_units", { company_id: companyA.id, job_package_id: priorPackageA.id, work_point_id: priorWorkPointA.id, price_book_item_id: priceBookItemA.id, unit_code: "UNIT-A", authorized_install_quantity: 1, created_by: userA.id });
  await serviceInsert("job_package_authorized_units", { company_id: companyA.id, job_package_id: currentPackageA.id, work_point_id: currentWorkPointA.id, price_book_item_id: priceBookItemA.id, unit_code: "UNIT-A", authorized_install_quantity: 2, created_by: userA.id });
  await serviceInsert("job_package_authorized_units", { company_id: companyB.id, job_package_id: packageB.id, work_point_id: workPointB.id, price_book_item_id: priceBookItemB.id, unit_code: "PRIVATE-UNIT-B", authorized_install_quantity: 99, created_by: userB.id });
  const reportA = await serviceInsert("daily_reports", { company_id: companyA.id, job_id: jobA.id, foreman_id: userA.id, report_date: new Date().toISOString().slice(0, 10), foreman_name: "Isolation Admin A" });
  const reportB = await serviceInsert("daily_reports", { company_id: companyB.id, job_id: jobB.id, foreman_id: userB.id, report_date: new Date().toISOString().slice(0, 10), foreman_name: "Isolation Admin B" });

  const timeEmployeeA = await serviceInsert("timekeeping_employees", {
    company_id: companyA.id,
    full_name: "Transactional Time Test",
    created_by: userA.id,
  });
  const weeklyReports = [];
  for (const workDate of ["2035-01-08", "2035-01-09", "2035-01-10"]) {
    weeklyReports.push(await serviceInsert("daily_reports", {
      company_id: companyA.id,
      job_id: jobA.id,
      foreman_id: userA.id,
      report_date: workDate,
      work_date: workDate,
      foreman_name: "Isolation Admin A",
      created_by: userA.id,
    }));
  }
  await serviceInsert("timekeeping_entries", {
    company_id: companyA.id,
    employee_id: timeEmployeeA.id,
    daily_report_id: weeklyReports[1].id,
    job_id: jobA.id,
    work_date: "2035-01-09",
    regular_hours: 24,
    overtime_hours: 0,
    created_by: userA.id,
    updated_by: userA.id,
  });
  await serviceInsert("timekeeping_entries", {
    company_id: companyA.id,
    employee_id: timeEmployeeA.id,
    daily_report_id: weeklyReports[2].id,
    job_id: jobA.id,
    work_date: "2035-01-10",
    regular_hours: 16,
    overtime_hours: 0,
    created_by: userA.id,
    updated_by: userA.id,
  });
  await servicePatch("daily_reports", weeklyReports[1].id, { status: "approved", approved_by: userA.id, approved_at: new Date().toISOString() });
  await servicePatch("daily_reports", weeklyReports[2].id, { status: "approved", approved_by: userA.id, approved_at: new Date().toISOString() });
  await servicePatch("companies", companyA.id, {
    storm_mode_enabled: true,
    storm_event_name: "Isolation Storm",
    storm_started_at: "2035-01-08T00:00:00Z",
    storm_ended_at: null,
  });
  await serviceInsert("storm_mode_assignments", { company_id: companyA.id, user_id: userA.id, assigned_by: userA.id });
  const preStormReport = await serviceInsert("daily_reports", {
    company_id: companyA.id,
    job_id: jobA.id,
    foreman_id: userA.id,
    report_date: "2035-01-01",
    work_date: "2035-01-01",
    foreman_name: "Isolation Admin A",
    created_by: userA.id,
  });

  const [tokenA, tokenB, managerTokenA] = await Promise.all([signInAtAal2(userA.email), signInAtAal2(userB.email), signInAtAal2(managerA.email)]);
  const resourcesA = { companies: companyA, profiles: { id: userA.id }, customers: customerA, price_books: priceBookA, jobs: jobA, daily_reports: reportA };
  const resourcesB = { companies: companyB, profiles: { id: userB.id }, customers: customerB, price_books: priceBookB, jobs: jobB, daily_reports: reportB };

  for (const [rpc, body] of [
    ["get_company_jsas", {}],
    ["get_job_package_work_points", { p_package_id: currentPackageA.id }],
    ["get_assignable_job_leaders", {}],
  ]) {
    const result = await userRest(managerTokenA, `rpc/${rpc}`, "", { method: "POST", body });
    assert(result.ok, `Manager operational RPC ${rpc} failed: ${JSON.stringify(result.data)}`);
  }
  const transactionalSave = await userRest(tokenA, "rpc/save_daily_report_crew_time", "", {
    method: "POST",
    body: {
      p_report_id: weeklyReports[0].id,
      p_rows: [{ employee_id: timeEmployeeA.id, crew_name: "Isolation Crew", regular_hours: 8, overtime_hours: 0 }],
    },
  });
  assert(transactionalSave.ok, `Transactional Crew Time save failed: ${JSON.stringify(transactionalSave.data)}`);
  assert(
    Number(transactionalSave.data?.[0]?.regular_hours) === 0 && Number(transactionalSave.data?.[0]?.overtime_hours) === 8,
    `Approved weekly hours were not reserved during backdated save: ${JSON.stringify(transactionalSave.data)}`,
  );
  const approvedEntries = await request(`/rest/v1/timekeeping_entries?daily_report_id=in.(${weeklyReports[1].id},${weeklyReports[2].id})&select=daily_report_id,regular_hours,overtime_hours&order=work_date.asc`);
  assert(
    approvedEntries.ok && Number(approvedEntries.data?.[0]?.regular_hours) === 24 && Number(approvedEntries.data?.[1]?.regular_hours) === 16,
    `Approved Crew Time changed during backdated save: ${JSON.stringify(approvedEntries.data)}`,
  );
  const rejectedEmptySave = await userRest(tokenA, "rpc/save_daily_report_crew_time", "", {
    method: "POST",
    body: { p_report_id: weeklyReports[0].id, p_rows: [] },
  });
  assert(!rejectedEmptySave.ok && rejectedEmptySave.data?.code === "22023", "Empty Crew Time save was not rejected.");
  const preservedEntry = await request(`/rest/v1/timekeeping_entries?daily_report_id=eq.${weeklyReports[0].id}&select=id`);
  assert(preservedEntry.ok && preservedEntry.data.length === 1, "Empty Crew Time save removed the persisted entry.");

  const stormContext = await userRest(tokenA, "rpc/set_daily_report_storm_context", "", {
    method: "POST",
    body: { p_report_id: weeklyReports[0].id },
  });
  assert(stormContext.ok, `Storm context latch failed: ${JSON.stringify(stormContext.data)}`);
  const stormTime = await request(`/rest/v1/timekeeping_entries?daily_report_id=eq.${weeklyReports[0].id}&select=storm_work`);
  assert(stormTime.ok && stormTime.data?.[0]?.storm_work === true, "Storm context did not restamp Crew Time.");
  const oldContext = await userRest(tokenA, "rpc/set_daily_report_storm_context", "", {
    method: "POST",
    body: { p_report_id: preStormReport.id },
  });
  assert(oldContext.ok, `Pre-Storm context latch failed: ${JSON.stringify(oldContext.data)}`);
  const oldReport = await request(`/rest/v1/daily_reports?id=eq.${preStormReport.id}&select=storm_mode,storm_event_name`);
  assert(oldReport.ok && oldReport.data?.[0]?.storm_mode === false && oldReport.data?.[0]?.storm_event_name === null,
    `Pre-Storm work date was misclassified: ${JSON.stringify(oldReport.data)}`);

  // ---------------------------------------------------------------------
  // Regression: the weekly overtime split at every allowance boundary.
  // Previously only the saturated case (running = 40) was exercised, so the
  // one branch that can actually SPLIT a day was never executed.
  // ---------------------------------------------------------------------
  for (const [seedRegular, dayHours, expectRegular, expectOvertime] of [
    [36, 8, 4, 4],
    [39.5, 8, 0.5, 7.5],
    [40, 8, 0, 8],
    [44, 8, 0, 8],
  ]) {
    const splitEmployee = await serviceInsert("timekeeping_employees", {
      company_id: companyA.id,
      full_name: `OT Split ${seedRegular}`,
      created_by: userA.id,
    });
    const seedReports = [];
    for (const workDate of ["2035-01-09", "2035-01-10"]) {
      seedReports.push(await serviceInsert("daily_reports", {
        company_id: companyA.id, job_id: jobA.id, foreman_id: userA.id,
        report_date: workDate, work_date: workDate,
        foreman_name: "Isolation Admin A", created_by: userA.id,
      }));
    }
    const targetReport = await serviceInsert("daily_reports", {
      company_id: companyA.id, job_id: jobA.id, foreman_id: userA.id,
      report_date: "2035-01-08", work_date: "2035-01-08",
      foreman_name: "Isolation Admin A", created_by: userA.id,
    });
    const seedParts = [seedRegular / 2, seedRegular - (seedRegular / 2)];
    for (let index = 0; index < seedReports.length; index += 1) {
      await serviceInsert("timekeeping_entries", {
        company_id: companyA.id, employee_id: splitEmployee.id,
        daily_report_id: seedReports[index].id, job_id: jobA.id,
        work_date: index === 0 ? "2035-01-09" : "2035-01-10",
        regular_hours: seedParts[index], overtime_hours: 0,
        created_by: userA.id, updated_by: userA.id,
      });
      await servicePatch("daily_reports", seedReports[index].id, {
        status: "approved", approved_by: userA.id, approved_at: new Date().toISOString(),
      });
    }
    const split = await userRest(tokenA, "rpc/save_daily_report_crew_time", "", {
      method: "POST",
      body: {
        p_report_id: targetReport.id,
        p_rows: [{ employee_id: splitEmployee.id, crew_name: "Split Crew", regular_hours: dayHours, overtime_hours: 0 }],
      },
    });
    assert(split.ok, `OT split save failed at running ${seedRegular}: ${JSON.stringify(split.data)}`);
    assert(
      Number(split.data?.[0]?.regular_hours) === expectRegular &&
      Number(split.data?.[0]?.overtime_hours) === expectOvertime,
      `OT split wrong at running ${seedRegular}: expected ${expectRegular}/${expectOvertime}, got ${JSON.stringify(split.data)}`,
    );
  }

  // ---------------------------------------------------------------------
  // Regression: the payroll week must follow companies.week_start_day.
  // 2035-01-06 is a Sunday and 2035-01-07 a Monday, so the two settings put
  // them in DIFFERENT weeks -- a fixture that can actually tell them apart.
  // ---------------------------------------------------------------------
  for (const [weekStartDay, sundayIsOwnWeek] of [[0, true], [1, false]]) {
    await servicePatch("companies", companyA.id, { week_start_day: weekStartDay });
    const weekEmployee = await serviceInsert("timekeeping_employees", {
      company_id: companyA.id, full_name: `Week Start ${weekStartDay}`, created_by: userA.id,
    });
    const sundayReport = await serviceInsert("daily_reports", {
      company_id: companyA.id, job_id: jobA.id, foreman_id: userA.id,
      report_date: "2035-01-07", work_date: "2035-01-07",
      foreman_name: "Isolation Admin A", created_by: userA.id,
    });
    const sundayJobTwo = await serviceInsert("jobs", {
      company_id: companyA.id, job_number: `${runId}-week-${weekStartDay}`,
      job_name: `Week Boundary ${weekStartDay}`, created_by: userA.id,
      price_book_id: priceBookA.id,
    });
    const sundayReportTwo = await serviceInsert("daily_reports", {
      company_id: companyA.id, job_id: sundayJobTwo.id, foreman_id: userA.id,
      report_date: "2035-01-07", work_date: "2035-01-07",
      foreman_name: "Isolation Admin A", created_by: userA.id,
    });
    const mondayReport = await serviceInsert("daily_reports", {
      company_id: companyA.id, job_id: jobA.id, foreman_id: userA.id,
      report_date: "2035-01-08", work_date: "2035-01-08",
      foreman_name: "Isolation Admin A", created_by: userA.id,
    });
    // Two valid entries on 2035-01-07 (Sunday) consume the whole regular
    // allowance without violating the table's 24-hour-per-entry constraint.
    await serviceInsert("timekeeping_entries", {
      company_id: companyA.id, employee_id: weekEmployee.id,
      daily_report_id: sundayReport.id, job_id: jobA.id, work_date: "2035-01-07",
      regular_hours: 24, overtime_hours: 0, created_by: userA.id, updated_by: userA.id,
    });
    await serviceInsert("timekeeping_entries", {
      company_id: companyA.id, employee_id: weekEmployee.id,
      daily_report_id: sundayReportTwo.id, job_id: sundayJobTwo.id, work_date: "2035-01-07",
      regular_hours: 16, overtime_hours: 0, created_by: userA.id, updated_by: userA.id,
    });
    await servicePatch("daily_reports", sundayReport.id, {
      status: "approved", approved_by: userA.id, approved_at: new Date().toISOString(),
    });
    await servicePatch("daily_reports", sundayReportTwo.id, {
      status: "approved", approved_by: userA.id, approved_at: new Date().toISOString(),
    });
    const weekSave = await userRest(tokenA, "rpc/save_daily_report_crew_time", "", {
      method: "POST",
      body: {
        p_report_id: mondayReport.id,
        p_rows: [{ employee_id: weekEmployee.id, crew_name: "Week Crew", regular_hours: 8, overtime_hours: 0 }],
      },
    });
    assert(weekSave.ok, `Week-start save failed for week_start_day=${weekStartDay}: ${JSON.stringify(weekSave.data)}`);
    // week_start_day=1 (Monday): Sunday 01-07 is in the PREVIOUS week, so the
    // Monday entry starts a fresh 40-hour allowance -> 8 regular.
    // week_start_day=0 (Sunday): both days share a week -> allowance spent -> 8 OT.
    const expectedRegular = sundayIsOwnWeek ? 0 : 8;
    const expectedOvertime = sundayIsOwnWeek ? 8 : 0;
    assert(
      Number(weekSave.data?.[0]?.regular_hours) === expectedRegular &&
      Number(weekSave.data?.[0]?.overtime_hours) === expectedOvertime,
      `week_start_day=${weekStartDay} did not move the week boundary: expected ${expectedRegular}/${expectedOvertime}, got ${JSON.stringify(weekSave.data)}`,
    );
  }
  await servicePatch("companies", companyA.id, { week_start_day: 1 });

  // ---------------------------------------------------------------------
  // Regression: two Daily Reports must not fight over one employee's entry,
  // and an approved report's crew time must be immutable in BOTH directions.
  // ---------------------------------------------------------------------
  const conflictEmployee = await serviceInsert("timekeeping_employees", {
    company_id: companyA.id, full_name: "Conflict Crew", created_by: userA.id,
  });
  const conflictReportOne = await serviceInsert("daily_reports", {
    company_id: companyA.id, job_id: jobA.id, foreman_id: userA.id,
    report_date: "2035-02-05", work_date: "2035-02-05",
    foreman_name: "Isolation Admin A", created_by: userA.id,
  });
  const conflictReportTwo = await serviceInsert("daily_reports", {
    company_id: companyA.id, job_id: jobA.id, foreman_id: managerA.id,
    report_date: "2035-02-05", work_date: "2035-02-05",
    foreman_name: "Isolation Manager A", created_by: userA.id,
  });
  const firstClaim = await userRest(tokenA, "rpc/save_daily_report_crew_time", "", {
    method: "POST",
    body: { p_report_id: conflictReportOne.id, p_rows: [{ employee_id: conflictEmployee.id, crew_name: "Crew One", regular_hours: 8, overtime_hours: 0 }] },
  });
  assert(firstClaim.ok, `First crew claim failed: ${JSON.stringify(firstClaim.data)}`);
  const secondClaim = await userRest(tokenA, "rpc/save_daily_report_crew_time", "", {
    method: "POST",
    body: { p_report_id: conflictReportTwo.id, p_rows: [{ employee_id: conflictEmployee.id, crew_name: "Crew Two", regular_hours: 8, overtime_hours: 0 }] },
  });
  assert(!secondClaim.ok && secondClaim.data?.code === "23505",
    `A second report re-parented an employee's crew time: ${JSON.stringify(secondClaim.data)}`);
  const stillOwned = await request(`/rest/v1/timekeeping_entries?employee_id=eq.${conflictEmployee.id}&select=daily_report_id`);
  assert(stillOwned.ok && stillOwned.data.length === 1 && stillOwned.data[0].daily_report_id === conflictReportOne.id,
    `Crew time changed owner during the conflict: ${JSON.stringify(stillOwned.data)}`);

  // Approve report one, then try to move the entry off it by direct REST.
  await servicePatch("daily_reports", conflictReportOne.id, {
    status: "approved", approved_by: managerA.id, approved_at: new Date().toISOString(),
  });
  const claimedEntry = stillOwned.data[0];
  const entryRow = await request(`/rest/v1/timekeeping_entries?employee_id=eq.${conflictEmployee.id}&select=id`);
  const reparent = await userRest(tokenA, "timekeeping_entries", `?id=eq.${entryRow.data[0].id}`, {
    method: "PATCH",
    body: { daily_report_id: conflictReportTwo.id, updated_by: userA.id },
  });
  assert(!reparent.ok,
    `Approved crew time was moved off its certified Daily Report by a direct write: ${JSON.stringify(reparent.data)}`);
  const afterReparent = await request(`/rest/v1/timekeeping_entries?employee_id=eq.${conflictEmployee.id}&select=daily_report_id`);
  assert(afterReparent.ok && afterReparent.data[0].daily_report_id === conflictReportOne.id,
    'Approved crew time left its certified report.');
  void claimedEntry;

  // ---------------------------------------------------------------------
  // Regression: a Manager must be able to record leadership time. Both the
  // caller RPCs admitted 'manager' while private.recalculate_leadership_week
  // did not, so every save ended in a raw 42501.
  // ---------------------------------------------------------------------
  const managerEmployee = await serviceInsert("timekeeping_employees", {
    company_id: companyA.id, full_name: "Isolation Manager A",
    linked_profile_id: managerA.id, created_by: userA.id,
  });
  const managerOwnTime = await userRest(managerTokenA, "rpc/upsert_my_leadership_time", "", {
    method: "POST",
    body: { p_work_date: "2035-03-04", p_start_time: "07:00", p_stop_time: "15:00", p_lunch_minutes: 30, p_labor_code: "OVERHEAD" },
  });
  assert(managerOwnTime.ok, `A Manager could not record their own leadership time: ${JSON.stringify(managerOwnTime.data)}`);
  const managerOtherTime = await userRest(managerTokenA, "rpc/upsert_leadership_employee_time", "", {
    method: "POST",
    body: { p_employee_id: timeEmployeeA.id, p_work_date: "2035-03-05", p_start_time: "07:00", p_stop_time: "15:00", p_lunch_minutes: 30, p_labor_code: "OVERHEAD" },
  });
  assert(managerOtherTime.ok, `A Manager could not record another employee's leadership time: ${JSON.stringify(managerOtherTime.data)}`);
  void managerEmployee;

  for (const [table, row] of Object.entries(resourcesA)) await expectOwnRow(tokenA, table, row.id);
  for (const [table, row] of Object.entries(resourcesB)) await expectOwnRow(tokenB, table, row.id);
  for (const [table, row] of Object.entries(resourcesB)) await expectForeignHidden(tokenA, table, row.id);
  for (const [table, row] of Object.entries(resourcesA)) await expectForeignHidden(tokenB, table, row.id);

  const ownRevisionDelta = await userRest(tokenA, "rpc/get_job_package_revision_delta", "", {
    method: "POST",
    body: { p_package_id: currentPackageA.id },
  });
  assert(ownRevisionDelta.ok, `Same-company package revision delta failed: ${JSON.stringify(ownRevisionDelta.data)}`);
  assert(
    Array.isArray(ownRevisionDelta.data) && ownRevisionDelta.data.length === 1 && ownRevisionDelta.data[0].install_change === 1,
    `Same-company package revision delta was incorrect: ${JSON.stringify(ownRevisionDelta.data)}`,
  );

  const foreignRevisionDelta = await userRest(tokenA, "rpc/get_job_package_revision_delta", "", {
    method: "POST",
    body: { p_package_id: packageB.id },
  });
  assert(
    !foreignRevisionDelta.ok && foreignRevisionDelta.data?.code === "P0002",
    `SECURITY FAILURE: cross-company package revision delta was not denied: ${JSON.stringify(foreignRevisionDelta.data)}`,
  );

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
  assert(
    !crossDelete.ok || (Array.isArray(crossDelete.data) && crossDelete.data.length === 0),
    "SECURITY FAILURE: cross-company delete affected a row.",
  );
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
