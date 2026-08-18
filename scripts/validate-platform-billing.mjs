#!/usr/bin/env node
import fs from 'node:fs';
import vm from 'node:vm';

const requiredFiles = [
  'owner.html',
  'billing.html',
  'supabase/migrations/20260818_platform_owner_and_billing.sql',
  'supabase/migrations/20260818_crew_tier_usage_policy.sql',
  'supabase/migrations/20260818_crew_tier_automation_and_visibility.sql',
  'supabase/functions/create-billing-checkout/index.ts',
  'supabase/functions/create-billing-portal/index.ts',
  'supabase/functions/stripe-webhook/index.ts',
  'scripts/test-platform-billing-isolation.mjs',
  '.github/workflows/test-platform-billing-isolation.yml',
  'docs/PLATFORM_OWNER_BILLING.md',
];

for (const file of requiredFiles) {
  if (!fs.existsSync(file)) throw new Error(`Missing required platform billing file: ${file}`);
}

const owner = fs.readFileSync('owner.html', 'utf8');
const billing = fs.readFileSync('billing.html', 'utf8');
const migration = fs.readFileSync('supabase/migrations/20260818_platform_owner_and_billing.sql', 'utf8');
const crewPolicy = fs.readFileSync('supabase/migrations/20260818_crew_tier_usage_policy.sql', 'utf8');
const crewAutomation = fs.readFileSync('supabase/migrations/20260818_crew_tier_automation_and_visibility.sql', 'utf8');
const checkout = fs.readFileSync('supabase/functions/create-billing-checkout/index.ts', 'utf8');
const portal = fs.readFileSync('supabase/functions/create-billing-portal/index.ts', 'utf8');
const webhook = fs.readFileSync('supabase/functions/stripe-webhook/index.ts', 'utf8');
const isolation = fs.readFileSync('scripts/test-platform-billing-isolation.mjs', 'utf8');
const isolationWorkflow = fs.readFileSync('.github/workflows/test-platform-billing-isolation.yml', 'utf8');

function parseInlineScripts(name, html) {
  const scripts = [...html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/gi)]
    .filter(match => !/\bsrc\s*=/.test(match[0]))
    .map(match => match[1]);
  if (!scripts.length) throw new Error(`${name} has no inline application script.`);
  for (const [index, script] of scripts.entries()) {
    try { new vm.Script(script, { filename: `${name}:inline-script-${index + 1}` }); }
    catch (error) { throw new Error(`${name} inline JavaScript does not parse: ${error.message}`); }
  }
}

function assertUniqueIds(name, html) {
  const ids = [...html.matchAll(/\bid=["']([^"']+)["']/gi)].map(match => match[1]);
  const duplicates = ids.filter((id, index) => ids.indexOf(id) !== index);
  if (duplicates.length) throw new Error(`${name} has duplicate HTML IDs: ${[...new Set(duplicates)].join(', ')}`);
}

parseInlineScripts('owner.html', owner);
parseInlineScripts('billing.html', billing);
assertUniqueIds('owner.html', owner);
assertUniqueIds('billing.html', billing);

for (const marker of ['is_platform_owner','platform_owner_company_dashboard','platform_owner_set_subscription','editAccessOverride','internal_notes','rolling_overage_crew_days','recommended_plan_code']) {
  if (!owner.includes(marker)) throw new Error(`owner.html is missing ${marker}`);
}
for (const marker of ['my_company_billing_summary','create-billing-checkout','create-billing-portal','stripe_subscription_linked','rolling_peak_billable_crews','crew_overage_status']) {
  if (!billing.includes(marker)) throw new Error(`billing.html is missing ${marker}`);
}

for (const marker of [
  'create table if not exists public.platform_owners',
  'create table if not exists public.company_subscriptions',
  'create table if not exists public.billing_events',
  'create table if not exists public.platform_owner_audit_events',
  'revoke all on public.platform_owners from anon, authenticated',
  'revoke all on public.company_subscriptions from anon, authenticated',
  'revoke all on public.billing_events from anon, authenticated',
  'access_override boolean null',
  'platform_owner_company_dashboard',
  'platform_owner_set_subscription',
  'my_company_subscription_access',
  'my_company_billing_summary',
  "select c.id, 'pilot', 0, 'trialing', true, 'manual'",
]) {
  if (!migration.toLowerCase().includes(marker.toLowerCase())) throw new Error(`billing migration is missing ${marker}`);
}

