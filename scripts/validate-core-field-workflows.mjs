import fs from 'node:fs';

function read(path){
  if(!fs.existsSync(path)) throw new Error(`Missing required field-workflow file: ${path}`);
  return fs.readFileSync(path,'utf8');
}
function need(source, token, message){
  if(!source.includes(token)) throw new Error(message);
}
function needAny(source, tokens, message){
  if(!tokens.some(token => source.includes(token))) throw new Error(message);
}

const index = read('index.html');
const timekeeping = read('timekeeping.js');
const timekeepingInput = read('timekeeping-input-v2.js');
const expandedJsa = read('expanded-jsa.js');
const jsaCore = read('expanded-jsa-core.js');
const jsaSignatures = read('jsa-signatures.js');
const offlineJsa = read('offline-jsa.js');
const gfScope = read('gf-crew-scope.js');
const maps = read('job-map-documents.js');
const serviceWorker = read('service-worker.js');

// DAILY REPORT: core save -> awaited crew-time persistence -> units -> redline guard -> GF review.
for(const [token,message] of [
  ['async function submitDailyReport','Daily Report submit function is missing.'],
  ['save_daily_report_unit_location_v2','Daily Report unit persistence RPC wiring is missing.'],
  ['get_daily_report_unit_locations_visible_v3','Daily Report saved-unit reload is missing.'],
  ['requireDailyReportRedlineComments','Daily Report redline submit guard is missing.'],
  ['save_daily_report_unit_redline_comment','Daily Report redline comment persistence is missing.'],
  ['await window.saveDailyReportCrewTime(savedReportId);','Daily Report must await crew-time save before advancing.'],
  ['offerForemanSubmitAfterUnits','Foreman submit-after-units path is missing.']
]) need(index, token, message);

need(timekeeping,
  'window.saveDailyReportCrewTime=async(reportId)',
  'Timekeeping must expose the awaited Daily Report crew-time save bridge.'
);
needAny(index,
  ['approve_daily_report','review_daily_report','gf_approve_daily_report'],
  'GF Daily Report review/approval wiring is missing.'
);

// JSA: shell loader, signatures, offline path and scoped leadership visibility all remain connected.
for(const [source,token,message] of [
  [expandedJsa,'expanded-jsa-core.js','Expanded JSA loader must keep the core form module.'],
  [expandedJsa,'jsa-signatures.js','Expanded JSA loader must keep signature support.'],
  [expandedJsa,'offline-jsa.js','Expanded JSA loader must keep offline support.'],
  [jsaSignatures,'lc-signature-wrap','JSA signature pad wiring is missing.'],
  [offlineJsa,'window.LineCrewOfflineColdStart','Offline JSA cold-start support is missing.'],
  [gfScope,'get_company_jsas_scoped','GF scoped JSA visibility is missing.']
]) need(source, token, message);
needAny(jsaCore,
  ['submit','save','create_jsa'],
  'Expanded JSA core no longer exposes a save/submit path.'
);
need(serviceWorker,'offline-jsa.js','Service worker must cache the offline JSA module.');

// TIMEKEEPING: workspace tabs, role access, roster persistence, per-person details and report bridge.
for(const [token,message] of [
  ['data-tk-tab="roster"','Timekeeping Roster tab is missing.'],
  ['data-tk-tab="equipment"','Timekeeping Equipment tab is missing.'],
  ['data-tk-tab="entry"','Timekeeping Enter Time tab is missing.'],
  ['data-tk-tab="reports"','Timekeeping Reports tab is missing.'],
  ['data-tk-tab="payroll"','Timekeeping Payroll tab is missing.'],
  ['saveRosterAssignments','Timekeeping roster assignment persistence is missing.'],
  ['window.saveDailyReportCrewTime=async(reportId)','Daily Report crew-time bridge is missing.']
]) need(timekeeping, token, message);
needAny(timekeeping,
  ['start_time','Start Time','startTime'],
  'Per-person start time support is missing from Timekeeping.'
);
needAny(timekeeping,
  ['stop_time','Stop Time','stopTime'],
  'Per-person stop time support is missing from Timekeeping.'
);
needAny(timekeeping,
  ['lunch_minutes','Lunch','lunchMinutes'],
  'Per-person lunch tracking is missing from Timekeeping.'
);
need(timekeepingInput,
  'window.LineCrewOfflineColdStart||!navigator.onLine',
  'Timekeeping must avoid protected polling during Offline JSA mode.'
);

// JOB MAPS: field access must remain additive and tied to the selected Daily Report job/work point.
for(const [token,message] of [
  ["const allowed=['foreman','gf'].includes(role())",'Daily Report job-map access must remain limited to Foreman/GF field entry.'],
  ["client.rpc('get_job_map_page'",'Job map work-point lookup is missing.'],
  ["p_job_id:report.job_id",'Job map lookup must stay scoped to the current Daily Report job.'],
  ["p_work_point_code:location||null",'Job map lookup must keep selected work-point context.'],
  ['createSignedUrl(documentRow.storage_path,900)','Retained job packets must use short-lived signed URLs.'],
  ['View Job Map','Daily Report map action is missing.']
]) need(maps, token, message);

// Cross-feature safety: production submission must not become blocked by JSA state.
const submitStart = index.indexOf('async function submitDailyReport');
if(submitStart >= 0){
  const block = index.slice(submitStart, submitStart + 6500).toLowerCase();
  if(block.includes('jsa')) throw new Error('Daily Report submission must remain independent from JSA completion.');
}

console.log('Core field workflow regression guards passed.');
