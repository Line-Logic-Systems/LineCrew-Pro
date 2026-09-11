import fs from 'node:fs';
import vm from 'node:vm';

const moduleSource = fs.readFileSync('notifications-core.js','utf8');
const bootstrap = fs.readFileSync('number-input-polish.js','utf8');
const index = fs.readFileSync('index.html','utf8');
const serviceWorker = fs.readFileSync('service-worker.js','utf8');

const navigator = { onLine:true, userAgent:'Desktop Browser', serviceWorker:{} };
const Notification = { permission:'default' };
const sandbox = {
  window:{
    atob:value => Buffer.from(value, 'base64').toString('binary'),
    navigator,
    PushManager:function PushManager(){},
    Notification
  },
  navigator,
  Notification,
  Uint8Array
};
vm.runInNewContext(moduleSource, sandbox, { filename:'notifications-core.js' });
const core = sandbox.window.LineCrewNotificationsCore;
for (const name of ['urlBase64ToUint8Array','pushUnsupportedReason']) {
  if (!core || typeof core[name] !== 'function') throw new Error(`Notifications core module must expose ${name}().`);
}

const cases = [
  ['', []],
  ['AQ', [1]],
  ['AQI', [1,2]],
  ['AQID', [1,2,3]],
  ['_-7d', [255,238,221]]
];
for (const [input, expected] of cases) {
  const actual = Array.from(core.urlBase64ToUint8Array(input));
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`urlBase64ToUint8Array(${JSON.stringify(input)}) returned ${JSON.stringify(actual)}; expected ${JSON.stringify(expected)}.`);
  }
}

function resetPushEnvironment(){
  navigator.userAgent = 'Desktop Browser';
  navigator.serviceWorker = {};
  delete navigator.standalone;
  sandbox.window.PushManager = function PushManager(){};
  sandbox.window.Notification = Notification;
  Notification.permission = 'default';
}

resetPushEnvironment();
if (core.pushUnsupportedReason() !== '') throw new Error('Supported desktop push environment must return no warning.');

delete navigator.serviceWorker;
if (core.pushUnsupportedReason() !== 'Not supported on this browser.') throw new Error('Missing serviceWorker support must return the browser support warning.');

resetPushEnvironment();
delete sandbox.window.PushManager;
if (core.pushUnsupportedReason() !== 'Not supported on this browser.') throw new Error('Missing PushManager support must return the browser support warning.');

resetPushEnvironment();
navigator.userAgent = 'iPhone';
if (core.pushUnsupportedReason() !== 'On iPhone, add LineCrew Pro to your Home Screen first: Share → Add to Home Screen.') {
  throw new Error('iPhone non-standalone warning must match legacy behavior.');
}

resetPushEnvironment();
navigator.userAgent = 'iPhone';
navigator.standalone = true;
if (core.pushUnsupportedReason() !== '') throw new Error('Home Screen iPhone push environment must not show the standalone warning.');

resetPushEnvironment();
Notification.permission = 'denied';
if (core.pushUnsupportedReason() !== 'Blocked in browser settings. Allow notifications for LineCrew Pro in this device’s browser or app settings.') {
  throw new Error('Denied notification permission warning must match legacy behavior.');
}

for (const name of ['urlBase64ToUint8Array','pushUnsupportedReason']) {
  if (sandbox.window[name] !== core[name]) throw new Error(`Notifications core compatibility bridge ${name} is not active.`);
}
if (!bootstrap.includes("script.src = '/notifications-core.js?v=20260910a'")) {
  throw new Error('Notifications core module is not bootstrapped by the existing front-end loader path.');
}
if (!bootstrap.includes('Notifications core module unavailable; using inline compatibility fallback.')) {
  throw new Error('Notifications core loader must retain an explicit inline fallback path.');
}
if (!serviceWorker.includes("'/notifications-core.js?v=20260910a'")) {
  throw new Error('Notifications core module must remain in the offline app shell.');
}
for (const signature of [
  'function urlBase64ToUint8Array(value){',
  'function pushUnsupportedReason(){'
]) {
  if (!index.includes(signature)) throw new Error(`Legacy inline Notifications fallback missing: ${signature}`);
}

console.log('Notifications core modularization guard passed.');
console.log('- VAPID URL-safe base64 decoding matches legacy behavior');
console.log('- browser/iPhone/permission support-state messages match legacy behavior');
console.log('- compatibility bridges are active; module is offline-capable; inline fallbacks remain available');
