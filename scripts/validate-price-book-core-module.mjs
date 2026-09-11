import fs from 'node:fs';
import vm from 'node:vm';

const moduleSource = fs.readFileSync('price-book-core.js','utf8');
const bootstrap = fs.readFileSync('number-input-polish.js','utf8');
const index = fs.readFileSync('index.html','utf8');
const serviceWorker = fs.readFileSync('service-worker.js','utf8');

const sandbox = { window:{} };
vm.runInNewContext(moduleSource, sandbox, { filename:'price-book-core.js' });
const core = sandbox.window.LineCrewPriceBookCore;
for (const name of ['normalizeImportHeader','importEditDistance','importHeaderMatchConfidence','normalizedPriceWorkType','importCell','importPrice']) {
  if (!core || typeof core[name] !== 'function') throw new Error(`Price Book core module must expose ${name}().`);
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

const distanceCases = [
  [['unitcode','unitcode'], 0],
  [['unitcode','unitcod'], 1],
  [['price','prize'], 1],
  [['','abc'], 3]
];
for (const [[left,right], expected] of distanceCases) {
  const actual = core.importEditDistance(left,right);
  if (actual !== expected) throw new Error(`importEditDistance(${left}, ${right}) returned ${actual}; expected ${expected}.`);
}

const confidenceCases = [
  [['Unit Code',['unitcode','itemcode']], 1],
  [['Unit Code Number',['unitcode','itemcode']], .92],
  [['Unutcode',['unitcode','itemcode']], .82],
  [['Completely Different',['unitcode','itemcode']], 0],
  [['',['unitcode']], 0]
];
for (const [[value, aliases], expected] of confidenceCases) {
  const actual = core.importHeaderMatchConfidence(value, aliases);
  if (actual !== expected) throw new Error(`importHeaderMatchConfidence(${JSON.stringify(value)}) returned ${actual}; expected ${expected}.`);
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

const row = { 'Unit Code':'OH4112R', 'Install Price ($)':'$1,250.50', Description:'Test row' };
if (core.importCell(row,['unitcode','itemcode']) !== 'OH4112R') throw new Error('importCell() failed normalized alias lookup.');
if (core.importCell(row,['transferprice']) !== '') throw new Error('importCell() must return an empty string when no alias matches.');

const priceCases = [
  ['',0],
  [null,0],
  [undefined,0],
  ['$1,250.50',1250.5],
  [' ( 450.25 ) ',-450.25],
  ['25',25]
];
for (const [input, expected] of priceCases) {
  const actual = core.importPrice(input);
  if (!Object.is(actual, expected)) throw new Error(`importPrice(${JSON.stringify(input)}) returned ${actual}; expected ${expected}.`);
}
if (!Number.isNaN(core.importPrice('not-a-price'))) throw new Error('importPrice() must preserve invalid numeric input as NaN for existing validation to catch.');

for (const name of ['normalizeImportHeader','importEditDistance','importHeaderMatchConfidence','normalizedPriceWorkType','importCell','importPrice']) {
  if (sandbox.window[name] !== core[name]) throw new Error(`Price Book compatibility bridge ${name} is not active.`);
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
for (const signature of [
  'function normalizeImportHeader(value){',
  'function importEditDistance(left,right){',
  'function importHeaderMatchConfidence(value,aliases){',
  "function normalizedPriceWorkType(value,itemCode=''){",
  'function importCell(row, aliases){',
  'function importPrice(value){'
]) {
  if (!index.includes(signature)) throw new Error(`Legacy inline Price Book fallback missing: ${signature}`);
}
if (!index.includes("const suffixMatch=String(itemCode || '').trim().toUpperCase().match(/[0-9]([IRT])$/);")) {
  throw new Error('Legacy unit-code suffix behavior must remain during staged extraction.');
}

console.log('Price Book core modularization guard passed.');
console.log('- header normalization and fuzzy header matching match legacy behavior');
console.log('- install/transfer/retirement detection parity is verified');
console.log('- cell alias lookup and price parsing parity are verified');
console.log('- word-style unit codes still avoid false suffix classification');
console.log('- compatibility bridges, offline cache, and inline fallbacks remain active');
