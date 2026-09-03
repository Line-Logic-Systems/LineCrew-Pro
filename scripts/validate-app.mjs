import fs from 'node:fs';
import vm from 'node:vm';

const html = fs.readFileSync('index.html', 'utf8');
const failures = [];
const assert = (condition, message) => {
  if (!condition) failures.push(message);
};

const extractNamedFunction = (source, name) => {
  const starts = [`async function ${name}(`, `function ${name}(`];
  const start = starts
    .map(marker => source.indexOf(marker))
    .find(index => index >= 0);
  if (start === undefined) return '';
  const bodyStart = source.indexOf('{', start);
  if (bodyStart < 0) return '';
  let depth = 0;
  let quote = '';
  let escaped = false;
  for (let index = bodyStart; index < source.length; index += 1) {
    const character = source[index];
    if (quote) {
      if (escaped) escaped = false;
      else if (character === '\\') escaped = true;
      else if (character === quote) quote = '';
      continue;
    }
    if (character === "'" || character === '"' || character === '`') {
      quote = character;
      continue;
    }
    if (character === '{') depth += 1;
    else if (character === '}' && --depth === 0) return source.slice(start, index + 1);
  }
  return '';
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
assert(
  html.includes('userVisibleOnly:true') &&
    html.includes('applicationServerKey:urlBase64ToUint8Array(VAPID_PUBLIC_KEY)'),
  'Push notification subscriptions must use a visible notification and the committed VAPID public key.'
);
const disablePushSource = extractNamedFunction(html, 'disablePushNotifications');
assert(
  disablePushSource.includes('await subscription.unsubscribe()') &&
    disablePushSource.includes("sb.rpc('linecrew_delete_push_subscription'"),
  'Disabling push notifications must unsubscribe the browser before deleting the caller-owned endpoint.'
);
assert(
  html.includes('/iPad|iPhone|iPod/.test(navigator.userAgent)') &&
    html.includes('add LineCrew Pro to your Home Screen first: Share → Add to Home Screen.'),
  'iPhone notification setup must require Home Screen installation before offering Enable.'
);
const loadAppSource = extractNamedFunction(html, 'loadApp');
assert(
  loadAppSource.includes('void loadPushNotificationStatus();') &&
    !loadAppSource.includes('loadPushNotificationStatus(),'),
  'Optional push status detection must run in the background and never block authenticated app startup.'
);
assert(
  html.includes('function pushPromiseWithTimeout(') &&
    html.includes("navigator.serviceWorker.register('/service-worker.js')") &&
    html.includes('Notification setup did not finish on this device.'),
  'Push setup must explicitly register the service worker and stop waiting with a useful timeout.'
);

const technicalErrorSource = extractNamedFunction(html, 'recordTechnicalError');
if (!technicalErrorSource) {
  failures.push('Missing executable application error recorder.');
} else {
  const telemetryCalls = [];
  const telemetryWarnings = [];
  const telemetryContext = {
    currentProfile:{ company_id:'company-test' },
    lastRecordedError:'',
    lastRecordedErrorAt:0,
    currentErrorPage:() => 'jobsPage',
    sb:{ rpc:async (name,args) => {
      telemetryCalls.push({ name,args });
      return { error:null };
    } },
    console:{ warn:(...args) => telemetryWarnings.push(args) }
  };
  try {
    vm.createContext(telemetryContext);
    vm.runInContext(technicalErrorSource, telemetryContext);
    await telemetryContext.recordTechnicalError('browser','uncaught_error','expected test error');
    assert(
      telemetryCalls.length === 1 &&
        telemetryCalls[0].name === 'record_app_error' &&
        telemetryCalls[0].args?.p_area === 'browser' &&
        telemetryCalls[0].args?.p_error_code === 'uncaught_error' &&
        telemetryCalls[0].args?.p_page === 'jobsPage' &&
        telemetryCalls[0].args?.p_message === 'expected test error',
      'Application errors must execute the record_app_error RPC with bounded context.'
    );

    telemetryContext.lastRecordedError = '';
    telemetryContext.sb.rpc = async () => { throw new Error('expected telemetry failure'); };
    await telemetryContext.recordTechnicalError('browser','uncaught_error','failure-path test');
    assert(
      telemetryWarnings.length === 1 &&
        String(telemetryWarnings[0][1]).includes('expected telemetry failure'),
      'Telemetry failures must be contained without creating an unhandled rejection.'
    );
  } catch (error) {
    failures.push(`Application error recorder validation failed: ${error.message}`);
  }
}

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
  'linecrew_claim_initial_owner',
  'linecrew_transfer_company_owner',
  'linecrew_admin_replace_company_owner',
  'Transfer Ownership',
  'Ownership Recovery'
]) {
  assert(html.includes(marker), `Missing critical role/team marker: ${marker}`);
}
const teamFunctionNames = [
  'currentUserRole',
  'userIsOwner',
  'formatTeamRole',
  'roleOptionsForMember',
  'canTransferOwnershipTo',
  'canAdminReplaceOwner',
  'transferCompanyOwnership',
  'replaceCompanyOwnerAsAdmin',
  'claimInitialOwner',
  'updateTeamMemberRole'
];
const teamFunctionSources = teamFunctionNames.map(name => extractNamedFunction(html, name));
if (teamFunctionSources.some(source => !source)) {
  failures.push('Missing executable Team role-management functions.');
} else {
  const teamContext = {
    currentProfile:{ id:'actor-admin', role:'admin' },
    alerts:[],
    teamLoads:0,
    appLoads:0,
    confirm:()=>true,
    alert:message => teamContext.alerts.push(String(message)),
    userCanManageRoles:()=>true,
    loadTeamMembers:async () => { teamContext.teamLoads += 1; },
    loadApp:async () => { teamContext.appLoads += 1; },
    sb:{ rpc:async () => ({ error:null }) }
  };
  try {
    vm.createContext(teamContext);
    teamFunctionSources.forEach(source => vm.runInContext(source, teamContext));
    const roleValues = member =>
      Array.from(teamContext.roleOptionsForMember(member), option => option[0]);
    const allManagedRoles = ['foreman','gf','superintendent','admin'];
    const lowerRoles = ['foreman','gf','superintendent'];
    const expectRoles = (actual, expected, message) =>
      assert(JSON.stringify(actual) === JSON.stringify(expected), message);

    teamContext.currentProfile = { id:'actor-admin', role:'admin' };
    lowerRoles.forEach(role => {
      expectRoles(
        roleValues({ id:`active-${role}`, role, active:true }),
        allManagedRoles,
        `Admin must be able to assign every managed role to an active ${role}.`
      );
    });
    expectRoles(
      roleValues({ id:'suspended-foreman', role:'foreman', active:false }),
      [],
      'Suspended team members must be restored before role controls are shown.'
    );
    expectRoles(
      roleValues({ id:'peer-admin', role:'admin', active:true }),
      [],
      'Admin must not change a peer Admin.'
    );
    expectRoles(
      roleValues({ id:'company-owner', role:'owner', active:true }),
      [],
      'Admin must not receive unsafe generic Owner role controls.'
    );
    assert(
      teamContext.canAdminReplaceOwner({ id:'company-owner', role:'owner', active:false }) &&
        !teamContext.canAdminReplaceOwner({ id:'peer-admin', role:'admin', active:true }) &&
        !teamContext.canAdminReplaceOwner({ id:'actor-admin', role:'owner', active:true }),
      'Admin ownership recovery must target only another current Owner, including an unavailable Owner.'
    );
    expectRoles(
      roleValues({ id:'actor-admin', role:'foreman', active:true }),
      [],
      'Team role controls must not allow self-role changes.'
    );

    teamContext.currentProfile = { id:'actor-owner', role:'owner' };
    expectRoles(
      roleValues({ id:'peer-admin', role:'admin', active:true }),
      allManagedRoles,
      'Owner must be able to manage an active Admin without assigning Owner generically.'
    );
    expectRoles(
      roleValues({ id:'suspended-admin', role:'admin', active:false }),
      [],
      'Owner must restore a suspended Admin before changing their role.'
    );
    assert(
      teamContext.canTransferOwnershipTo({ id:'peer-admin', role:'admin', active:true }) &&
        !teamContext.canTransferOwnershipTo({ id:'suspended-admin', role:'admin', active:false }) &&
        !teamContext.canTransferOwnershipTo({ id:'active-foreman', role:'foreman', active:true }),
      'Ownership transfer must be limited to another active Admin.'
    );

    const installDeferredRpc = () => {
      const calls = [];
      teamContext.sb.rpc = (name, args) => new Promise(resolve => {
        calls.push({ name, args, resolve });
      });
      return calls;
    };

    teamContext.teamLoads = 0;
    let calls = installDeferredRpc();
    const transferButton = { disabled:false, textContent:'Transfer Ownership' };
    const transferTarget = { id:'peer-admin', full_name:'Peer Admin', role:'admin', active:true };
    const firstTransfer = teamContext.transferCompanyOwnership(transferTarget, transferButton);
    const repeatedTransfer = teamContext.transferCompanyOwnership(transferTarget, transferButton);
    assert(
      calls.length === 1 &&
        calls[0].name === 'linecrew_transfer_company_owner' &&
        calls[0].args?.target_admin_id === transferTarget.id &&
        transferButton.disabled &&
        transferButton.textContent === 'Transferring...',
      'Ownership transfer must enter a single-flight pending state before awaiting the RPC.'
    );
    calls.forEach(call => call.resolve({ error:{ message:'expected transfer failure' } }));
    await Promise.all([firstTransfer, repeatedTransfer]);
    assert(
      !transferButton.disabled &&
        transferButton.textContent === 'Transfer Ownership' &&
        teamContext.teamLoads === 1,
      'Ownership transfer errors must restore the button and reload authoritative Team state.'
    );

    teamContext.currentProfile = { id:'actor-admin', role:'admin' };
    teamContext.teamLoads = 0;
    calls = installDeferredRpc();
    const recoveryOwner = { id:'company-owner', full_name:'Former Owner', role:'owner', active:false };
    const recoveryAdmin = { id:'actor-admin', full_name:'Current Admin', role:'admin', active:true };
    const recoveryButton = { disabled:false, textContent:'Change Owner & Transfer Ownership' };
    const replacementSelect = { disabled:false };
    const formerRoleSelect = { disabled:false };
    const firstRecovery = teamContext.replaceCompanyOwnerAsAdmin(
      recoveryOwner,
      recoveryAdmin,
      'superintendent',
      recoveryButton,
      replacementSelect,
      formerRoleSelect
    );
    const repeatedRecovery = teamContext.replaceCompanyOwnerAsAdmin(
      recoveryOwner,
      recoveryAdmin,
      'superintendent',
      recoveryButton,
      replacementSelect,
      formerRoleSelect
    );
    assert(
      calls.length === 1 &&
        calls[0].name === 'linecrew_admin_replace_company_owner' &&
        calls[0].args?.current_owner_id === recoveryOwner.id &&
        calls[0].args?.replacement_admin_id === recoveryAdmin.id &&
        calls[0].args?.former_owner_role === 'superintendent' &&
        recoveryButton.disabled &&
        replacementSelect.disabled &&
        formerRoleSelect.disabled &&
        recoveryButton.textContent === 'Recovering Ownership...',
      'Admin ownership recovery must submit one atomic handoff request and disable every control while pending.'
    );
    calls.forEach(call => call.resolve({ error:{ message:'expected recovery failure' } }));
    await Promise.all([firstRecovery, repeatedRecovery]);
    assert(
      !recoveryButton.disabled &&
        recoveryButton.textContent === 'Change Owner & Transfer Ownership' &&
        !replacementSelect.disabled &&
        !formerRoleSelect.disabled &&
        teamContext.teamLoads === 1,
      'Ownership recovery errors must restore all controls and reload authoritative Team state.'
    );

    teamContext.appLoads = 0;
    calls = installDeferredRpc();
    const successButton = { disabled:false, textContent:'Change Owner & Transfer Ownership' };
    const successRecovery = teamContext.replaceCompanyOwnerAsAdmin(
      recoveryOwner,
      recoveryAdmin,
      'admin',
      successButton,
      { disabled:false },
      { disabled:false }
    );
    calls[0].resolve({ error:null });
    await successRecovery;
    assert(
      teamContext.appLoads === 1,
      'An Admin who becomes Owner through recovery must reload the complete app with the new authority.'
    );

    teamContext.currentProfile = { id:'actor-admin', role:'admin' };
    calls = installDeferredRpc();
    const claimButton = { disabled:false, textContent:'Make Me Company Owner' };
    const firstClaim = teamContext.claimInitialOwner(claimButton);
    const repeatedClaim = teamContext.claimInitialOwner(claimButton);
    assert(
      calls.length === 1 &&
        calls[0].name === 'linecrew_claim_initial_owner' &&
        claimButton.disabled &&
        claimButton.textContent === 'Assigning Owner...',
      'Initial Owner claim must enter a single-flight pending state before awaiting the RPC.'
    );
    calls.forEach(call => call.resolve({ error:{ message:'expected claim failure' } }));
    await Promise.all([firstClaim, repeatedClaim]);
    assert(
      !claimButton.disabled && claimButton.textContent === 'Make Me Company Owner',
      'Initial Owner claim errors must restore the original button state.'
    );

    teamContext.teamLoads = 0;
    calls = installDeferredRpc();
    const saveButton = { disabled:false, textContent:'Save Role' };
    const roleSelect = { disabled:false };
    const roleTarget = { id:'active-foreman', full_name:'Active Foreman', role:'foreman', active:true };
    const firstSave = teamContext.updateTeamMemberRole(roleTarget, 'admin', saveButton, roleSelect);
    const repeatedSave = teamContext.updateTeamMemberRole(roleTarget, 'admin', saveButton, roleSelect);
    assert(
      calls.length === 1 &&
        calls[0].name === 'linecrew_set_member_role' &&
        calls[0].args?.target_user_id === roleTarget.id &&
        calls[0].args?.new_role === 'admin' &&
        saveButton.disabled &&
        roleSelect.disabled &&
        saveButton.textContent === 'Saving...',
      'Save Role must disable both controls and remain single-flight while its RPC is pending.'
    );
    calls.forEach(call => call.resolve({ error:{ message:'expected role failure' } }));
    await Promise.all([firstSave, repeatedSave]);
    assert(
      !saveButton.disabled &&
        !roleSelect.disabled &&
        saveButton.textContent === 'Save Role' &&
        teamContext.teamLoads === 1,
      'Save Role errors must restore both controls and reload authoritative Team state.'
    );

    const teamRendererStart = html.indexOf('async function loadTeamMembers(){');
    const teamRendererEnd = html.indexOf("$('manageFieldEmployeesBtn').onclick", teamRendererStart);
    const teamRenderer = teamRendererStart >= 0 && teamRendererEnd > teamRendererStart
      ? html.slice(teamRendererStart, teamRendererEnd)
      : '';
    assert(
      teamRenderer.includes('button.onclick = ()=>claimInitialOwner(button);') &&
        teamRenderer.includes('save.onclick=()=>updateTeamMemberRole(member,roleSelect.value,save,roleSelect);') &&
        teamRenderer.includes('transfer.onclick=()=>transferCompanyOwnership(member,transfer);') &&
        teamRenderer.includes('renderAdminOwnershipRecovery(member,members,card);'),
      'Rendered Team buttons must pass their controls into the single-flight handlers.'
    );
  } catch (error) {
    failures.push('Team role-management behavior regression test failed: ' + error.message);
  }
}

