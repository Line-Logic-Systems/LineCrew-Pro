import fs from 'node:fs';

const html = fs.readFileSync('index.html', 'utf8');
const failures = [];
const assert = (condition, message) => {
  if (!condition) failures.push(message);
};

assert(html.includes('<!DOCTYPE html>') || html.includes('<!doctype html>'), 'Missing HTML doctype.');
assert(html.includes('/* LINECREW PRO SUPABASE */'), 'Missing main application script marker.');
assert(html.includes('id="authPage"'), 'Missing authentication page.');
assert(html.includes('id="dashboardPage"'), 'Missing dashboard page.');
assert(html.includes('id="productionPage"'), 'Missing production page.');
assert(html.includes('id="jobsPage"'), 'Missing jobs page.');
assert(html.includes('id="priceBooksPage"'), 'Missing Price Books page.');
assert(html.includes('id="teamPage"'), 'Missing Team page.');
assert(html.includes('id="safetyPage"'), 'Missing Safety/JSA page.');
assert(html.includes('id="safetyJsaHistoryCard"'), 'Missing compact completed JSA history control.');
assert(html.includes('id="safetyJsaRecordSelect"'), 'Missing single-record Foreman JSA picker.');
assert(html.includes("'Reset to Today'"), 'Foreman JSA filters must reset to the current day.');
assert(html.includes('createSafetyJsaHistoryCard'), 'Missing reusable JSA history renderer.');
assert(html.includes('Crew Name / Number'), 'Daily Report crew identifier must be clearly labeled.');
assert(
  html.includes('await sb.auth.getUser()') &&
    html.includes('await sb.auth.refreshSession()') &&
    html.includes("await sb.auth.signOut({scope:'local'})") &&
    html.includes('Your secure session expired after an account security update.'),
  'Startup must recover from locally cached sessions invalidated by a signing-key rotation.'
);
assert(
  html.includes("sb.functions.invoke('notify-pilot-feedback'") &&
    html.includes('body:{feedback_id:feedbackId}') &&
    html.includes('Your feedback was saved and emailed to Support.'),
  'Pilot feedback must save first and then invoke the authenticated support email notifier.'
);

// Weekend pilot critical-role markers. These do not replace server-side policy tests;
// they prevent accidental removal of required UI wiring during rapid changes.
for (const marker of [
  "owner:'Owner'",
  "admin:'Admin'",
  "superintendent:'Superintendent'",
  "gf:'General Foreman'",
  "foreman:'Foreman'",
  'linecrew_set_member_role',
  'linecrew_set_superintendent_permissions',
  'linecrew_claim_initial_owner'
]) {
  assert(html.includes(marker), `Missing critical role/team marker: ${marker}`);
}

// Flexible JSA/mobile capture and the in-app multi-page viewer are core pilot flows.
for (const marker of [
  'jsa-attachment-viewer',
  'openUploadedJsaFiles',
  'Upload Company JSA',
  'Take JSA Photo'
]) {
  assert(html.includes(marker), `Missing critical JSA/mobile marker: ${marker}`);
}

// Real utility pricing workbooks often contain repeated side-by-side tables,
// section restarts, multiple sheets, and a description row below the priced row.
for (const marker of [
  'findStructuredPricingBlocks',
  'extractStructuredPricingRows',
  'analyzeStructuredPricingWorkbook',
  'All Recognized Unit Sheets',
  'constructionlaborprice',
  'removallaborprice',
  'installationcost',
  'retirementcost',
  'transfer-only rate',
  'fileCodeCounts'
]) {
  assert(html.includes(marker), `Missing smart Unit Pricing import marker: ${marker}`);
}
for (const marker of [
  'normalizedPriceWorkType',
  'importHeaderMatchConfidence',
  'combinedStructuredHeaderRow',
  'consolidatePriceBookImportRows',
  'mapWorkType',
  'xferlabor'
]) {
  assert(html.includes(marker), `Missing adaptive Unit Pricing import marker: ${marker}`);
}
for (const marker of [
  'jobMapTransferQuantity',
  'authorized-transfer',
  'save_job_package_authorized_unit_v2',
  'get_job_package_work_points_v2',
  'import_price_book_items_atomic',
  'transfer_quantity'
]) {
  assert(html.includes(marker), `Missing Utility Package Transfer marker: ${marker}`);
}

