import fs from 'node:fs';

const timekeeping = fs.readFileSync('timekeeping.js','utf8');
const workspace = fs.readFileSync('role-workspace-polish.js','utf8');
const shell = fs.readFileSync('responsive-role-shell.js','utf8');
const failures = [];
const assert = (condition, message) => { if (!condition) failures.push(message); };

assert(timekeeping.includes("section.id = 'timekeepingPage'"), 'Timekeeping must remain its own top-level page.');
assert(timekeeping.includes('main.appendChild(section);'), 'Timekeeping page must attach directly under <main>.');
assert(timekeeping.includes('<h2>Timekeeping / Roster</h2>'), 'Timekeeping workspace title is missing.');

const expectedTabs = [
  ['roster','Roster'],
  ['equipment','Equipment'],
  ['entry','Enter Time'],
  ['reports','Time Reports'],
  ['payroll','Payroll']
];
for (const [key,label] of expectedTabs) {
  assert(timekeeping.includes(`data-tk-tab="${key}"`) && timekeeping.includes(`>${label}</button>`), `Timekeeping tab missing or renamed: ${label}`);
}

assert(timekeeping.includes("entry:()=>['gf','superintendent','admin','manager','owner'].includes(role())"), 'Enter Time role boundary changed unexpectedly.');
assert(timekeeping.includes('roster:()=>canManageRoster()'), 'Roster role boundary changed unexpectedly.');
assert(timekeeping.includes('equipment:()=>canManageRoster()'), 'Equipment role boundary changed unexpectedly.');

for (const mapping of [
  "priceBooksTile:'priceBooksPage'",
  "timekeepingTile:'timekeepingPage'"
]) assert(workspace.includes(mapping), `Workspace tile mapping missing: ${mapping}`);

assert(shell.includes("priceBooksPage: 'priceBooksTile'"), 'Desktop shell must map Price Books to the Price Books tile.');
assert(shell.includes("timekeepingPage: 'timekeepingTile'"), 'Desktop shell must map Timekeeping to the Timekeeping tile.');
assert(!shell.includes("timekeepingPage: 'priceBooksTile'"), 'Desktop shell must never map Timekeeping into Price Books.');
assert(!shell.includes("priceBooksPage: 'timekeepingTile'"), 'Desktop shell must never map Price Books into Timekeeping.');

for (const role of ['admin','manager','owner','superintendent']) {
  const roleStart = workspace.indexOf(`${role}:{`);
  assert(roleStart >= 0, `Workspace plan missing for ${role}.`);
  if (roleStart >= 0) {
    const slice = workspace.slice(roleStart, roleStart + 500);
    assert(slice.includes("'timekeepingTile'"), `${role} workspace must include Timekeeping.`);
    assert(slice.includes("'priceBooksTile'"), `${role} workspace must include Price Books.`);
  }
}

const foremanStart = workspace.indexOf('foreman:{');
if (foremanStart >= 0) {
  const slice = workspace.slice(foremanStart, foremanStart + 500);
  assert(slice.includes("'timekeepingTile'"), 'Foreman workspace must keep Crew Time/Timekeeping access.');
  assert(slice.includes("hidden:['teamTile','priceBooksTile']"), 'Foreman workspace must keep Price Books hidden.');
} else failures.push('Foreman workspace plan missing.');

const safetyStart = workspace.indexOf('safety:{');
if (safetyStart >= 0) {
  const slice = workspace.slice(safetyStart, safetyStart + 500);
  assert(slice.includes("order:['safetyTile']"), 'Safety workspace must remain JSA-focused.');
  assert(slice.includes("'timekeepingTile'"), 'Safety workspace hidden list must continue excluding Timekeeping access.');
} else failures.push('Safety workspace plan missing.');

if (failures.length) {
  console.error('Workspace/navigation validation failed:\n- ' + failures.join('\n- '));
  process.exit(1);
}

console.log('Workspace/navigation regression guard passed.');
console.log('- Timekeeping remains a top-level workspace with five dedicated tabs');
console.log('- Price Books and Timekeeping retain distinct desktop/dashboard mappings');
console.log('- Role-specific visibility boundaries remain intact');