for (const marker of ['company_crew_usage_daily','starter','business','pro','enterprise','rolling_overage_crew_days','current_date - 29']) {
  if (!crewPolicy.toLowerCase().includes(marker.toLowerCase())) throw new Error(`crew tier policy migration is missing ${marker}`);
}
for (const marker of [
  'peak_billable_crews',
  'capture_company_crew_usage',
  'capture_all_company_crew_usage',
  'linecrew_capture_crew_usage',
  'linecrew_capture_storm_assignment_usage',
  'linecrew_capture_storm_toggle_usage',
  "v_overage <= 6",
  "v_plan = 'pilot'",
  'recommended_plan_code',
  'rolling_peak_billable_crews',
  "when v_plan='custom' then p_monthly_price_cents",
  'public.plan_monthly_cents(v_plan)',
]) {
  if (!crewAutomation.toLowerCase().includes(marker.toLowerCase())) throw new Error(`crew tier automation migration is missing ${marker}`);
}

if (!checkout.includes('BILLING_PLAN_PRICE_MAP')) throw new Error('Checkout must use the server-side BILLING_PLAN_PRICE_MAP.');
if (checkout.includes('BILLING_ALLOWED_PRICE_IDS')) throw new Error('Checkout still contains the older client-selected Price ID allowlist path.');
if (!checkout.includes('planPriceMap.get(planCode)')) throw new Error('Checkout must bind the company assigned plan to its Stripe Price server-side.');
if (!checkout.includes('String(profile.role).toLowerCase() !== "admin"')) throw new Error('Checkout must require company Admin role.');
if (!checkout.includes('already has a Stripe subscription')) throw new Error('Checkout must guard against duplicate live subscriptions.');
if (!portal.includes('String(profile.role).toLowerCase() !== "admin"')) throw new Error('Billing portal must require company Admin role.');
if (!portal.includes('/billing.html?billing=portal-return')) throw new Error('Billing portal must return to the contractor billing page.');
if (!webhook.includes('stripe-signature') || !webhook.includes('verifyStripeSignature')) throw new Error('Stripe webhook signature validation is missing.');
if (!webhook.includes('eventInsertError.code !== "23505"')) throw new Error('Stripe webhook must recognize unique-event retries by PostgreSQL error code.');
if (!webhook.includes('prior?.processed_at')) throw new Error('Stripe webhook must distinguish completed duplicates from retryable failed events.');
if (!webhook.includes('invoice.paid is intentionally audit-only')) throw new Error('Stripe invoice.paid must not blindly reactivate a subscription.');

for (const marker of ['DISPOSABLE_ONLY','SUPABASE_PRODUCTION_PROJECT_REF','platform_owner_company_dashboard','my_company_billing_summary','my_company_subscription_access','company_subscriptions','platform_owners','Foreman accessed company Admin billing summary']) {
  if (!isolation.includes(marker)) throw new Error(`billing isolation harness is missing ${marker}`);
}
if (!isolationWorkflow.includes('environment: isolation-test')) throw new Error('billing isolation workflow must use the protected isolation-test environment.');
if (!isolationWorkflow.includes('LINECREW_ISOLATION_TEST_CONFIRM')) throw new Error('billing isolation workflow is missing disposable-project confirmation.');

const publicFiles = [owner, billing, checkout, portal, webhook].join('\n');
for (const pattern of [
  /STRIPE_SECRET_KEY\s*=\s*['"][^'"]+['"]/i,
  /SUPABASE_SERVICE_ROLE_KEY\s*=\s*['"][^'"]+['"]/i,
  /STRIPE_WEBHOOK_SECRET\s*=\s*['"][^'"]+['"]/i,
  /BILLING_PLAN_PRICE_MAP\s*=\s*['"][^'"]+['"]/i,
]) {
  if (pattern.test(publicFiles)) throw new Error(`Potential hard-coded secret/config detected: ${pattern}`);
}
if (owner.includes('SUPABASE_SERVICE_ROLE_KEY') || billing.includes('SUPABASE_SERVICE_ROLE_KEY')) throw new Error('A browser page references the Supabase service-role key.');
if (owner.includes('STRIPE_SECRET_KEY') || billing.includes('STRIPE_SECRET_KEY')) throw new Error('A browser page references the Stripe secret key.');

console.log('PASS: platform owner, crew-tier and subscription billing validation passed.');
