import fs from 'node:fs';
import assert from 'node:assert/strict';

const app=fs.readFileSync('index.html','utf8');
const serviceWorker=fs.readFileSync('service-worker.js','utf8');
const responsive=fs.readFileSync('responsive-role-shell.css','utf8');
const expanded=fs.readFileSync('expanded-jsa.js','utf8');
const loaders=fs.readFileSync('number-input-polish.js','utf8');
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
for(const marker of ["linecrew-pro-shell-v99","'/job-map-documents.js?v=20260910a'","cache.add(SUPABASE_RUNTIME).catch"])
  assert.ok(serviceWorker.includes(marker),`PWA reliability marker is missing: ${marker}`);
const shellList=serviceWorker.slice(serviceWorker.indexOf('const APP_SHELL = ['),serviceWorker.indexOf('];',serviceWorker.indexOf('const APP_SHELL = [')));
assert.ok(!shellList.includes('SUPABASE_RUNTIME'),'Cross-origin runtime must not be in mandatory addAll.');
for(const name of ['submit-beta-application','review-beta-application','complete-utility-invitation-signup','send-push-notification','send-utility-invitation','notify-pilot-feedback','retry-beta-sales-notification'])
  assert.ok(edgeWorkflow.includes(`deno check supabase/functions/${name}/index.ts`),`Edge Function type check is missing: ${name}`);

console.log('Launch reliability fixes passed.');