const dailyReportValueSummarySource = extractNamedFunction(html, 'dailyReportValueSummaryMarkup');
if (!dailyReportValueSummarySource) {
  failures.push('Missing executable Daily Report value summary renderer.');
} else {
  try {
    const reportContext = {
      canSeeActual:false,
      canSeeField:true,
      userCanSeeActualContractPrices:()=>reportContext.canSeeActual,
      userCanSeeFieldMoney:()=>reportContext.canSeeField,
      escapeHtml:value=>String(value),
      formatCurrency:value=>`$${Number(value).toFixed(2)}`,
      manHourRateNumberMarkup:value=>`<RATE>${Number(value).toFixed(2)}</RATE>`
    };
    vm.createContext(reportContext);
    vm.runInContext(dailyReportValueSummarySource, reportContext);
    const report = { regular_hours:10, overtime_hours:2 };
    const summary = {
      unit_line_count:1,
      has_adjustment:true,
      actual_total:1000,
      adjusted_total:460,
      visible_total:460
    };
    const foremanMarkup = reportContext.dailyReportValueSummaryMarkup(report, summary);
    assert(
      foremanMarkup.includes('Field MH Run Rate') &&
        foremanMarkup.includes('35.38') &&
        !foremanMarkup.includes('Actual MH Run Rate') &&
        !foremanMarkup.includes('76.92'),
      'Foreman Daily Reports must show the field MH run rate without exposing the actual MH run rate.'
    );
    reportContext.canSeeActual = true;
    const adminMarkup = reportContext.dailyReportValueSummaryMarkup(report, summary);
    assert(
      adminMarkup.includes('Actual MH Run Rate') &&
        adminMarkup.includes('76.92') &&
        adminMarkup.includes('Field MH Run Rate') &&
        adminMarkup.includes('35.38'),
      'Actual-pricing leadership must continue to see both actual and field MH run rates.'
    );
    reportContext.canSeeField = false;
    const actualOnlyMarkup = reportContext.dailyReportValueSummaryMarkup(report, summary);
    assert(
      actualOnlyMarkup.includes('Actual MH Run Rate') &&
        !actualOnlyMarkup.includes('Field MH Run Rate'),
      'Field Money disabled must hide the field MH run rate while preserving allowed actual money.'
    );
    reportContext.canSeeActual = false;
    const noMoneyMarkup = reportContext.dailyReportValueSummaryMarkup(report, summary);
    assert(
      noMoneyMarkup.includes('hidden by company permissions') &&
        !noMoneyMarkup.includes('MH Run Rate'),
      'Disabling both money permissions must hide every unit value and MH run rate.'
    );
  } catch (error) {
    failures.push('Daily Report value-summary behavior regression test failed: ' + error.message);
  }
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
  'fileCodeCounts',
  'id="newPriceBookFileCheck"',
  'inspectNewPriceBookImportFile',
  'spreadsheet rows were found.',
  'new-price-book-inline-mapping',
  'showNewPriceBookInlineMapping',
  'restorePriceBookColumnMappings(newPriceBookPendingMappings)',
  'loadImportWorksheet(newPriceBookPendingWorksheet)',
  'newPriceBookInlineMappingTask',
  'newPriceBookPreSaveMappingActive ? [] : currentPriceBookItems',
  'validRows.length === 0 || newPriceBookPreSaveMappingActive',
  "$('manageExistingContracts').open = true;",
  "currentOpenPriceBook?.id === priceBookId",
  "!$('priceBookImportCard').classList.contains('hidden')"
]) {
  assert(html.includes(marker), `Missing smart Unit Pricing import marker: ${marker}`);
}