const transferMigrationPath =
  'supabase/migrations/20260831050000_smart_pricebook_and_packet_transfers.sql';
assert(fs.existsSync(transferMigrationPath), 'Missing packet Transfer database migration.');
if (fs.existsSync(transferMigrationPath)) {
  const transferMigration = fs.readFileSync(transferMigrationPath, 'utf8');
  for (const marker of [
    "work_type in ('install', 'transfer', 'remove')",
    "when 'transfer' then 'T'",
    'authorized_transfer_quantity',
    'validate_job_package_import',
    'import_job_package_units',
    'save_job_package_authorized_unit_v2',
    'get_job_package_work_points_v2',
    'price_book_items_book_code_unique',
    'import_price_book_items_atomic',
    'for update',
    'from public, anon'
  ]) {
    assert(
      transferMigration.includes(marker),
      `Missing guarded packet Transfer migration marker: ${marker}`
    );
  }
}

const ids = [...html.matchAll(/\sid=["']([^"']+)["']/g)].map(match => match[1]);
const duplicateIds = [...new Set(ids.filter((id, index) => ids.indexOf(id) !== index))];
assert(duplicateIds.length === 0, 'Duplicate HTML ids: ' + duplicateIds.join(', '));

const scriptStart = html.indexOf('/* LINECREW PRO SUPABASE */');
const scriptEnd = html.indexOf('</script>', scriptStart);
if (scriptStart >= 0 && scriptEnd > scriptStart) {
  const applicationCode = html.slice(scriptStart, scriptEnd);
  try {
    new Function(applicationCode);
  } catch (error) {
    failures.push('Application JavaScript syntax error: ' + error.message);
  }
  try {
    const coreStart = applicationCode.indexOf('function normalizeImportHeader');
    const coreEnd = applicationCode.indexOf('function loadImportWorksheet');
    const coreCode = applicationCode.slice(coreStart, coreEnd);
    const testElements = new Map();
    const testElement = id => {
      if (!testElements.has(id)) {
        testElements.set(id, {
          value: id === 'priceBookImportMode' ? 'add-only' : '',
          innerHTML: '',
          textContent: '',
          classList: { add() {}, remove() {}, toggle() {} }
        });
      }
      return testElements.get(id);
    };
    const core = new Function(
      '$',
      'currentPriceBookItems',
      coreCode +
      '; return {importHeaderMatchConfidence,mapImportRow,' +
      'consolidatePriceBookImportRows,normalizedPriceWorkType,' +
      'findStructuredPricingBlocks,extractStructuredPricingRows};'
    )(testElement, []);
    assert(
      core.importHeaderMatchConfidence('Instal Price', ['installprice']) >= 0.8,
      'Smart Price Book import must recognize a close Install heading.'
    );
    assert(
      core.importHeaderMatchConfidence('Xfer Labor', ['xferlabor']) === 1,
      'Smart Price Book import must recognize Xfer Labor.'
    );
    const longRows = [
      core.mapImportRow({
        'Unit Code':'A-10',
        'Description':'Pole framing',
        'Unit Price':'125.00',
        'Work Type':'Install'
      }, 2),
      core.mapImportRow({
        'Unit Code':'A-10',
        'Description':'Pole framing',
        'Unit Price':'75.00',
        'Work Type':'Transfer'
      }, 3),
      core.mapImportRow({
        'Unit Code':'A-10',
        'Description':'Pole framing',
        'Unit Price':'40.00',
        'Work Type':'Remove'
      }, 4)
    ];
    const consolidated = core.consolidatePriceBookImportRows(longRows);
    assert(
      consolidated.length === 1 &&
      consolidated[0].install_price === 125 &&
      consolidated[0].transfer_price === 75 &&
      consolidated[0].retirement_price === 40 &&
      consolidated[0].errors.length === 0,
      'Long-format Install/Transfer/Remove rows must consolidate safely.'
    );
    const conflictRows = core.consolidatePriceBookImportRows([
      core.mapImportRow({
        'Unit Code':'A-11','Description':'Anchor',
        'Unit Price':'50','Work Type':'Transfer'
      }, 5),
      core.mapImportRow({
        'Unit Code':'A-11','Description':'Anchor',
        'Unit Price':'60','Work Type':'Transfer'
      }, 6)
    ]);
    assert(
      conflictRows[0].errors.some(error => error.includes('Conflicting Transfer Prices')),
      'Conflicting action prices must be blocked instead of silently merged.'
    );
    const priceLeftBlocks = core.findStructuredPricingBlocks([
      ['Install Price','Unit Code','Description'],
      ['125.00','A-12','Crossarm']
    ]);
    assert(
      priceLeftBlocks.length === 1 &&
      priceLeftBlocks[0].codeColumn === 1 &&
      priceLeftBlocks[0].installColumn === 0,
      'Structured pricing must recognize a price column left of Unit Code.'
    );
    const multiHeaderBlocks = core.findStructuredPricingBlocks([
      ['Unit Code','Labor Rates',''],
      ['', 'Instal Price','Xfer Labor'],
      ['A-13','100','65']
    ]);
    assert(
      multiHeaderBlocks.length === 1 &&
      multiHeaderBlocks[0].installColumn === 1 &&
      multiHeaderBlocks[0].transferColumn === 2,
      'Structured pricing must recognize merged/multi-row action headings.'
    );
    const longStructured = core.extractStructuredPricingRows('Long Rates',[
      ['Unit Code','Description','Work Type','Rate'],
      ['A-14','Transformer','Install','900'],
      ['A-14','Transformer','Transfer','425'],
      ['A-14','Transformer','Remove','300']
    ]);
    const longStructuredMapped = core.consolidatePriceBookImportRows(
      longStructured.rows.map(entry => core.mapImportRow(entry.row,entry.rowNumber))
    );
    assert(
      longStructuredMapped.length === 1 &&
      longStructuredMapped[0].install_price === 900 &&
      longStructuredMapped[0].transfer_price === 425 &&
      longStructuredMapped[0].retirement_price === 300,
      'Structured long-format pricing must consolidate all three actions.'
    );
  } catch (error) {
    failures.push('Smart Price Book functional validation error: ' + error.message);
  }
}

