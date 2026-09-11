import fs from 'node:fs';
import vm from 'node:vm';

const moduleSource = fs.readFileSync('notifications-core.js','utf8');
const bootstrap = fs.readFileSync('number-input-polish.js','utf8');
const index = fs.readFileSync('index.html','utf8');
const serviceWorker = fs.readFileSync('service-worker.js','utf8');

const sandbox = {
  window:{ atob:value => Buffer.from(value, 'base64').toString('binary') },
  Uint8Array
};
vm.runInNewContext(moduleSource, sandbox, { filename:'notifications-core.js' });
const core = sandbox.window.LineCrewNotificationsCore;
if (!core || typeof core.urlBase64ToUint8Array !== 'function') {
  throw new Error('Notifications core module must expose urlBase64ToUint8Array().');
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

if (sandbox.window.urlBase64ToUint8Array !== core.urlBase64ToUint8Array) {
  throw new Error('Notifications core compatibility bridge is not active.');
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
if (!index.includes('function urlBase64ToUint8Array(value){')) {
  throw new Error('Legacy inline urlBase64ToUint8Array() fallback must remain during staged extraction.');
}

console.log('Notifications core modularization guard passed.');
console.log('- VAPID URL-safe base64 decoding matches legacy behavior');
console.log('- compatibility bridge is active');
console.log('- module is available offline');
console.log('- inline fallback remains available if the module cannot load');
