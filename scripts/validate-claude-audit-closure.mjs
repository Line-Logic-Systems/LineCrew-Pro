import fs from 'node:fs';
import assert from 'node:assert/strict';

const app=fs.readFileSync('index.html','utf8');
const migration=fs.readFileSync('supabase/migrations/20260912144518_close_launch_readiness_audit.sql','utf8');
const assistant=fs.readFileSync('supabase/functions/linecrew-assistant/index.ts','utf8');
const serviceWorker=fs.readFileSync('service-worker.js','utf8');
const theme=fs.readFileSync('gf-review-theme-enhancements.js','utf8');
const leadership=fs.readFileSync('leadership-my-time.js','utf8');

const progressCalls=[...app.matchAll(/sb\.rpc\('get_job_progress_dashboard_v2'([^)]*)\)/g)];
assert.ok(progressCalls.length>=2&&progressCalls.every(call=>call[1].includes('p_job_id:')),
  'Every job-progress call must be explicitly job-scoped.');
assert.ok(!app.includes("sb.rpc('get_job_progress_dashboard_v2')"),'An unscoped progress call remains.');

for(const marker of [
  "v_role not in ('owner','manager','admin','superintendent')",
  'point.normalized_work_point_key location_key',
  'authorization_scope as (',
  'location.normalized_pole_location_key',
  "lower(coalesce(report.status,''))='approved' or report.id=p_report_id",
  "linecrew_company_entitlement_required",
  "company_member_access_changed",
  "timekeeping_entries.daily_report_id=p_report_id",
  "report.redline_override_by",
  "v_current='draft' and v_next in ('exported','submitted','paid')",
  'job_packet_documents_manager_delete'
]) assert.ok(migration.includes(marker),`Audit closure migration is missing: ${marker}`);
assert.ok(!migration.includes('), authorization as ('),'Reserved SQL keywords must not be used as CTE names.');

assert.ok(assistant.includes('if (error || !Array.isArray(data))'),
  'Assistant must distinguish unavailable context from an empty result.');
assert.ok(leadership.includes("['gf','admin','manager','owner']"),
  'Manager leadership-time parity is missing.');
assert.ok(app.includes("localStorage.getItem('linecrew-pro-theme-preload')==='dark'")&&
  theme.includes("localStorage.setItem('linecrew-pro-theme-preload', theme)"),
  'Dark mode must be available to the head bootstrap before deferred scripts load.');
assert.ok(serviceWorker.includes("caches.match('/index.html')"),
  'Offline navigation must fall back to a mandatory precached URL.');
assert.ok(app.includes('<form id="signupCard"')&&app.includes('for="signupEmail"')&&
  app.includes('id="signupEmail" type="email" autocomplete="username"'),
  'Signup form semantics and autocomplete are incomplete.');

console.log('Claude audit closure regression guard passed.');
