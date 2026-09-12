#!/usr/bin/env node

import fs from 'node:fs';

const html = fs.readFileSync('index.html', 'utf8');

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

const unitReviewStart = html.indexOf('function renderDailyUnitReviewActions(report)');
const unitReviewEnd = html.indexOf("const returnButton = document.createElement('button');", unitReviewStart);
const listReviewStart = html.indexOf("approveBtn.textContent = 'Approve';", unitReviewEnd);
const listReviewEnd = html.indexOf('const returnLabel =', listReviewStart);
const approvalPaths = html.slice(unitReviewStart, unitReviewEnd) + html.slice(listReviewStart, listReviewEnd);

assert(unitReviewStart >= 0 && unitReviewEnd > unitReviewStart, 'Unit-editor approval path is missing.');
assert(listReviewStart >= 0 && listReviewEnd > listReviewStart, 'Report-list approval path is missing.');
assert(!approvalPaths.includes('prompt('), 'GF approval must not use browser prompt().');
assert(!approvalPaths.includes('confirm('), 'GF approval must not use browser confirm().');
assert((approvalPaths.match(/requestReportApprovalDecision\(/g) || []).length === 2,
  'Both GF approval paths must use the on-page approval dialog.');
assert(html.includes("backdrop.setAttribute('role','dialog')"), 'Approval dialog must expose dialog semantics.');
assert(html.includes("backdrop.setAttribute('aria-modal','true')"), 'Approval dialog must be modal to assistive technology.');
assert(html.includes('id="reportApprovalNotes"'), 'Approval dialog notes field is missing.');
assert(html.includes('id="reportApprovalDialogError" class="error-text hidden" role="alert" aria-live="assertive"'),
  'Required-reason failures must be announced accessibly.');
assert(html.includes("if(requiresAdminOverride && !value)"), 'Redline override reasons must remain mandatory.');
assert(html.includes("if(notes === null) return;"), 'Cancelling approval must not call the approval RPC.');

console.log('GF approval dialog validation passed.');