// Extension scripts are validated independently so additional script tags do not
// become part of the main inline application parse window.
if (fs.existsSync('expanded-jsa.js')) {
  const expandedJsaCode = fs.readFileSync('expanded-jsa.js', 'utf8');
  try {
    new Function(expandedJsaCode);
  } catch (error) {
    failures.push('Expanded JSA JavaScript syntax error: ' + error.message);
  }
  assert(
    expandedJsaCode.includes("load('timekeeping-input-v2.js"),
    'Foreman Crew Time must load Start/Stop, lunch, per diem, and equipment controls.'
  );
  const timekeepingInputCode = fs.readFileSync('timekeeping-input-v2.js', 'utf8');
  const timekeepingCode = fs.readFileSync('timekeeping.js', 'utf8');
  const roleWorkspaceCode = fs.readFileSync('role-workspace-polish.js', 'utf8');
  assert(
    expandedJsaCode.includes("'linecrew-timekeeping-input-v2'") &&
      timekeepingInputCode.includes("row.dataset.tkLaunchDetails==='1'&&detailIsComplete") &&
      timekeepingInputCode.includes('existingDetail?.remove()'),
    'Foreman Crew Time must prevent duplicate enhancement loads and repair incomplete first-load rows.'
  );
  assert(
    timekeepingCode.includes("row.dataset.tkLaunchDetails='1'") &&
      timekeepingCode.includes('class="tk-start tk-clock24"') &&
      timekeepingCode.includes('class="tk-stop tk-clock24"') &&
      timekeepingCode.includes('class="tk-lunch"') &&
      timekeepingCode.includes('class="tk-equipment"') &&
      timekeepingCode.includes('class="tk-per-diem"'),
    'Core Foreman Crew Time rows must render every military-time control before enhancement or refresh.'
  );
  assert(
    !roleWorkspaceCode.includes("Enter each crew member's Regular and OT hours"),
    'Role workspace polish must not restore the obsolete Regular/OT Crew Time instructions.'
  );
  assert(
    expandedJsaCode.includes("load('leadership-my-time.js"),
    'GF, Superintendent, Admin, and Owner My Time must load with Timekeeping.'
  );
}

