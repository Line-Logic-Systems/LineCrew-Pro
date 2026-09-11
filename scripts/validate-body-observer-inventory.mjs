import fs from 'node:fs';
import path from 'node:path';

const root = process.cwd();
const files = fs.readdirSync(root)
  .filter(name => name.endsWith('.js') && fs.statSync(path.join(root, name)).isFile())
  .sort();

// Whole-body observers are intentionally tracked here so their count cannot grow unnoticed.
// Temporary attach observers are allowed only when they disconnect after locating a dynamic root.
const temporaryAttachAllowlist = new Set([
  'custom-time-export.js',
  'dark-contrast-draft-edit-fix.js',
  'jsa-signatures.js',
  'timekeeping-polish.js',
  'timekeeping-roster.js'
]);

// Legacy long-lived whole-app observers. Each item must be removed deliberately behind regression coverage.
const legacyLongLivedAllowlist = new Set([
  'app-polish.js',
  'foreman-field-tools.js',
  'gf-crew-scope.js',
  'gf-review-theme-enhancements.js',
  'leadership-my-time.js',
  'responsive-role-shell.js',
  'role-workspace-polish.js',
  'timekeeping-input-v2.js',
  'timekeeping-pay-period-history.js',
  'timekeeping-payroll.js',
  'timekeeping-report-v2.js',
  'timekeeping.js'
]);

const allowed = new Set([...temporaryAttachAllowlist, ...legacyLongLivedAllowlist]);
const bodyObservePattern = /\.observe\s*\(\s*document\.body\b/g;
const found = [];

for (const file of files) {
  const source = fs.readFileSync(path.join(root, file), 'utf8');
  const matches = [...source.matchAll(bodyObservePattern)];
  if (!matches.length) continue;
  found.push({ file, count: matches.length });
}

const unexpected = found.filter(item => !allowed.has(item.file));
if (unexpected.length) {
  throw new Error('New whole-app MutationObserver(s) detected without review: ' + unexpected.map(item => `${item.file} (${item.count})`).join(', '));
}

const duplicateAttachments = found.filter(item => item.count > 1);
if (duplicateAttachments.length) {
  throw new Error('Existing whole-app observer file gained duplicate document.body attachments: ' + duplicateAttachments.map(item => `${item.file} (${item.count})`).join(', '));
}

const missingLegacy = [...legacyLongLivedAllowlist].filter(file => !found.some(item => item.file === file));
if (missingLegacy.length) {
  console.log('Legacy whole-app observer(s) removed since inventory baseline:', missingLegacy.join(', '));
}

const total = found.reduce((sum, item) => sum + item.count, 0);
const expectedMaximum = allowed.size;
if (total > expectedMaximum) {
  throw new Error(`Whole-app observer count exceeded reviewed baseline: ${total} > ${expectedMaximum}.`);
}

console.log(`Whole-app observer inventory: ${total} direct document.body observer attachment(s) across ${found.length} file(s).`);
for (const item of found) {
  const kind = temporaryAttachAllowlist.has(item.file) ? 'temporary attach' : 'legacy long-lived';
  console.log(`- ${item.file}: ${item.count} (${kind})`);
}
console.log(`Observer inventory validation passed; reviewed maximum remains ${expectedMaximum}.`);
