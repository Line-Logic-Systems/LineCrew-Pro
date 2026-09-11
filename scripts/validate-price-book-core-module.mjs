import fs from 'node:fs';
import vm from 'node:vm';

const moduleSource = fs.readFileSync('price-book-core.js','utf8');
const bootstrap = fs.readFileSync('number-input-polish.js','utf8');
const index = fs.readFileSync('index.html','utf8');
const serviceWorker = fs.readFileSync('service-worker.js','utf8');

const sandbox = { window:{} };
vm.runInNewContext(moduleSource, sandbox, { filename:'price-book-core.js' });
const core = sandbox.window.LineCrewPriceBookCore;
const helperNames = ['normalizeImportHeader','importEditDistance','importHeaderMatchConfidence','normalizedPriceWorkType','importCell','importPrice','numericImportPrice','spreadsheetColumnName','priceBookComparisonValueChanged','newPriceBookFileSignature'];
for (const name of helperNames) if (!core || typeof core[name] !== 'function') throw new Error(`Price Book core module must expose ${name}().`);

for (const [input, expected] of [[' Unit Code ','unitcode'],['Install Price ($)','installprice'],['WORK-TYPE','worktype'],['','']]) if (core.normalizeImportHeader(input) !== expected) throw new Error('normalizeImportHeader() parity failed.');
for (const [[left,right], expected] of [[['unitcode','unitcode'],0],[['unitcode','unitcod'],1],[['price','prize'],1],[['','abc'],3]]) if (core.importEditDistance(left,right) !== expected) throw new Error('importEditDistance() parity failed.');
for (const [[value,aliases], expected] of [[['Unit Code',['unitcode','itemcode']],1],[['Unit Code Number',['unitcode','itemcode']],.92],[['Unutcode',['unitcode','itemcode']],.82],[['Completely Different',['unitcode','itemcode']],0],[['',['unitcode']],0]]) if (core.importHeaderMatchConfidence(value,aliases) !== expected) throw new Error('importHeaderMatchConfidence() parity failed.');
for (const [[value,itemCode], expected] of [[['Transfer',''],'transfer'],[['xfer',''],'transfer'],[['Remove',''],'retirement'],[['Retirement',''],'retirement'],[['Install',''],'install'],[['','CV3030I'],'install'],[['','OH4112R'],'retirement'],[['','PS1095T'],'transfer'],[['','ANCHOR'],''],[['','CONDUIT'],''],[['Mystery','ABC123'],'unknown']]) if (core.normalizedPriceWorkType(value,itemCode) !== expected) throw new Error('normalizedPriceWorkType() parity failed.');

const row = { 'Unit Code':'OH4112R', 'Install Price ($)':'$1,250.50', Description:'Test row' };
if (core.importCell(row,['unitcode','itemcode']) !== 'OH4112R') throw new Error('importCell() failed normalized alias lookup.');
if (core.importCell(row,['transferprice']) !== '') throw new Error('importCell() must return an empty string when no alias matches.');
for (const [input, expected] of [['',0],[null,0],[undefined,0],['$1,250.50',1250.5],[' ( 450.25 ) ',-450.25],['25',25]]) if (!Object.is(core.importPrice(input),expected)) throw new Error(`importPrice(${JSON.stringify(input)}) parity failed.`);
if (!Number.isNaN(core.importPrice('not-a-price'))) throw new Error('importPrice() must preserve invalid numeric input as NaN.');
for (const [input, expected] of [['',null],['   ',null],[null,null],[undefined,null],['$1,250.50',1250.5],['0',0],[0,0],['25',25],['(25)',null],['-1',null],['not-a-price',null]]) if (!Object.is(core.numericImportPrice(input),expected)) throw new Error(`numericImportPrice(${JSON.stringify(input)}) parity failed.`);
for (const [index, expected] of [[0,'A'],[25,'Z'],[26,'AA'],[51,'AZ'],[52,'BA'],[701,'ZZ'],[702,'AAA']]) if (core.spreadsheetColumnName(index) !== expected) throw new Error(`spreadsheetColumnName(${index}) parity failed.`);
for (const [left,right,expected] of [['ABC','ABC',false],[' ABC ','ABC',false],[null,'',false],[undefined,' ',false],[100,'100',false],['100','101',true],['Install','install',true]]) {
  const actual = core.priceBookComparisonValueChanged(left,right);
  if (actual !== expected) throw new Error(`priceBookComparisonValueChanged(${JSON.stringify(left)}, ${JSON.stringify(right)}) returned ${actual}; expected ${expected}.`);
}
for (const [file, expected] of [
  [null,'0:0'],
  [{name:'pricing.xlsx',size:12345,lastModified:1700000000000},'pricing.xlsx:12345:1700000000000'],
  [{name:'',size:0,lastModified:0},':0:0'],
  [{name:'units.csv',size:'42',lastModified:'99'},'units.csv:42:99']
]) {
  const actual = core.newPriceBookFileSignature(file);
  if (actual !== expected) throw new Error(`newPriceBookFileSignature(${JSON.stringify(file)}) returned ${actual}; expected ${expected}.`);
}

for (const name of helperNames) if (sandbox.window[name] !== core[name]) throw new Error(`Price Book compatibility bridge ${name} is not active.`);
if (!bootstrap.includes("script.src = '/price-book-core.js?v=20260910a'")) throw new Error('Price Book core module is not bootstrapped by the existing front-end loader path.');
if (!bootstrap.includes('Price Book core module unavailable; using inline compatibility fallback.')) throw new Error('Price Book core loader must retain an explicit inline fallback path.');
if (!serviceWorker.includes("'/price-book-core.js?v=20260910a'")) throw new Error('Price Book core module must remain in the offline app shell.');
for (const signature of ['function normalizeImportHeader(value){','function importEditDistance(left,right){','function importHeaderMatchConfidence(value,aliases){',"function normalizedPriceWorkType(value,itemCode=''){",'function importCell(row, aliases){','function importPrice(value){','function numericImportPrice(value){','function spreadsheetColumnName(columnIndex){','function priceBookComparisonValueChanged(left, right){','function newPriceBookFileSignature(file){']) {
  const compactSignature = signature.replace(', ', ',');
  if (!index.includes(signature) && !index.includes(compactSignature)) throw new Error(`Legacy inline Price Book fallback missing: ${signature}`);
}
if (!index.includes("const suffixMatch=String(itemCode || '').trim().toUpperCase().match(/[0-9]([IRT])$/);")) throw new Error('Legacy unit-code suffix behavior must remain during staged extraction.');

console.log('Price Book core modularization guard passed.');
console.log('- import parsing, prices, spreadsheet columns, comparison values, and file signatures match legacy behavior');
console.log('- compatibility bridges, offline cache, and inline fallbacks remain active');
