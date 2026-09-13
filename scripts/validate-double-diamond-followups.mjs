import fs from 'node:fs';
import assert from 'node:assert/strict';

const app=fs.readFileSync('index.html','utf8');
const loader=fs.readFileSync('expanded-jsa.js','utf8');
const signatures=fs.readFileSync('jsa-signatures.js','utf8');
const worker=fs.readFileSync('service-worker.js','utf8');
const sql=fs.readFileSync('supabase/migrations/20260913015216_fix_foreman_production_summaries.sql','utf8');

for(const marker of [
  'No JSAs Match These Filters','details?.crew_acknowledgments',
  "canReviewProduction || canViewProductionReporting || foremanEntryWorkspace",
  "' — COMMENT SAVED'",'daily-batch-clear','selectionSequence',
  'regular_hours,\novertime_hours,',"Math.round(Number(summary.adjusted_total || 0)*100) / 100 / totalHours",
  'currentJobLoadSequence','Loading Report Form...'
]) assert.ok(app.includes(marker),`Missing UI reliability repair: ${marker}`);

assert.ok(loader.includes('attempt < 1')&&loader.includes("'retry=' + attempt"),'Dependency loader must retry one transient failure.');
assert.ok(signatures.includes('stroke.length>=3&&strokeLength(stroke)>=25'),'A click/dot must not count as a signature.');
assert.ok(worker.includes("linecrew-pro-shell-v102")&&worker.includes('jsa-signatures.js?v=20260913a'),'Repaired JSA assets must invalidate the old shell cache.');

for(const marker of [
  "'owner','manager','admin','superintendent','gf','foreman'",
  "v_role<>'foreman' or report.foreman_id=auth.uid() or report.created_by=auth.uid()",
  'revoke all on function public.get_daily_report_authorization_summaries() from public,anon'
]) assert.ok(sql.includes(marker),`Missing scoped Foreman summary protection: ${marker}`);

console.log('Double Diamond follow-up validation passed.');
