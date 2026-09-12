import fs from 'node:fs';
import assert from 'node:assert/strict';

const app=fs.readFileSync('index.html','utf8');
const migration=fs.readFileSync('supabase/migrations/20260912150000_harden_assistant_and_stripe_idempotency.sql','utf8');
const assistant=fs.readFileSync('supabase/functions/linecrew-assistant/index.ts','utf8');
const stripe=fs.readFileSync('supabase/functions/stripe-webhook/index.ts','utf8');

for(const marker of ['assistant_usage_monthly','consume_assistant_monthly_request',
  'processing_started_at','processing_token','billing_events_unfinished_claim_idx',
  'get_job_jsas','get_job_billing_export_batches'])
  assert.ok(migration.includes(marker),`Hardening migration is missing: ${marker}`);
assert.ok(assistant.includes('consume_assistant_monthly_request')&&assistant.includes('}, 429)'),
  'Assistant requests must consume an atomic monthly budget and return HTTP 429 at the limit.');
assert.ok(stripe.includes('processingToken = crypto.randomUUID()')&&
  stripe.includes('.eq("processing_token", processingToken)')&&
  stripe.includes('processing_started_at.lt.'),
  'Stripe webhook must use an expiring, token-bound processing claim.');
assert.ok(!app.includes("sb.rpc('get_company_jsas')"),'Completed Jobs must not fetch company-wide JSA history.');
assert.ok(app.includes("sb.rpc('get_job_jsas'")&&app.includes("sb.rpc('get_job_billing_export_batches'"),
  'Completed Jobs must use job-scoped JSA and billing reads.');
assert.ok((app.match(/\.range\(offset,offset\+/g)||[]).length>=2,
  'Large Completed Jobs collections must be fetched in bounded pages.');

console.log('Final audit hardening regression guard passed.');
