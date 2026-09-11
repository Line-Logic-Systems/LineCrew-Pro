import fs from 'node:fs';
import vm from 'node:vm';

const moduleSource = fs.readFileSync('price-book-core.js','utf8');
const bootstrap = fs.readFileSync('number-input-polish.js','utf8');
const index = fs.readFileSync('index.html','utf8');
const serviceWorker = fs.readFileSync('service-worker.js','utf8');

const sandbox = { window:{} };
vm.runInNewContext(moduleSource, sandbox, { filename:'price-book-core.js' });
const core = sandbox.window.LineCrewPriceBookCore;
if (!core || typeof core.normalizeImportHeader !== 'function' || typeof core.normalizedPriceWorkType !== 'function') {
  throw new Error('Price Book core module must expose normalizeImportHeader() and normalizedPriceWorkType().');
}

const headerCases = [
  [' Unit Code ', 'unitcode'],
  ['Install Price ($)', 'installprice'],
  ['WORK-TYPE', 'worktype'],
  ['', '']
];
for (const [input, expected] of headerCases) {
  const actual = core.normalizeImportHeader(input);
  if (actual !== expected) throw new Error(`normalizeImportHeader(${JSON.stringify(input)}) returned ${actual}; expected ${expected}.`);
}

const workTypeCases = [
  [['Transfer',''], 'transfer'],
  [['xfer',''], 'transfer'],
  [['Remove',''], 'retirement'],
  [['Retirement',''], 'retirement'],
  [['Install',''], 'install'],
  [['','CV3030I'], 'install'],
  [['','OH4112R'], 'retirement'],
  [['','PS1095T'], 'transfer'],
  [['','ANCHOR'], ''],
  [['','CONDUIT'], ''],
  [['Mystery','ABC123'], 'unknown']
];
for (const [[value, itemCode], expected] of workTypeCases) {
  const actual = core.normalizedPriceWorkType(value, itemCode);
  if (actual !== expected) throw new Error(`normalizedPriceWorkType(${JSON.stringify(value)}, ${JSON.stringify(itemCode)}) returned ${actual}; expected ${expected}.`);
}

if (sandbox.window.normalizeImportHeader !== core.normalizeImportHeader ||
    sandbox.window.normalizedPriceWorkType !== core.normalizedPriceWorkType) {
  throw new Error('Price Book compatibility bridges are not active.');
}
if (!bootstrap.includes("script.src = '/price-book-core.js?v=20260910a'")) {
  throw new Error('Price Book core module is not bootstrapped by the existing front-end loader path.');
}
if (!bootstrap.includes('Price Book core module unavailable; using inline compatibility fallback.')) {
  throw new Error('Price Book core loader must retain an explicit inline fallback path.');
}
if (!serviceWorker.includes("'/price-book-core.js?v=20260910a'")) {
  throw new Error('Price Book core module must remain in the offline app shell.');
}
if (!index.includes('function normalizeImportHeader(value){') ||
    !index.includes('function normalizedPriceWorkType(value,itemCode=\'\'){')) {
  throw new Error('Legacy inline Price Book helper fallbacks must remain during staged extraction.');
}
if (!index.includes("const suffixMatch=String(itemCode || '').trim().toUpperCase().match(/[0-9]([IRT])$/);")) {
  throw new Error('Legacy unit-code suffix behavior must remain during staged extraction.');
}

console.log('Price Book core modularization guard passed.');
console.log('- header normalization matches legacy behavior');
console.log('- install/transfer/retirement detection parity is verified');
console.log('- word-style unit codes still avoid false suffix classification');
console.log('- compatibility bridges, offline cache, and inline fallbacks remain active');
