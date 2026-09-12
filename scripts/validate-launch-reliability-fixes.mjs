import fs from 'node:fs';
import assert from 'node:assert/strict';

const app=fs.readFileSync('index.html','utf8');
const serviceWorker=fs.readFileSync('service-worker.js','utf8');
const responsive=fs.readFileSync('responsive-role-shell.css','utf8');
const expanded=fs.readFileSync('expanded-jsa.js','utf8');
const loaders=fs.readFileSync('number-input-polish.js','utf8');
const roleLoaders=fs.readFileSync('role-workspace-polish.js','utf8');
const timekeepingReport=fs.readFileSync('timekeeping-report-v2.js','utf8');
const edgeWorkflow=fs.readFileSync('.github/workflows/validate-platform-billing.yml','utf8');

for(const marker of ['<form id="loginCard"','for="loginEmail"','autocomplete="email"','for="loginPassword"','autocomplete="current-password"'])
  assert.ok(app.includes(marker),`Accessible sign-in marker is missing: ${marker}`);
assert.ok(app.includes("function userCanSeeSafetyRecords(){ return userIsSafety() ||"),'Safety fallback must match the core module.');
for(const id of ['forgotPasswordBtn','saveRecoveryPassword']){
  const start=app.indexOf(`$('${id}').onclick`); const end=app.indexOf('\n};',start);
  assert.ok(start>=0&&app.slice(start,end).includes('finally{'),`${id} handler must restore its button in finally.`);
}
assert.ok(!responsive.includes('@media (max-width: 1099px), (pointer: coarse)'),'Touch input must not force phone layout at desktop widths.');
assert.ok(!expanded.includes('script.defer = false')&&!loaders.includes('script.defer = false'),'Dynamic loaders must not rely on defer.');
assert.ok(expanded.includes('script.async = false')&&(loaders.match(/script\.async = false/g)||[]).length===9,'Every dynamic root loader must explicitly preserve order.');
assert.equal((roleLoaders.match(/script\.async=false/g)||[]).length,2,'Role/theme loaders must preserve execution order.');
assert.ok(timekeepingReport.includes("timekeeping-input-v2.js?v=20260910a")&&timekeepingReport.includes('script.async=false'),
  'The Timekeeping loader must use the precached version and preserve order.');
const cacheVersion=Number(serviceWorker.match(/const CACHE_NAME = 'linecrew-pro-shell-v(\d+)'/)?.[1]);
assert.ok(Number.isInteger(cacheVersion)&&cacheVersion>=99,'PWA cache name must have a monotonic numeric version.');
for(const marker of ["'/job-map-documents.js?v=20260910a'","cache.add(SUPABASE_RUNTIME).catch","caches.match('/index.html')"])
  assert.ok(serviceWorker.includes(marker),`PWA reliability marker is missing: ${marker}`);
const shellList=serviceWorker.slice(serviceWorker.indexOf('const APP_SHELL = ['),serviceWorker.indexOf('];',serviceWorker.indexOf('const APP_SHELL = [')));
assert.ok(!shellList.includes('SUPABASE_RUNTIME'),'Cross-origin runtime must not be in mandatory addAll.');
for(const name of ['submit-beta-application','review-beta-application','complete-utility-invitation-signup','send-push-notification','send-utility-invitation','notify-pilot-feedback','retry-beta-sales-notification'])
  assert.ok(edgeWorkflow.includes(`deno check supabase/functions/${name}/index.ts`),`Edge Function type check is missing: ${name}`);

console.log('Launch reliability fixes passed.');
