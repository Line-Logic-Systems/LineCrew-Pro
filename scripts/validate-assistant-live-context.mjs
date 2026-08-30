import fs from 'node:fs';
import assert from 'node:assert/strict';
import {
  assistantModelConfig,
  classifyAssistantRequest,
  detectAssistantMemoryProposal,
  sanitizeAssistantScreenContext
} from '../supabase/functions/linecrew-assistant/assistant-logic.mjs';

const VALID_JOB_ID = '123e4567-e89b-42d3-a456-426614174000';
const VALID_REPORT_ID = '223e4567-e89b-42d3-a456-426614174001';

const sanitized = sanitizeAssistantScreenContext({
  page:'productionPage',
  title:'Production Review',
  selected_ids:{job_id:VALID_JOB_ID,report_id:VALID_REPORT_ID,secret_id:VALID_JOB_ID,billing_batch_id:'not-a-uuid'},
  selected_labels:{job:'1001 — Oak Street',crew:'Crew A',password:'do-not-send'},
  visible_messages:['Report is waiting for review.'],
  last_error:'operation_failed|Unable to load report',
  arbitrary_form_data:'must be discarded'
});
assert.deepEqual(sanitized.selected_ids,{job_id:VALID_JOB_ID,report_id:VALID_REPORT_ID});
assert.deepEqual(sanitized.selected_labels,{job:'1001 — Oak Street',crew:'Crew A'});
assert.equal('arbitrary_form_data' in sanitized,false);

const reportPlan = classifyAssistantRequest('Which daily reports are waiting for approval?','productionPage',sanitized);
assert(reportPlan.categories.includes('reports'));
assert.equal(reportPlan.route,'reasoning','A recent screen error should select the reasoning route.');

const fastPlan = classifyAssistantRequest('How do I import a Price Book?','priceBooksPage',{});
assert(fastPlan.categories.includes('pricing'));
assert.equal(fastPlan.route,'fast');

const diagnosticPlan = classifyAssistantRequest("Why can't Garrett see this job?",'jobsPage',{
  selected_ids:{job_id:VALID_JOB_ID}
});
assert(diagnosticPlan.categories.includes('jobs'));
assert(diagnosticPlan.categories.includes('team'));
assert.equal(diagnosticPlan.route,'reasoning');

const finalBillingPlan = classifyAssistantRequest('Is this job ready for final billing?','jobsPage',{
  selected_ids:{job_id:VALID_JOB_ID}
});
assert.deepEqual(finalBillingPlan.categories.sort(),['billing','jobs','reports']);
assert.equal(finalBillingPlan.route,'reasoning');

const jobReminder = detectAssistantMemoryProposal(
  'On this job, remind me to add a redline attachment before final billing.',
  {selected_ids:{job_id:VALID_JOB_ID},selected_labels:{job:'1001 — Oak Street'}}
);
assert.equal(jobReminder.memory_type,'job_reminder');
assert.equal(jobReminder.job_id,VALID_JOB_ID);
assert.equal(jobReminder.trigger_type,'final_billing');
assert.equal(jobReminder.instruction,'add a redline attachment before final billing');
assert.equal(jobReminder.requires_confirmation,true);

const workflowMemory = detectAssistantMemoryProposal(
  'From now on, remember that every job needs a closeout photo.',
  {selected_ids:{job_id:VALID_JOB_ID}}
);
assert.equal(workflowMemory.memory_type,'company_workflow');
assert.equal(workflowMemory.job_id,null);
assert.equal(workflowMemory.trigger_type,'always');
assert.equal(detectAssistantMemoryProposal('How do reminders work?',{}),null);

assert.deepEqual(
  assistantModelConfig('fast',{OPENAI_MODEL:'gpt-5-mini'}),
  {model:'gpt-5-mini',effort:'low',fallbackModel:'gpt-5-mini'}
);
assert.deepEqual(
  assistantModelConfig('reasoning',{OPENAI_MODEL:'gpt-5-mini',OPENAI_MODEL_REASONING:'gpt-5.6-terra'}),
  {model:'gpt-5.6-terra',effort:'medium',fallbackModel:'gpt-5-mini'}
);

const assistant = fs.readFileSync('supabase/functions/linecrew-assistant/index.ts','utf8');
const app = fs.readFileSync('index.html','utf8');
for(const marker of [
  '2026-08-30-assistant-memory-v6',
  'loadLiveCompanyContext(',
  'Authenticated Owner/Admin read-only snapshot constrained by company RLS',
  '.eq("company_id", companyId)',
  'assistantModelConfig(requestPlan.route',
  'OPENAI_MODEL_REASONING',
  'safety_identifier: safetyIdentifier',
  'fast-fallback',
  'store: false'
]) assert(assistant.includes(marker),`Assistant live-context marker missing: ${marker}`);
assert(!assistant.includes('SUPABASE_SERVICE_ROLE_KEY'),'Assistant must not bypass RLS with a service-role key.');
for(const mutation of ['.insert(','.update(','.upsert(','.delete(','.rpc(']) {
  assert(!assistant.includes(mutation),`Assistant live data must remain read-only: ${mutation}`);
}
for(const marker of [
  'collectAssistantScreenContext()',
  'screen_context:collectAssistantScreenContext()',
  "page:currentErrorPage()",
  "rememberId('job_id'",
  "rememberId('report_id'",
  'permission-safe, read-only company data'
]) assert(app.includes(marker),`App screen-context marker missing: ${marker}`);

console.log('Assistant live-context validation passed.');
console.log('- Screen context allowlist strips unknown fields and invalid record IDs');
console.log('- Job/report/team/pricing intents choose relevant read-only data');
console.log('- Complex troubleshooting routes to balanced reasoning with safe fallback');
console.log('- Edge Function remains authenticated, tenant-scoped and non-mutating');