if (fs.existsSync('leadership-my-time.js')) {
  const leadershipMyTimeCode = fs.readFileSync('leadership-my-time.js', 'utf8');
  try {
    new Function(leadershipMyTimeCode);
  } catch (error) {
    failures.push('Leadership My Time JavaScript syntax error: ' + error.message);
  }
  assert(
    leadershipMyTimeCode.includes("rpc('upsert_my_leadership_time'") &&
      leadershipMyTimeCode.includes('Recent My Time'),
    'Leadership My Time must save through the guarded RPC and show recent entries.'
  );
}

if (fs.existsSync('jsa-signatures.js')) {
  const signatureCode = fs.readFileSync('jsa-signatures.js', 'utf8');
  assert(
    signatureCode.includes('setPointerCapture') &&
      signatureCode.includes("'touchmove'") &&
      signatureCode.includes('passive:false'),
    'JSA signature pads must capture drawing gestures without scrolling the page.'
  );
}

if (fs.existsSync('role-workspace-polish.js')) {
  const roleWorkspaceCode = fs.readFileSync('role-workspace-polish.js', 'utf8');
  try {
    new Function(roleWorkspaceCode);
  } catch (error) {
    failures.push('Role workspace JavaScript syntax error: ' + error.message);
  }
  assert(
    roleWorkspaceCode.includes('tilesNeedReordering'),
    'Role workspace must avoid continuously re-appending dashboard tiles.'
  );
  assert(
    roleWorkspaceCode.includes('observer?.disconnect()') &&
      roleWorkspaceCode.includes('finally{') &&
      roleWorkspaceCode.includes('observe();'),
    'Role workspace must not observe its own dashboard mutations.'
  );
}

if (fs.existsSync('training/training-center.js')) {
  const trainingCenterCode = fs.readFileSync('training/training-center.js', 'utf8');
  try {
    new Function(trainingCenterCode);
  } catch (error) {
    failures.push('Training Center JavaScript syntax error: ' + error.message);
  }
  assert(
    trainingCenterCode.includes('New training videos are being added') &&
      trainingCenterCode.includes('The previous videos were retired after recent LineCrew Pro updates.'),
    'The Training Center must explain the temporary empty state after legacy videos are retired.'
  );
}

const forbiddenSecrets = [
  ['Supabase service-role key reference', /service[_-]?role/i],
  ['OpenAI API key reference', /OPENAI_API_KEY|sk-proj-/],
  ['Supabase secret key', /sb_secret_/i]
];
for (const [label, pattern] of forbiddenSecrets) {
  assert(!pattern.test(html), label + ' found in public index.html.');
}

if (failures.length) {
  console.error('LineCrew Pro validation failed:');
  failures.forEach(failure => console.error('- ' + failure));
  process.exit(1);
}

console.log('LineCrew Pro validation passed.');
console.log('- JavaScript syntax is valid');
console.log('- Required application pages are present');
console.log('- Owner/Admin/Superintendent/GF/Foreman team wiring is present');
console.log('- Flexible JSA camera/viewer wiring is present');
console.log('- Multi-table and multi-sheet Unit Pricing import wiring is present');
console.log('- Adaptive wide/long Unit Pricing import behavior is verified');
console.log('- Utility Package Transfer wiring is present');
console.log('- HTML ids are unique');
console.log('- No known server-side secret patterns are exposed');