// Step 4 Review must reveal the already-loaded import without reopening the
// Price Book, because openPriceBook() intentionally resets pending import state.
const reviewHandlerStart = html.indexOf("$('reviewSetupPriceBookBtn').onclick = () => {");
const reviewHandlerEnd = html.indexOf("$('finishContractSetupBtn').onclick = () => {", reviewHandlerStart);
if (reviewHandlerStart < 0 || reviewHandlerEnd < 0) {
  failures.push('Missing executable Step 4 Review Unit Pricing handler.');
} else {
  const reviewHandlerCode = html.slice(reviewHandlerStart, reviewHandlerEnd);
  const classList = (...classes) => {
    const values = new Set(classes);
    return {
      add: value => values.add(value),
      remove: value => values.delete(value),
      contains: value => values.has(value)
    };
  };
  let scrolledTarget = '';
  let openCalls = 0;
  const pendingRows = [{ item_code:'PL2000R' }];
  const elements = {
    reviewSetupPriceBookBtn:{ onclick:null },
    contractSetupReview:{ dataset:{ priceBookId:'pb-review' } },
    manageExistingContracts:{ open:false },
    priceBookDetail:{
      dataset:{ priceBookId:'pb-review' },
      classList:classList('hidden'),
      scrollIntoView:()=>{ scrolledTarget='detail'; }
    },
    priceBookImportCard:{
      classList:classList(),
      scrollIntoView:()=>{ scrolledTarget='import'; }
    },
    mapUnitCode:{ value:'Work Unit' },
    confirmPriceBookImportBtn:{ classList:classList() }
  };
  const getElement = id => elements[id];
  try {
    const installHandler = new Function(
      '$',
      'currentOpenPriceBook',
      'currentPriceBookImportRows',
      'priceBookNavigationRecords',
      'openPriceBook',
      'alert',
      `${reviewHandlerCode}; return $('reviewSetupPriceBookBtn').onclick;`
    );
    const handler = installHandler(
      getElement,
      { id:'pb-review' },
      pendingRows,
      new Map(),
      ()=>{ openCalls += 1; },
      ()=>{}
    );
    handler();
    assert(elements.manageExistingContracts.open, 'Step 4 Review must open Manage Existing Contracts.');
    assert(scrolledTarget === 'import', 'Step 4 Review must scroll to the pending import preview.');
    assert(openCalls === 0, 'Step 4 Review must not reopen and reset the current Price Book.');
    assert(pendingRows.length === 1, 'Step 4 Review must preserve pending import rows.');
    assert(elements.mapUnitCode.value === 'Work Unit', 'Step 4 Review must preserve column mappings.');
    assert(!elements.confirmPriceBookImportBtn.classList.contains('hidden'), 'Step 4 Review must preserve the Import button state.');
  } catch (error) {
    failures.push('Step 4 Review handler regression test failed: ' + error.message);
  }
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

// A Job Jacket can be supplied while the job is first created. Keep the
// picker optional so an Admin can still create the job and add a jacket later.
const createJobPacketInput = html.match(
  /<input\b(?=[^>]*\bid=["']createJobPacketFile["'])[^>]*>/i
)?.[0] || '';
assert(createJobPacketInput, 'Missing same-page Create Job jacket picker.');
assert(
  /accept=["']\.pdf,\.csv,\.tsv,\.txt,\.xlsx,\.xls,\.ods["']/i.test(createJobPacketInput),
  'Create Job jacket picker must accept every supported PDF/spreadsheet format.'
);
assert(
  !/\srequired(?:\s|=|>)/i.test(createJobPacketInput),
  'Create Job jacket picker must remain optional.'
);
assert(
  html.includes('Job Jacket / Utility Packet (optional)') &&
    html.includes('Create Job & Review Jacket'),
  'Create Job must clearly identify the optional jacket review flow.'
);

// Exercise the shared validation/router used by both the Create Job picker
// and the existing-job "+ Add Job Packet" picker.
const packetHelpersStart = html.indexOf('function jobPacketFileValidationMessage');
const packetHelpersEnd = html.indexOf('function chooseJobPacketFileForJob', packetHelpersStart);
if (packetHelpersStart < 0 || packetHelpersEnd < 0) {
  failures.push('Missing executable Job Jacket file validation/router helpers.');
} else {
  const packetHelpersCode = html.slice(packetHelpersStart, packetHelpersEnd);
  const packetCalls = [];
  const packetAlerts = [];
  try {
    const packetHelpers = new Function(
      'alert',
      'document',
      'showJobDetail',
      'parsePdfJobPacketForJob',
      'showJobPackageForm',
      'handleJobPackageImportFile',
      `let currentOpenJobId = null;\n${packetHelpersCode}\n` +
        'return {' +
        'jobPacketFileValidationMessage,handleJobPacketFileForJob,' +
        'getCurrentOpenJobId:()=>currentOpenJobId' +
        '};'
    )(
      message => packetAlerts.push(message),
      { getElementById: () => null },
      job => packetCalls.push(['detail', job]),
      async (job, file) => packetCalls.push(['pdf', job, file]),
      (job, options) => packetCalls.push(['form', job, options]),
      async file => packetCalls.push(['sheet', file])
    );
    const packetJob = { id:'job-packet-test', job_number:'TEST-100' };
    const pdfFile = { name:'FIELD-JACKET.PDF', size:20 * 1024 * 1024 };
    const sheetFile = { name:'authorized-units.xlsx', size:1234 };

    assert(
      packetHelpers.jobPacketFileValidationMessage(pdfFile) === '' &&
        packetHelpers.jobPacketFileValidationMessage(sheetFile) === '',
      'Supported Job Jacket files must pass validation.'
    );
    assert(
      packetHelpers.jobPacketFileValidationMessage({
        name:'too-large.pdf',
        size:20 * 1024 * 1024 + 1
      }).includes('20 MB'),
      'Job Jacket validation must reject PDFs larger than 20 MB.'
    );
    assert(
      packetHelpers.jobPacketFileValidationMessage({ name:'jacket.zip', size:1 }) !== '',
      'Job Jacket validation must reject unsupported file formats.'
    );

    await packetHelpers.handleJobPacketFileForJob(packetJob, pdfFile);
    assert(
      packetCalls.map(call => call[0]).join(',') === 'detail,pdf' &&
        packetCalls[1][1] === packetJob &&
        packetCalls[1][2] === pdfFile,
      'PDF jackets must route only to structured PDF review for the selected job.'
    );
    assert(
      packetHelpers.getCurrentOpenJobId() === packetJob.id,
      'Job Jacket review must preserve the selected job id.'
    );

    packetCalls.length = 0;
    await packetHelpers.handleJobPacketFileForJob(packetJob, sheetFile);
    assert(
      packetCalls.map(call => call[0]).join(',') === 'detail,form,sheet' &&
        packetCalls[1][2]?.inline === true &&
        packetCalls[1][2]?.fileName === sheetFile.name &&
        packetCalls[2][1] === sheetFile,
      'Spreadsheet jackets must open inline mapping and read the exact selected file.'
    );

    packetCalls.length = 0;
    packetAlerts.length = 0;
    const invalidRoute = await packetHelpers.handleJobPacketFileForJob(
      packetJob,
      { name:'jacket.exe', size:1 }
    );
    assert(
      invalidRoute === false && packetCalls.length === 0 && packetAlerts.length === 1,
      'Invalid Job Jacket files must stop before any parser or import flow runs.'
    );
  } catch (error) {
    failures.push('Job Jacket file routing regression test failed: ' + error.message);
  }
}

// Spreadsheet parsing is asynchronous and the shared import state must belong
// to the newest selection. A slower, stale read must not overwrite the newer
// workbook or leave its contents paired with the newer filename.
const packetSpreadsheetStateStart = html.indexOf(
  'let currentJobPackageImportWorkbook = null;'
);
const packetSpreadsheetStateEnd = html.indexOf(
  'let currentUtilityPacketImportId',
  packetSpreadsheetStateStart
);
const packetSpreadsheetReaderStart = html.indexOf(
  'async function handleJobPackageImportFile'
);
const packetSpreadsheetReaderEnd = html.indexOf(
  "$('jobPackageImportFile').onchange",
  packetSpreadsheetReaderStart
);
if (
  packetSpreadsheetStateStart < 0 || packetSpreadsheetStateEnd < 0 ||
  packetSpreadsheetReaderStart < 0 || packetSpreadsheetReaderEnd < 0
) {
  failures.push('Missing executable Job Jacket spreadsheet reader.');
} else {
  try {
    const spreadsheetElements = {
      jobPackageImportWorksheet:{ innerHTML:'', appendChild:()=>{} },
      jobPackageImportWorksheetWrap:{ classList:{ toggle:()=>{} } },
      jobPackageImportMapping:{ classList:{ add:()=>{} } },
      previewJobPackageImportBtn:{ classList:{ add:()=>{} } },
      confirmJobPackageImportBtn:{ classList:{ add:()=>{} } },
      jobPackageImportPreview:{ innerHTML:'' },
      jobPackageFormCard:{ contains:()=>true },
      jobPackageImportForm:{},
      jobPackageName:{ value:'' }
    };
    const spreadsheetMappings = [];
    const spreadsheetAlerts = [];
    const spreadsheetFixture = new Function(
      '$',
      'XLSX',
      'document',
      'configureJobPacketMappings',
      'alert',
      `${html.slice(packetSpreadsheetStateStart, packetSpreadsheetStateEnd)}\n` +
        `${html.slice(packetSpreadsheetReaderStart, packetSpreadsheetReaderEnd)}\n` +
        'return {' +
        'read:handleJobPackageImportFile,' +
        'state:()=>({' +
        'filename:currentJobPackageImportFilename,' +
        'workbook:currentJobPackageImportWorkbook,' +
        "packageName:$('jobPackageName').value" +
        '})};'
    )(
      id => spreadsheetElements[id],
      {
        read:value => value,
        utils:{ sheet_to_json:sheet => sheet.rows }
      },
      { createElement:()=>({}) },
      headers => spreadsheetMappings.push(headers[0]),
      message => spreadsheetAlerts.push(message)
    );
    const delayedSpreadsheet = (name, delay, header) => ({
      name,
      async arrayBuffer(){
        await new Promise(resolve => setTimeout(resolve, delay));
        return {
          SheetNames:['Sheet1'],
          Sheets:{ Sheet1:{ rows:[{ [header]:1 }] } }
        };
      }
    });
    const staleRead = spreadsheetFixture.read(
      delayedSpreadsheet('first.xlsx', 45, 'FIRST')
    );
    await new Promise(resolve => setTimeout(resolve, 2));
    const newestRead = spreadsheetFixture.read(
      delayedSpreadsheet('second.xlsx', 5, 'SECOND')
    );
    const [staleResult, newestResult] = await Promise.all([staleRead, newestRead]);
    const spreadsheetState = spreadsheetFixture.state();
    const finalSpreadsheetHeader = Object.keys(
      spreadsheetState.workbook?.Sheets?.Sheet1?.rows?.[0] || {}
    )[0];
    assert(
      staleResult === false && newestResult === true &&
        spreadsheetState.filename === 'second.xlsx' &&
        spreadsheetState.packageName === 'second' &&
        finalSpreadsheetHeader === 'SECOND' &&
        spreadsheetMappings.join(',') === 'SECOND' &&
        spreadsheetAlerts.length === 0,
      'Overlapping Job Jacket reads must keep only the newest filename, workbook and mapping.'
    );
  } catch (error) {
    failures.push('Overlapping Job Jacket spreadsheet-read regression test failed: ' + error.message);
  }
}

const packetFallbackStart = html.indexOf('async function analyzePacketPageGroupsWithFallback(');
const packetFallbackEnd = html.indexOf('async function parsePdfJobPacketForJob(', packetFallbackStart);
let analyzePacketFallbackFixture = null;
if (packetFallbackStart >= 0 && packetFallbackEnd >= 0) {
  const packetFallbackCode = html.slice(packetFallbackStart, packetFallbackEnd);
  analyzePacketFallbackFixture = new Function(
    `${packetFallbackCode}; return analyzePacketPageGroupsWithFallback;`
  )();
}

if (analyzePacketFallbackFixture) {
  try {
    const slowGroup = new Error('fixture dense group timed out');
    slowGroup.retryOriginal = false;
    slowGroup.retrySmaller = true;
    slowGroup.pageOffset = 3;
    slowGroup.pageCount = 3;
    const recovery = await analyzePacketFallbackFixture(
      [
        { page_offset:0, page_count:3, total_pages:6 },
        { page_offset:3, page_count:3, total_pages:6 }
      ],
      async (_chunk, index) => {
        if(index === 1) throw slowGroup;
        return { status:'supported', rows:[{ source_page:1 }] };
      },
      async failures => {
        assert(
          failures.length === 1 && failures[0] === slowGroup,
          'Adaptive packet recovery must receive only the failed dense group.'
        );
        return {
          retryMode:'smaller',
          parsedChunks:[3,4,5].map(pageOffset => ({
            status:'supported',
            rows:[{ source_page:pageOffset + 1 }]
          }))
        };
      }
    );
    assert(
      recovery.retriedSmaller === true &&
        recovery.retriedOriginal === false &&
        recovery.parsedChunks.length === 4 &&
        recovery.parsedChunks.flatMap(chunk => chunk.rows).map(row => row.source_page).join(',') === '1,4,5,6',
      'A slow three-page group must be replaced by its one-page results without discarding successful groups.'
    );
  } catch (error) {
    failures.push('Adaptive Job Jacket page-group recovery test failed: ' + error.message);
  }
}

// Promise rejection does not cancel sibling PDF workers. The parser must wait
// for them to settle before rendering its terminal error, or a late progress
// update can overwrite the failure and leave the review stuck on "Reading".
const packetPdfParserStart = html.indexOf('async function parsePdfJobPacketForJob');
const packetPdfParserEnd = html.indexOf(
  'function renderSmartPacketReview',
  packetPdfParserStart
);
if (packetPdfParserStart < 0 || packetPdfParserEnd < 0) {
  failures.push('Missing executable Job Jacket PDF parser.');
} else {
  try {
    let pdfReview = null;
    let pdfStageCalls = 0;
    const pdfPackageContainer = {
      prepend:node => { pdfReview = node; }
    };
    const pdfFixture = new Function(
      'document',
      'escapeHtml',
      'splitPdfForPacketImport',
      'sha256File',
      'sb',
      'packetFunctionErrorMessage',
      'packetFunctionErrorDetails',
      'fileAsDataUrl',
      'analyzePacketPageGroupsWithFallback',
      'renderSmartPacketReview',
      `let currentUtilityPacketImportId = null;\n` +
        `${html.slice(packetPdfParserStart, packetPdfParserEnd)}\n` +
        'return parsePdfJobPacketForJob;'
    )(
      {
        getElementById:()=>pdfPackageContainer,
        createElement:()=>({
          className:'',
          innerHTML:'',
          querySelector:()=>({ onclick:null }),
          remove:()=>{}
        })
      },
      value => String(value),
      async () => [0, 2, 4].map(pageOffset => ({
        file_data:'data:application/pdf;base64,fixture',
        page_offset:pageOffset,
        page_count:2,
        total_pages:6
      })),
      async () => 'fixture-sha256',
      {
        functions:{
          invoke:async (_name, { body }) => {
            const delay = body.page_offset === 0 ? 5 : body.page_offset === 2 ? 30 : 50;
            await new Promise(resolve => setTimeout(resolve, delay));
            if(body.page_offset === 0){
              return { data:null, error:{ message:'fixture chunk failed' } };
            }
            return {
              data:{
                status:'supported',
                provider_key:'oncor',
                rows:[{ source_page:body.page_offset + 1 }],
                warnings:[]
              },
              error:null
            };
          }
        },
        rpc:async () => {
          pdfStageCalls += 1;
          return { data:null, error:null };
        }
      },
      async error => error.message,
      async error => ({ message:error.message, code:'fixture', retryOriginal:true }),
      async () => 'data:application/pdf;base64,original-fixture',
      analyzePacketFallbackFixture,
      ()=>{}
    );
    await pdfFixture(
      { id:'pdf-race-job', job_number:'PDF-1', contract_id:'contract-1' },
      { name:'race-jacket.pdf', size:1024 }
    );
    const pdfFailureAtReturn = pdfReview?.innerHTML || '';
    await new Promise(resolve => setTimeout(resolve, 80));
    const pdfFailureAfterWorkers = pdfReview?.innerHTML || '';
    assert(
      pdfStageCalls === 0 &&
        pdfFailureAtReturn.includes('Packet not added') &&
        pdfFailureAtReturn.includes('fixture chunk failed') &&
        pdfFailureAfterWorkers === pdfFailureAtReturn &&
        !pdfFailureAfterWorkers.includes('Analyzed'),
      'A failed PDF Job Jacket worker must leave one stable terminal error after sibling workers settle.'
    );
  } catch (error) {
    failures.push('Job Jacket PDF worker-failure regression test failed: ' + error.message);
  }
}

// Staging and review loading are separate transactions. If review loading
// fails after staging commits, the UI must expose the saved draft instead of
// claiming that the packet was never added.
if (packetPdfParserStart >= 0 && packetPdfParserEnd >= 0) {
  try {
    let savedReview = null;
    let openedPackage = null;
    let loadCalls = 0;
    const savedButton = { onclick:null };
    const savedPackage = {
      id:'saved-package',
      job_id:'saved-job',
      package_name:'saved-jacket',
      status:'draft'
    };
    const savedReviewFixture = new Function(
      'document',
      'escapeHtml',
      'splitPdfForPacketImport',
      'sha256File',
      'sb',
      'packetFunctionErrorMessage',
      'packetFunctionErrorDetails',
      'fileAsDataUrl',
      'analyzePacketPageGroupsWithFallback',
      'renderSmartPacketReview',
      'loadJobs',
      'openJobPackageDetails',
      'currentJobPackageCatalog',
      `let currentUtilityPacketImportId = null;\n` +
        `let currentOpenJobId = null;\n` +
        `${html.slice(packetPdfParserStart, packetPdfParserEnd)}\n` +
        'return parsePdfJobPacketForJob;'
    )(
      {
        getElementById:()=>({ prepend:node => { savedReview = node; } }),
        createElement:()=>({
          className:'',
          innerHTML:'',
          querySelector:()=>savedButton,
          remove:()=>{}
        })
      },
      value => String(value),
      async () => [{
        file_data:'data:application/pdf;base64,fixture',
        page_offset:0,
        page_count:1,
        total_pages:1
      }],
      async () => 'saved-fixture-sha256',
      {
        functions:{
          invoke:async () => ({
            data:{
              status:'supported',
              provider_key:'oncor',
              format_key:'fixture',
              profile_version:'fixture-v1',
              work_order:'WO-SAVED',
              confidence:0.99,
              warnings:[],
              rows:[{
                source_page:1,
                work_point_code:'20',
                work_type:'install',
                contractor_unit_code:'U1',
                estimated_quantity:1
              }]
            },
            error:null
          })
        },
        rpc:async name => name === 'create_and_stage_utility_packet_import'
          ? { data:{ package_id:'saved-package', import_id:'saved-import' }, error:null }
          : { data:null, error:{ message:'canceling statement due to statement timeout' } }
      },
      async error => error.message,
      async error => ({ message:error.message, code:'fixture', retryOriginal:true }),
      async () => 'data:application/pdf;base64,original-saved-fixture',
      analyzePacketFallbackFixture,
      ()=>{},
      async () => { loadCalls += 1; },
      async jobPackage => { openedPackage = jobPackage; },
      [savedPackage]
    );
    await savedReviewFixture(
      { id:'saved-job', job_number:'PDF-2', contract_id:'contract-1' },
      { name:'saved-jacket.pdf', size:1024 }
    );
    assert(
      savedReview?.innerHTML.includes('Packet saved for review') &&
        savedReview.innerHTML.includes('Open Saved Review') &&
        !savedReview.innerHTML.includes('Packet not added'),
      'A post-stage review timeout must identify the resumable saved draft.'
    );
    await savedButton.onclick?.();
    assert(
      loadCalls === 1 && openedPackage === savedPackage,
      'Open Saved Review must reload jobs and reopen the exact staged package.'
    );
  } catch (error) {
    failures.push('Saved Job Jacket review recovery regression test failed: ' + error.message);
  }
}

const smartPacketReviewStart = html.indexOf('function renderSmartPacketReview');
const smartPacketReviewEnd = html.indexOf(
  'function fileNameWithoutExtension',
  smartPacketReviewStart
);
if (smartPacketReviewStart < 0 || smartPacketReviewEnd < 0) {
  failures.push('Missing executable smart Job Jacket review renderer.');
} else {
  const smartPacketReview = html.slice(smartPacketReviewStart, smartPacketReviewEnd);
  assert(
    smartPacketReview.includes("'finalize_utility_packet_import_review'") &&
      smartPacketReview.includes('{ p_import_id:importId, p_rows:reviewRows }'),
    'Smart Job Jacket review must save and finalize all rows through one atomic RPC.'
  );
  assert(
    !smartPacketReview.includes("sb.rpc('update_utility_packet_import_row'") &&
      !smartPacketReview.includes("'update_utility_packet_import_rows_bulk'"),
    'Smart Job Jacket review must not split review saving into extra database requests.'
  );
}

// Work-point aliases must use the same canonical key so quantities do not
// overwrite or split when a utility sheet mixes padded and prefixed values.
const packetPointStart = html.indexOf('function normalizeJobPacketPoint');
const packetPointEnd = html.indexOf('async function previewJobPackageImport', packetPointStart);
if (packetPointStart < 0 || packetPointEnd < 0) {
  failures.push('Missing executable Job Jacket work-point normalizer.');
} else {
  try {
    const normalizeJobPacketPoint = new Function(
      `${html.slice(packetPointStart, packetPointEnd)}; return normalizeJobPacketPoint;`
    )();
    const aliases = ['WP-0020', 'Pole 20', '20'];
    assert(
      aliases.every(value => normalizeJobPacketPoint(value) === '20'),
      'WP-0020, Pole 20 and 20 must normalize to the same work point.'
    );
    const aggregated = aliases.reduce((totals, value, index) => {
      const key = normalizeJobPacketPoint(value);
      totals.set(key, (totals.get(key) || 0) + index + 1);
      return totals;
    }, new Map());
    assert(
      aggregated.size === 1 && aggregated.get('20') === 6,
      'Equivalent work points must aggregate quantities instead of overwriting or splitting them.'
    );
  } catch (error) {
    failures.push('Job Jacket work-point normalization regression test failed: ' + error.message);
  }
}

// The remaining-units RPC intentionally releases a returned draft. When that
// same draft is reopened, subtract only its own matching saved row for the
// picker display. A never-returned draft is already reserved by the RPC and
// must not be subtracted a second time.
const returnedDraftQuantityStart = html.indexOf('function authorizedDailyWorkType');
const returnedDraftQuantityEnd = html.indexOf(
  'function renderDailyAuthorizedUnitsForLocation',
  returnedDraftQuantityStart
);
if (
  packetPointStart < 0 || packetPointEnd < 0 ||
  returnedDraftQuantityStart < 0 || returnedDraftQuantityEnd < 0
) {
  failures.push('Missing executable returned-draft authorized-quantity helpers.');
} else {
  try {
    const installReturnedDraftFixture = (report, savedUnits) => new Function(
      'currentDailyUnitReport',
      'currentDailySavedUnits',
      `${html.slice(packetPointStart, packetPointEnd)}\n` +
        `${html.slice(returnedDraftQuantityStart, returnedDraftQuantityEnd)}\n` +
        'return {dailyReportIsReturnedDraft,dailyAuthorizedQuantityAvailable};'
    )(report, savedUnits);
    const targetAuthorizedUnit = {
      work_point_code:'20',
      unit_code:'A',
      work_type:'install',
      remaining_quantity:5
    };
    const savedReturnedDraftRows = [
      {
        pole_location:'WP-20',
        item_code:'A',
        install_quantity:2,
        transfer_quantity:0,
        retirement_quantity:0
      },
      {
        pole_location:'WP-21',
        item_code:'A',
        install_quantity:40,
        transfer_quantity:0,
        retirement_quantity:0
      },
      {
        pole_location:'Pole 20',
        item_code:'B',
        install_quantity:50,
        transfer_quantity:0,
        retirement_quantity:0
      }
    ];
    const returnedDraftReport = { status:'draft', review_notes:'Correct and resubmit' };
    const returnedDraft = installReturnedDraftFixture(
      returnedDraftReport,
      savedReturnedDraftRows
    );
    assert(
      returnedDraft.dailyReportIsReturnedDraft(returnedDraftReport) &&
        returnedDraft.dailyAuthorizedQuantityAvailable(targetAuthorizedUnit) === 3,
      'A returned draft with 2 saved against RPC remaining 5 must offer exactly 3.'
    );
    assert(
      returnedDraft.dailyAuthorizedQuantityAvailable({
        ...targetAuthorizedUnit,
        work_point_code:'WP-22'
      }) === 5 &&
        returnedDraft.dailyAuthorizedQuantityAvailable({
          ...targetAuthorizedUnit,
          unit_code:'C'
        }) === 5,
      'Returned-draft adjustment must not subtract unrelated locations or unit codes.'
    );

    const neverReturnedDraftReport = { status:'draft', review_notes:'' };
    const neverReturnedDraft = installReturnedDraftFixture(
      neverReturnedDraftReport,
      savedReturnedDraftRows
    );
    assert(
      !neverReturnedDraft.dailyReportIsReturnedDraft(neverReturnedDraftReport) &&
        neverReturnedDraft.dailyAuthorizedQuantityAvailable({
          ...targetAuthorizedUnit,
          remaining_quantity:3
        }) === 3,
      'A never-returned draft with RPC remaining 3 must still offer 3 without double subtraction.'
    );
  } catch (error) {
    failures.push('Returned-draft authorized-quantity regression test failed: ' + error.message);
  }
}

// Execute the Create Job handler with a jacket to prove the UUID returned by
// the database is loaded before that exact file is routed into its review.
const createJobHandlerStart = html.indexOf("$('createJobBtn').onclick = async()=>{");
const createJobHandlerEnd = html.indexOf('/* LOAD JOBS */', createJobHandlerStart);
if (createJobHandlerStart < 0 || createJobHandlerEnd < 0) {
  failures.push('Missing executable Create Job handler.');
} else {
  try {
    const createJobHandlerCode = html.slice(createJobHandlerStart, createJobHandlerEnd);
    const createdJobId = '00000000-0000-4000-8000-000000000123';
    const jacketFile = { name:'created-job-jacket.xlsx', size:456 };
    const sequence = [];
    const alerts = [];
    let routedJob = null;
    let routedFile = null;
    let historyState = null;
    let rpcCall = null;
    const jobs = [];
    const elements = {
      createJobCard:{ dataset:{}, classList:{ add:className => sequence.push('hide:' + className) } },
      createJobPacketFile:{ files:[jacketFile] },
      jobNumber:{ value:' JOB-123 ' },
      jobName:{ value:' Jacket Integration Test ' },
      jobContract:{ value:'contract-123' },
      createJobBtn:{ onclick:null, disabled:false, textContent:'Create Job & Review Jacket' }
    };
    const getElement = id => elements[id];
    const fixture = new Function(
      '$',
      'sb',
      'currentJobsCatalog',
      'currentOpenJobId',
      'loadJobs',
      'handleJobPacketFileForJob',
      'setAppHistory',
      'updateCreateJobActionLabel',
      'resetCreateJobPacketSelection',
      'jobPacketFileValidationMessage',
      'alert',
      `${createJobHandlerCode}; return {` +
        "handler:$('createJobBtn').onclick," +
        'getCurrentOpenJobId:()=>currentOpenJobId' +
        '};'
    )(
      getElement,
      {
        rpc:async (name, args) => {
          sequence.push('rpc');
          rpcCall = { name, args };
          return { data:createdJobId, error:null };
        }
      },
      jobs,
      null,
      async () => {
        sequence.push('load');
        jobs.push({ id:createdJobId, job_number:'JOB-123' });
      },
      async (job, file) => {
        sequence.push('route');
        routedJob = job;
        routedFile = file;
      },
      state => {
        sequence.push('history');
        historyState = state;
      },
      () => sequence.push('label'),
      () => sequence.push('reset'),
      () => '',
      message => alerts.push(message)
    );

    await fixture.handler();
    assert(
      rpcCall?.name === 'create_contract_job' &&
        rpcCall.args.p_contract_id === 'contract-123' &&
        rpcCall.args.p_job_number === 'JOB-123' &&
        rpcCall.args.p_job_name === 'Jacket Integration Test',
      'Create Job must send the entered contract, number and name to the create RPC.'
    );
    assert(
      sequence.filter(step => ['rpc', 'load', 'history', 'route'].includes(step)).join(',') ===
        'rpc,load,history,route',
      'Create Job must create, reload, establish detail history, then route the jacket.'
    );
    assert(
      fixture.getCurrentOpenJobId() === createdJobId &&
        routedJob?.id === createdJobId &&
        routedFile === jacketFile,
      'Create Job must route the exact selected jacket using the returned job UUID.'
    );
    assert(
      historyState?.lineCrewPage === 'jobsPage' &&
        historyState?.view === 'jobDetail' &&
        historyState?.jobId === createdJobId,
      'Create Job jacket review must push the same job-detail history state as a normal job open.'
    );
    assert(
      elements.createJobBtn.disabled === false && alerts.length === 0,
      'Create Job must restore its button after a successful jacket handoff.'
    );
  } catch (error) {
    failures.push('Create Job jacket handoff regression test failed: ' + error.message);
  }
}

for (const marker of [
  'id="dailyAuthorizedUnitPanel"',
  'id="dailyAuthorizedUnitHelp"',
  'id="dailyAuthorizedUnitChoices"',
  "sb.rpc('get_remaining_job_units_for_field', { p_job_id:report.job_id })",
  'const authorizedRowsRequest = canEditDraft && report.job_id',
  'renderDailyAuthorizedUnitsForLocation',
  'addAuthorizedDailyUnit',
  'From job jacket:',
  'Pending Packet or Redline'
]) {
  assert(html.includes(marker), `Missing Foreman authorized Job Jacket marker: ${marker}`);
}

assert(
  html.includes('async function splitPdfForPacketImport(file, pagesPerChunk = 3)') &&
    html.includes('page_count:packet.page_count') &&
    html.includes('Math.min(completedPages, chunk.total_pages)'),
  'PDF Job Jackets must use adaptive three-page groups and page-accurate progress reporting.'
);
for (const marker of [
  'const remainingInstall = Math.max(',
  'const remainingTransfer = Math.max(',
  'const remainingRetirement = Math.max(',
  '<strong>Remaining I: ${dailyQuantityText(remainingInstall)}',
  'T: ${dailyQuantityText(remainingTransfer)}',
  'R: ${dailyQuantityText(remainingRetirement)}</strong>'
]) {
  assert(html.includes(marker), `Missing Admin Job Jacket remaining-quantity marker: ${marker}`);
}

// Jacket work points with remaining quantity must be offered in the same
// Foreman pole/location control as locations already saved on the report.
// The end marker only bounds the slice compiled below; it is whichever
// function follows renderDailyPoleLocationOptions. It used to be
// dailyQuantityText, which has since moved to top level so the Utility Job
// Package screen can reach it. The compiled region is unchanged:
// dailyWorkPointKey, findDailySavedUnitAtLocation, renderDailyPoleLocationOptions.
const dailyLocationStart = html.indexOf('function dailyWorkPointKey');
const dailyLocationEnd = html.indexOf('function authorizedDailyWorkType', dailyLocationStart);
if (dailyLocationStart < 0 || dailyLocationEnd < 0) {
  failures.push('Missing executable Foreman jacket work-point renderer.');
} else {
  try {
    const locationList = { innerHTML:'' };
    const dailyLocationHelpers = new Function(
      '$',
      'escapeHtml',
      'normalizeJobPacketPoint',
      'currentDailySavedUnits',
      'currentDailyAuthorizedRows',
      'dailyAuthorizedQuantityAvailable',
      `${html.slice(dailyLocationStart, dailyLocationEnd)}; ` +
        'return {renderDailyPoleLocationOptions,findDailySavedUnitAtLocation};'
    )(
      id => (id === 'dailyUnitPoleLocations' ? locationList : null),
      value => String(value),
      value => {
        const key = String(value || '')
          .trim()
          .toLowerCase()
          .replace(/^(pole|wp|work[\s_-]*point)[\s#:_-]*/i, '')
          .replace(/[^a-z0-9]+/g, '');
        return /^\d+$/.test(key) ? (key.replace(/^0+(?=\d)/, '') || '0') : key;
      },
      [
        { price_book_item_id:'item-a', pole_location:'Pole 20' },
        { price_book_item_id:'item-b', pole_location:'Pole 4' }
      ],
      [
        { work_point_code:'WP-0020', remaining_quantity:3 },
        { work_point_code:'20', remaining_quantity:2 },
        { work_point_code:'Pole 99', remaining_quantity:0 }
      ],
      authorized => Number(authorized.remaining_quantity || 0)
    );
    dailyLocationHelpers.renderDailyPoleLocationOptions();
    const optionValues = [...locationList.innerHTML.matchAll(/value="([^"]*)"/g)]
      .map(match => match[1]);
    assert(
      optionValues.length === 2 &&
        optionValues.includes('Pole 4') &&
        optionValues.includes('Pole 20') &&
        !optionValues.includes('WP-0020') &&
        !optionValues.includes('20') &&
        !optionValues.includes('Pole 99'),
      'Foreman location choices must canonically dedupe saved and jacket work-point aliases.'
    );
    assert(
      dailyLocationHelpers.findDailySavedUnitAtLocation('item-a', 'WP-0020')
        ?.pole_location === 'Pole 20' &&
        dailyLocationHelpers.findDailySavedUnitAtLocation('item-a', '20')
          ?.pole_location === 'Pole 20' &&
        dailyLocationHelpers.findDailySavedUnitAtLocation('item-b', 'WP-0020') == null,
      'Foreman batch save must reuse an equivalent saved location for the same Price Book item.'
    );
    for (const marker of [
      'const existing = findDailySavedUnitAtLocation(',
      "const persistedLocation = String(existing?.pole_location || '').trim() || location;",
      'dailyWorkPointKey(persistedLocation)',
      'location:persistedLocation'
    ]) {
      assert(
        html.includes(marker),
        `Foreman batch save is missing canonical existing-location reuse: ${marker}`
      );
    }
  } catch (error) {
    failures.push('Foreman jacket work-point renderer regression test failed: ' + error.message);
  }
}

// A rejected PDF page group must not abort the packet immediately. The browser
// retries the untouched source PDF once and uses only that result, preventing
// partial or duplicate rows from reaching database staging.
if (packetFallbackStart < 0 || packetFallbackEnd < 0) {
  failures.push('Missing executable utility packet original-PDF fallback.');
} else {
  try {
    const analyzeWithFallback = analyzePacketFallbackFixture;
    const chunkCalls = [];
    let originalCalls = 0;
    const progress = [];
    const result = await analyzeWithFallback(
      [{page_offset:0},{page_offset:2},{page_offset:4}],
      async chunk => {
        chunkCalls.push(chunk.page_offset);
        throw new Error('Analyzer rejected page group ' + chunk.page_offset);
      },
      async failures => {
        originalCalls += 1;
        assert(failures.length === 3, 'Original-PDF retry must receive all failed page groups.');
        return { status:'supported', provider_key:'oncor', rows:[{contractor_unit_code:'A1'}] };
      },
      (...args) => progress.push(args)
    );
    assert(chunkCalls.join(',') === '0,2,4', 'Packet fallback must attempt every page group before retrying.');
    assert(originalCalls === 1, 'Packet fallback must retry the untouched original PDF exactly once.');
    assert(result.retriedOriginal === true && result.failedCount === 3, 'Packet fallback must report the retry and failure count.');
    assert(result.parsedChunks.length === 1 && result.parsedChunks[0].rows.length === 1, 'Packet fallback must discard failed/partial chunks and use only the original-PDF result.');
    assert(progress.some(entry => entry[3] === true), 'Packet fallback must notify the UI when the original PDF retry starts.');

    let quotaOriginalCalls = 0;
    const quotaError = new Error('The job-packet AI service is temporarily unavailable.');
    quotaError.retryOriginal = false;
    let quotaFailure = null;
    try {
      await analyzeWithFallback(
        [{page_offset:0},{page_offset:2},{page_offset:4}],
        async () => { throw quotaError; },
        async () => { quotaOriginalCalls += 1; return {}; }
      );
    } catch (error) {
      quotaFailure = error;
    }
    assert(
      quotaFailure === quotaError && quotaOriginalCalls === 0,
      'Quota/service failures must stop without wasting an original-PDF retry or blaming the file.'
    );
  } catch (error) {
    failures.push('Utility packet fallback regression test failed: ' + error.message);
  }
}

const transferMigrationPath =
  'supabase/migrations/archive/20260831050000_smart_pricebook_and_packet_transfers.sql';
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

const jobJacketIntegrityMigrationPath =
  'supabase/migrations/archive/20260901030000_job_jacket_end_to_end_integrity.sql';
assert(
  fs.existsSync(jobJacketIntegrityMigrationPath),
  'Missing end-to-end Job Jacket integrity migration.'
);
if (fs.existsSync(jobJacketIntegrityMigrationPath)) {
  const integrityMigration = fs.readFileSync(jobJacketIntegrityMigrationPath, 'utf8');
  for (const marker of [
    'finalize_job_package_spreadsheet_import',
    'linecrew_report_counts_toward_progress',
    "lower(coalesce(p_status, 'draft')) in ('submitted', 'approved')",
    'p_reviewed_at is null',
    "nullif(btrim(coalesce(p_review_notes, '')), '') is null",
    'coalesce(p_archived, false) is false'
  ]) {
    assert(
      integrityMigration.includes(marker),
      `Missing canonical Job Jacket progress marker: ${marker}`
    );
  }

  const migrationFunction = name => {
    const start = integrityMigration.indexOf(`create or replace function public.${name}(`);
    if (start < 0) return '';
    const next = integrityMigration.indexOf('\ncreate or replace function public.', start + 1);
    return integrityMigration.slice(start, next < 0 ? undefined : next);
  };
  for (const consumer of [
    'get_job_package_work_points',
    'get_job_package_work_points_v2',
    'get_daily_report_unit_locations_v2',
    'get_remaining_job_units_for_field',
    'get_job_progress_dashboard'
  ]) {
    const body = migrationFunction(consumer);
    assert(body, `Missing rewritten progress consumer: ${consumer}`);
    assert(
      body.includes('public.linecrew_report_counts_toward_progress('),
      `${consumer} must share the canonical returned-report counting rule.`
    );
  }

  // Keep the rule's expected state transitions explicit and executable. The
  // SQL markers above tie this truth table to the immutable database helper.
  const canonicalProgressCount = report =>
    report.archived !== true &&
    (
      ['submitted', 'approved'].includes(String(report.status || 'draft').toLowerCase()) ||
      (
        String(report.status || 'draft').toLowerCase() === 'draft' &&
        report.reviewedAt == null &&
        !String(report.reviewNotes || '').trim()
      )
    );
  const reportStateTruthTable = [
    {
      label:'initial draft',
      report:{ status:'draft', submittedAt:null, reviewedAt:null, reviewNotes:'', archived:false },
      expected:true
    },
    {
      label:'submitted',
      report:{ status:'submitted', submittedAt:'2026-09-01', reviewedAt:null, reviewNotes:'', archived:false },
      expected:true
    },
    {
      label:'approved',
      report:{ status:'approved', submittedAt:'2026-09-01', reviewedAt:'2026-09-02', reviewNotes:'', archived:false },
      expected:true
    },
    {
      label:'returned draft',
      report:{ status:'draft', submittedAt:'2026-09-01', reviewedAt:'2026-09-02', reviewNotes:'Fix quantities', archived:false },
      expected:false
    },
    {
      label:'rejected',
      report:{ status:'rejected', submittedAt:'2026-09-01', reviewedAt:'2026-09-02', reviewNotes:'Rejected', archived:false },
      expected:false
    },
    {
      label:'archived draft',
      report:{ status:'draft', submittedAt:null, reviewedAt:null, reviewNotes:'', archived:true },
      expected:false
    },
    {
      label:'archived approved',
      report:{ status:'approved', submittedAt:'2026-09-01', reviewedAt:'2026-09-02', reviewNotes:'', archived:true },
      expected:false
    }
  ];
  for (const state of reportStateTruthTable) {
    assert(
      canonicalProgressCount(state.report) === state.expected,
      `Canonical progress truth table failed for ${state.label}.`
    );
  }

  assert(
    integrityMigration.includes(
      'authorized.authorized_transfer_quantity * item.transfer_price'
    ) &&
      integrityMigration.includes(
        'location.transfer_quantity * unit.actual_transfer_price'
      ) &&
      integrityMigration.includes(
        'location.transfer_quantity * unit.adjusted_transfer_price'
      ),
    'Transfer quantities must retain their transfer prices in Admin and report values.'
  );
  assert(
    !/(?:authorized\.authorized_transfer_quantity|location\.transfer_quantity)\s*\*\s*(?:item\.install_price|unit\.(?:actual|adjusted)_install_price)/i.test(
      integrityMigration
    ),
    'Transfer quantities must never be valued with an install price.'
  );
}

const packetTimeoutMigrationPath =
  'supabase/migrations/archive/20260901045812_optimize_job_packet_review_import.sql';
assert(
  fs.existsSync(packetTimeoutMigrationPath),
  'Missing Job Jacket review/finalization timeout migration.'
);
if (fs.existsSync(packetTimeoutMigrationPath)) {
  const packetTimeoutMigration = fs.readFileSync(packetTimeoutMigrationPath, 'utf8');
  for (const marker of [
    'linecrew_utility_packet_import_matches',
    'create_and_stage_utility_packet_import',
    "'resumed', true",
    'source_keys as materialized',
    'candidates as materialized',
    'update_utility_packet_import_rows_bulk',
    'finalize_utility_packet_import_review',
    'jsonb_to_recordset(p_rows)',
    'Review between 1 and 4,000 packet rows at a time.',
    'job_package_work_points_package_canonical_key_idx',
    'public.normalize_work_point_key(work_point_code)',
    'with matches as materialized',
    'on conflict (work_point_id, price_book_item_id) do update',
    'package.status = \'draft\'',
    'from public, anon, authenticated'
  ]) {
    assert(
      packetTimeoutMigration.includes(marker),
      `Missing packet timeout/atomic import marker: ${marker}`
    );
  }
}

for (const marker of [
  'id="arrangeDashboardBtn"',
  'id="saveDashboardOrderBtn"',
  'id="dashboardTileGrid"',
  'loadDashboardTileOrder',
  'user_dashboard_preferences',
  'dashboard-arrange-active',
  'LineCrew Pro Subscription',
  'Finish Contract Setup'
]) {
  assert(html.includes(marker), `Missing Admin dashboard/setup usability marker: ${marker}`);
}
const dashboardPreferenceMigrationPath =
  'supabase/migrations/archive/20260831143000_user_dashboard_preferences.sql';
assert(
  fs.existsSync(dashboardPreferenceMigrationPath),
  'Missing per-account dashboard preference migration.'
);
if (fs.existsSync(dashboardPreferenceMigrationPath)) {
  const dashboardMigration = fs.readFileSync(dashboardPreferenceMigrationPath, 'utf8');
  for (const marker of [
    'enable row level security',
    'user_dashboard_preferences_select_own',
    'user_dashboard_preferences_insert_own',
    'user_dashboard_preferences_update_own',
    "in ('admin', 'owner')",
    'from public, anon',
    'to authenticated'
  ]) {
    assert(
      dashboardMigration.includes(marker),
      `Missing guarded dashboard preference marker: ${marker}`
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
    // A work-type suffix is only meaningful where it follows a digit, the way
    // real utility unit codes are built. Reading a bare final letter filed
    // word-style codes from other utilities under a price type nobody chose.
    assert(
      core.normalizedPriceWorkType('', 'CV3030I') === 'install' &&
      core.normalizedPriceWorkType('', 'OH4112R') === 'retirement' &&
      core.normalizedPriceWorkType('', 'PS1095T') === 'transfer',
      'Digit-delimited unit code suffixes must still resolve their work type.'
    );
    assert(
      ['CONDUIT', 'ANCHOR', 'TRANSFORMER', 'POLE40FT'].every(
        code => core.normalizedPriceWorkType('', code) === ''
      ),
      'A trailing letter that is part of a word must not be read as a work type.'
    );
    assert(
      core.normalizedPriceWorkType('Transfer', 'CONDUIT') === 'transfer',
      'An explicit Work Type column must still win over the unit code.'
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
    const actionFlagsWithoutPrices = core.extractStructuredPricingRows('Utility Units',[
      ['Unit ID','Unit Description','Install','Remove','Transfer'],
      ['015-QA','Fuse Expulsion','X','X',''],
      ['020-QA','Fuse Expulsion','X','X','']
    ]);
    assert(
      actionFlagsWithoutPrices.tableCount === 1 &&
      actionFlagsWithoutPrices.rows.length === 0 &&
      actionFlagsWithoutPrices.skippedNoPrice === 2,
      'Install/Remove/Transfer availability flags must not be mistaken for numeric pricing.'
    );
    const weightedPriceRows = core.extractStructuredPricingRows('Historical Prices',[
      ['Item Number','Weighted Unit Price','Description','Unit','Item Class'],
      ['1020004','2750','WOOD POLE (35 FEET)','ea.','ELECTRICAL WORK AND LIGHTING'],
      ['1003997','292','REMOVE POLE','ea.','ELECTRICAL WORK AND LIGHTING']
    ]);
    assert(
      weightedPriceRows.rows.length === 2 &&
      weightedPriceRows.rows[0].row['Unit Price'] === '2750',
      'A real historical Weighted Unit Price column must produce a priced preview.'
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
  assert(
    roleWorkspaceCode.includes('preservePersonalOrder') &&
      roleWorkspaceCode.includes("grid.dataset.userDashboardCustomOrder==='true'"),
    'Role workspace must preserve each Admin or Owner dashboard layout.'
  );
  assert(
    roleWorkspaceCode.includes("document.addEventListener('touchmove',onMove,{passive:false})") &&
      roleWorkspaceCode.includes("showIndicator('Refreshing…'") &&
      roleWorkspaceCode.includes("showIndicator('Updated'") &&
      roleWorkspaceCode.includes("Finish or cancel your current work before refreshing.") &&
      roleWorkspaceCode.includes("page==='timekeepingPage'&&byId('tkSaveAssignmentsBtn')?.disabled===false") &&
      roleWorkspaceCode.includes("page==='teamPage'&&teamRoleDirty"),
    'Mobile pull-to-refresh must refresh data visibly without discarding open or unsaved work.'
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
console.log('- Create Job jacket routing and work-point normalization are verified');
console.log('- Foreman authorized units and Admin remaining quantities are present');
console.log('- HTML ids are unique');
console.log('- No known server-side secret patterns are exposed');
