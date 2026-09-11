import fs from 'node:fs';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

const root = process.cwd();
const htmlPath = path.join(root, 'index.html');
if (!fs.existsSync(htmlPath)) throw new Error('index.html is missing.');
const html = fs.readFileSync(htmlPath, 'utf8');
const failures = [];

function fail(message){ failures.push(message); }

// Duplicate static IDs are a common source of handlers updating the wrong control.
const idMatches = [...html.matchAll(/\bid=["']([^"']+)["']/gi)].map(match => match[1]);
const idCounts = new Map();
for (const id of idMatches) idCounts.set(id, (idCounts.get(id) || 0) + 1);
const duplicateIds = [...idCounts.entries()].filter(([, count]) => count > 1);
if (duplicateIds.length) {
  fail('Duplicate static HTML ids: ' + duplicateIds.map(([id, count]) => `${id} (${count})`).join(', '));
}

// Static local scripts referenced by index.html must exist and must not be loaded twice.
const scriptSources = [...html.matchAll(/<script\b[^>]*\bsrc=["']([^"']+)["'][^>]*>/gi)].map(match => match[1]);
const normalizedLocalScripts = scriptSources
  .filter(src => !/^(?:https?:)?\/\//i.test(src))
  .map(src => src.split('?')[0].split('#')[0].replace(/^\//, ''))
  .filter(Boolean);
const scriptCounts = new Map();
for (const src of normalizedLocalScripts) scriptCounts.set(src, (scriptCounts.get(src) || 0) + 1);
const duplicateScripts = [...scriptCounts.entries()].filter(([, count]) => count > 1);
if (duplicateScripts.length) {
  fail('Duplicate local script loads: ' + duplicateScripts.map(([src, count]) => `${src} (${count})`).join(', '));
}
for (const src of normalizedLocalScripts) {
  if (!fs.existsSync(path.join(root, src))) fail(`Local script referenced by index.html is missing: ${src}`);
}

// Key application surfaces must remain unique so page switching cannot target the wrong element.
for (const id of ['authPage','dashboardPage','jobsPage','productionPage','safetyPage','priceBooksPage','teamPage','signOutBtn','dailyUnitPoleLocation']) {
  const count = idCounts.get(id) || 0;
  if (count !== 1) fail(`Critical element #${id} must appear exactly once in static HTML; found ${count}.`);
}

// Syntax-check every top-level front-end module. This catches broken production loads before merge.
const jsFiles = fs.readdirSync(root)
  .filter(name => name.endsWith('.js') && fs.statSync(path.join(root, name)).isFile())
  .sort();
for (const file of jsFiles) {
  try {
    execFileSync(process.execPath, ['--check', file], { cwd: root, stdio: 'pipe' });
  } catch (error) {
    fail(`JavaScript syntax check failed for ${file}: ${String(error.stderr || error.message).trim()}`);
  }
}

// Guard the shared shell against accidental duplicate map-module injection.
if (fs.existsSync(path.join(root, 'responsive-role-shell.js'))) {
  const shell = fs.readFileSync(path.join(root, 'responsive-role-shell.js'), 'utf8');
  const loaderCount = (shell.match(/job-map-documents\.js/g) || []).length;
  if (loaderCount > 1) fail(`job-map-documents.js loader must be declared once; found ${loaderCount}.`);
}

if (failures.length) {
  console.error('Front-end stability guardrails failed:\n- ' + failures.join('\n- '));
  process.exit(1);
}
console.log(`Front-end stability guardrails passed (${idMatches.length} static IDs, ${jsFiles.length} top-level JS modules checked).`);
