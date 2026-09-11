import fs from 'node:fs';
import vm from 'node:vm';

const source = fs.readFileSync('completed-jobs-core.js','utf8');
const index = fs.readFileSync('index.html','utf8');
const bootstrap = fs.readFileSync('number-input-polish.js','utf8');
const serviceWorker = fs.readFileSync('service-worker.js','utf8');

const sandbox = { window:{} };
vm.runInNewContext(source, sandbox, { filename:'completed-jobs-core.js' });
const core = sandbox.window.LineCrewCompletedJobsCore;
const names = [
  'completedJobCardViewModel',
  'completedJobAttachmentRowViewModel',
  'completedJobCloseoutRowViewModel',
  'completedJobAuditRowViewModel'
];
for (const name of names) {
  if (!core || typeof core[name] !== 'function') throw new Error(`Completed Jobs core must expose ${name}().`);
}

const card = core.completedJobCardViewModel(
  {
    job_number:'WO-100',
    job_name:'North Feeder',
    customer_name:'Legacy Customer',
    closed_at:'2026-09-10T15:00:00Z',
    contracts:{ contract_name:'Oncor North', customers:{ name:'Oncor' } }
  },
  { reported_percent:'82.35', approved_percent:79, report_count:'6', work_point_count:'14' },
  [{ full_name:'Alex Foreman' },{ full_name:'Jordan GF' }]
);
const expectedCard = {
  jobNumber:'WO-100',
  jobName:'North Feeder',
  customer:'Oncor',
  contract:'Oncor North',
  closedAt:'2026-09-10T15:00:00Z',
  reportedPercent:'82.3',
  approvedPercent:'79.0',
  reportCount:6,
  workPointCount:14,
  supervision:'Alex Foreman, Jordan GF'
};
if (JSON.stringify(card) !== JSON.stringify(expectedCard)) throw new Error(`Completed Jobs card model changed: ${JSON.stringify(card)}.`);
const emptyCard = core.completedJobCardViewModel({}, {}, []);
if (emptyCard.customer !== 'Not recorded' || emptyCard.contract !== 'Not assigned' || emptyCard.supervision !== 'No retained assignment') {
  throw new Error('Completed Jobs card fallbacks changed.');
}

const attachment = core.completedJobAttachmentRowViewModel({id:'a1',original_filename:'photo.jpg',caption:'Pole 12',created_at:'2026-09-10T12:00:00Z'});
if (JSON.stringify(attachment) !== JSON.stringify({attachmentId:'a1',fileName:'photo.jpg',caption:'Pole 12',createdAt:'2026-09-10T12:00:00Z'})) {
  throw new Error('Completed Jobs attachment row changed.');
}
const emptyAttachment = core.completedJobAttachmentRowViewModel({});
if (emptyAttachment.fileName !== 'Attachment' || emptyAttachment.caption !== '' || emptyAttachment.attachmentId !== '') {
  throw new Error('Completed Jobs attachment fallbacks changed.');
}

const closeout = core.completedJobCloseoutRowViewModel({action:'override_closed',actor_name:'Owner User',actor_role:'owner',occurred_at:'2026-09-10T13:00:00Z',reason:'Emergency closeout'});
if (JSON.stringify(closeout) !== JSON.stringify({actionText:'OVERRIDE CLOSED',actorName:'Owner User',actorRole:'owner',occurredAt:'2026-09-10T13:00:00Z',reason:'Emergency closeout',isOwnerOverride:true})) {
  throw new Error('Completed Jobs closeout row changed.');
}
const emptyCloseout = core.completedJobCloseoutRowViewModel({});
if (emptyCloseout.actorName !== 'System' || emptyCloseout.isOwnerOverride !== false || emptyCloseout.actionText !== '') {
  throw new Error('Completed Jobs closeout fallbacks changed.');
}

const audit = core.completedJobAuditRowViewModel({event_type:'daily_report_approved',actor_name:'GF User',event_at:'2026-09-10T14:00:00Z',event_notes:'Approved'});
if (JSON.stringify(audit) !== JSON.stringify({eventType:'daily report approved',actorName:'GF User',eventAt:'2026-09-10T14:00:00Z',eventNotes:'Approved'})) {
  throw new Error('Completed Jobs audit row changed.');
}
const emptyAudit = core.completedJobAuditRowViewModel({});
if (emptyAudit.eventType !== 'updated' || emptyAudit.actorName !== 'System' || emptyAudit.eventNotes !== '') {
  throw new Error('Completed Jobs audit fallbacks changed.');
}

if (!bootstrap.includes("script.src = '/completed-jobs-core.js?v=20260911a'")) throw new Error('Completed Jobs core is not bootstrapped.');
if (!bootstrap.includes('Completed Jobs core module unavailable; using inline compatibility fallback.')) throw new Error('Completed Jobs loader must retain an explicit inline fallback path.');
if (!serviceWorker.includes("'/completed-jobs-core.js?v=20260911a'")) throw new Error('Completed Jobs core must be cached for offline use.');

for (const marker of [
  "job.contracts?.customers?.name||job.customer_name||'Not recorded'",
  "job.contracts?.contract_name||'Not assigned'",
  "assignments.map(item=>item.full_name).join(', ')||'No retained assignment'",
  "item.original_filename||'Attachment'",
  "String(item.action||'').replaceAll('_',' ').toUpperCase()",
  "item.actor_name||'System'",
  "item.action==='override_closed'",
  "String(item.event_type||'updated').replaceAll('_',' ')",
  "item.event_notes?'<br>'+escapeHtml(item.event_notes):''"
]) {
  if (!index.includes(marker)) throw new Error(`Completed Jobs inline fallback marker missing: ${marker}`);
}

console.log('Completed Jobs core guard passed.');
console.log('- completed-job cards, attachments, closeout history, and audit history match current display behavior');
console.log('- live inline archive renderer remains present as the compatibility fallback');
console.log('- module is bootstrapped and available offline');
