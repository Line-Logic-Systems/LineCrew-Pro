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

for(const marker of ['<form id="loginCard"','for="loginEmail"','autocomplete="username"','for="loginPassword"','autocomplete="current-password"'])
  assert.ok(app.includes(marker),`Accessible sign-in marker is missing: ${marker}`);
// Sign-in must submit natively (Enter key + assistive technology) and announce
// failures inline rather than through alert().
assert.ok(app.includes('<button id="loginBtn" type="submit">'),'Sign In must be a real submit button.');
assert.ok(!app.includes('<form id="loginCard" class="card" onsubmit="return false">'),
  'The sign-in form must not suppress its own submit event.');
assert.ok(/id="loginError"[^>]*role="alert"[^>]*aria-live="assertive"/.test(app),
  'Sign-in errors must be announced by an aria-live alert region.');
// Exactly one handler may run per submit: both index.html and expanded-jsa.js
// assign onsubmit as a PROPERTY so the later one supersedes rather than stacks.
assert.ok(app.includes("$('loginCard').onsubmit ="),'index.html must assign loginCard.onsubmit as a property.');
assert.ok(expanded.includes('loginForm.onsubmit ='),'expanded-jsa.js must supersede via loginCard.onsubmit.');
assert.ok(!expanded.includes('loginButton.onclick ='),
  'expanded-jsa.js must not also bind onclick, or a click would sign in twice.');
assert.ok(app.includes("function userCanSeeSafetyRecords(){ return userIsSafety() ||"),'Safety fallback must match the core module.');
for(const id of ['forgotPasswordBtn','saveRecoveryPassword']){
  const start=app.indexOf(`$('${id}').onclick`); const end=app.indexOf('\n};',start);
  assert.ok(start>=0&&app.slice(start,end).includes('finally{'),`${id} handler must restore its button in finally.`);
}
assert.ok(!responsive.includes('@media (max-width: 1099px), (pointer: coarse)'),'Touch input must not force phone layout at desktop widths.');
// ...but wide touch devices must still get a complete layout. Every (width,
// pointer) pair has to match either the compact block or a desktop block.
assert.ok(responsive.includes('@media (max-width: 1099px), (min-width: 1100px) and (pointer: coarse)'),
  'Wide coarse-pointer devices (tablet landscape) must match the compact shell block.');
// The pre-paint theme class must be the one the stylesheets actually target.
assert.ok(app.includes("classList.add('lc-industrial-dark')"),
  'The pre-paint theme script must apply the class the dark stylesheets use.');
assert.ok(!app.includes("classList.add('dark')"),'A pre-paint class no stylesheet targets is a no-op.');
assert.ok(responsive.includes('html.lc-industrial-dark {'),
  'The dark palette must exist in a <head> stylesheet so it applies before first paint.');
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
