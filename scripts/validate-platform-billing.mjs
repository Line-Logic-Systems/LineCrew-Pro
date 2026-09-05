#!/usr/bin/env node
import fs from 'node:fs';
import vm from 'node:vm';

const requiredFiles = [
  'owner.html',
  'billing.html',
  'supabase/migrations/archive/20260818010000_platform_owner_and_billing.sql',
  'supabase/migrations/archive/20260818020000_crew_tier_usage_policy.sql',
  'supabase/migrations/archive/20260818030000_crew_tier_automation_and_visibility.sql',
  'supabase/migrations/archive/20260825000000_lock_crew_usage_rpc_execution.sql',
  'supabase/migrations/archive/20260824223848_enforce_active_crew_plan_limit.sql',
  'supabase/migrations/archive/20260825133736_harden_subscription_entitlements.sql',
  'supabase/functions/create-billing-checkout/index.ts',
  'supabase/functions/create-billing-portal/index.ts',
  'supabase/functions/create-plan-upgrade/index.ts',
  'supabase/functions/capture-crew-usage/index.ts',
  'supabase/functions/linecrew-assistant/index.ts',
  'supabase/functions/parse-utility-job-packet/index.ts',
  'supabase/functions/send-team-invitation/index.ts',
  'supabase/functions/stripe-webhook/index.ts',
  'supabase/functions/stripe-webhook/logic.ts',
  'supabase/functions/stripe-webhook/logic_test.ts',
  'supabase/functions/_shared/api-keys.ts',
  'supabase/functions/_shared/api-keys_test.ts',
  'supabase/functions/_shared/billing-pricing.ts',
  'supabase/migrations/20260905004706_licensed_crew_billing.sql',
  'supabase/config.toml',
  'scripts/test-platform-billing-isolation.mjs',
  '.github/workflows/test-platform-billing-isolation.yml',
  'internal-docs/PLATFORM_OWNER_BILLING.md',
];

for (const file of requiredFiles) {
  if (!fs.existsSync(file)) throw new Error(`Missing required platform billing file: ${file}`);
}

const owner = fs.readFileSync('owner.html', 'utf8');
const billing = fs.readFileSync('billing.html', 'utf8');
const app = fs.readFileSync('index.html', 'utf8');
const support = fs.readFileSync('support.html', 'utf8');
const training = fs.readFileSync('training/index.html', 'utf8');
const migration = fs.readFileSync('supabase/migrations/archive/20260818010000_platform_owner_and_billing.sql', 'utf8');
const crewPolicy = fs.readFileSync('supabase/migrations/archive/20260818020000_crew_tier_usage_policy.sql', 'utf8');
const crewAutomation = fs.readFileSync('supabase/migrations/archive/20260818030000_crew_tier_automation_and_visibility.sql', 'utf8');
const crewRpcLockdown = fs.readFileSync('supabase/migrations/archive/20260825000000_lock_crew_usage_rpc_execution.sql', 'utf8');
const crewLimitMigration = fs.readFileSync('supabase/migrations/archive/20260824223848_enforce_active_crew_plan_limit.sql', 'utf8');
const entitlementHardening = fs.readFileSync('supabase/migrations/archive/20260825133736_harden_subscription_entitlements.sql', 'utf8');
const licensedBilling = fs.readFileSync('supabase/migrations/20260905004706_licensed_crew_billing.sql', 'utf8');
const checkout = fs.readFileSync('supabase/functions/create-billing-checkout/index.ts', 'utf8');
const portal = fs.readFileSync('supabase/functions/create-billing-portal/index.ts', 'utf8');
const upgrade = fs.readFileSync('supabase/functions/create-plan-upgrade/index.ts', 'utf8');
const crewUsage = fs.readFileSync('supabase/functions/capture-crew-usage/index.ts', 'utf8');
const assistant = fs.readFileSync('supabase/functions/linecrew-assistant/index.ts', 'utf8');
const packetParser = fs.readFileSync('supabase/functions/parse-utility-job-packet/index.ts', 'utf8');
const teamInvitation = fs.readFileSync('supabase/functions/send-team-invitation/index.ts', 'utf8');
const webhook = fs.readFileSync('supabase/functions/stripe-webhook/index.ts', 'utf8');
const webhookLogic = fs.readFileSync('supabase/functions/stripe-webhook/logic.ts', 'utf8');
const webhookTests = fs.readFileSync('supabase/functions/stripe-webhook/logic_test.ts', 'utf8');
const edgeApiKeys = fs.readFileSync('supabase/functions/_shared/api-keys.ts', 'utf8');
const functionConfig = fs.readFileSync('supabase/config.toml', 'utf8');
const vercelConfig = JSON.parse(fs.readFileSync('vercel.json', 'utf8'));
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

for (const [name, source] of [['index.html', app], ['owner.html', owner], ['billing.html', billing], ['support.html', support], ['training/index.html', training]]) {
  if (!source.includes("LINECREW_PRODUCTION_HOSTS")) throw new Error(`${name} must use the exact production-host allowlist.`);
  if (source.includes("vercel\\.app$/i") || source.includes(".vercel.app$/i")) {
    throw new Error(`${name} must not treat every Vercel alias as production-capable.`);
  }
  for (const host of ['linecrewpro.com','www.linecrewpro.com','app.linecrewpro.com']) {
    if (!source.includes(host)) throw new Error(`${name} is missing production host ${host}.`);
  }
  if (!source.includes('https://yvuxrqrdprquxypiffpa.supabase.co')) throw new Error(`${name} must isolate Vercel previews in Supabase Test.`);
  if (!source.includes('SANDBOX TEST')) throw new Error(`${name} must visibly identify the test environment.`);
}

const productionCspRule = vercelConfig.headers.find(rule =>
  rule.has?.some(condition => condition.type === 'host' && String(condition.value).includes('linecrewpro')) &&
  !rule.missing
);
const productionCsp = productionCspRule?.headers?.find(header => header.key === 'Content-Security-Policy')?.value || '';
if (!productionCsp) throw new Error('vercel.json is missing the production-host CSP rule.');
if (productionCsp.includes('yvuxrqrdprquxypiffpa')) throw new Error('Production CSP must not allow the Supabase Test project.');
const sandboxCspRule = vercelConfig.headers.find(rule =>
  rule.missing?.some(condition =>
    condition.type === 'host' &&
    String(condition.value).includes('linecrewpro') &&
    String(condition.value).includes('app\\.linecrewpro\\.com')
  )
);
const sandboxCsp = sandboxCspRule?.headers?.find(header =>
  header.key === 'Content-Security-Policy'
)?.value || '';
if (!sandboxCsp) throw new Error('Sandbox CSP must allow the Supabase Test project.');
if (sandboxCsp.includes('ldgkyxuozbozgkvwzadg')) throw new Error('Sandbox CSP must not allow the production Supabase project.');

const migrationOrder = [
  '20260818010000_platform_owner_and_billing.sql',
  '20260818020000_crew_tier_usage_policy.sql',
  '20260818030000_crew_tier_automation_and_visibility.sql',
];
if (migrationOrder.join('\n') !== [...migrationOrder].sort().join('\n')) throw new Error('Billing migrations are not in dependency order.');
for (const legacy of ['20260818_platform_owner_and_billing.sql','20260818_crew_tier_usage_policy.sql','20260818_crew_tier_automation_and_visibility.sql']) {
  if (fs.existsSync(`supabase/migrations/${legacy}`)) throw new Error(`Legacy unordered migration still exists: ${legacy}`);
}

for (const marker of ['is_platform_owner','platform_owner_company_dashboard','platform_owner_set_subscription','editAccessOverride','internal_notes','rolling_overage_crew_days','recommended_plan_code']) {
  if (!owner.includes(marker)) throw new Error(`owner.html is missing ${marker}`);
}
for (const marker of ['my_company_billing_summary','create-billing-checkout','create-billing-portal','create-plan-upgrade','stripe_subscription_linked','rolling_peak_billable_crews','crew_overage_status']) {
  if (!billing.includes(marker)) throw new Error(`billing.html is missing ${marker}`);
}
for (const marker of [
  "billingResult==='portal-return'",
  'Returned from Stripe Billing. Checking for subscription updates...',
  'Cancellation scheduled for ',
  'App access remains enabled until then.',
  'Stripe Checkout was closed. No new subscription was created.',
  "billingResult==='access-blocked'",
  'Start or restore the subscription below to restore access for your whole team.',
]) {
  if (!billing.includes(marker)) throw new Error(`billing.html is missing portal return state: ${marker}`);
}
for (const signature of [
  'capture_company_crew_usage(uuid,date)',
  'capture_all_company_crew_usage(date)',
  'recalculate_company_crew_overage(uuid)',
]) {
  const escaped = signature.replace(/[()]/g, value => `\\${value}`);
  if (!new RegExp(`revoke all on function public\\.${escaped}[^;]*from public, anon, authenticated`, 'is').test(crewRpcLockdown)) {
    throw new Error(`Crew usage ACL lockdown is missing authenticated revoke for ${signature}.`);
  }
}
if (!crewRpcLockdown.includes('last_stripe_event_created bigint')) throw new Error('Crew RPC lockdown migration must add the Stripe event ordering column.');
for (const marker of [
  "billingResult==='capacity-return'",
  'Change Licensed Crew Slots',
  '$85 per month, with no upper tier.',
  '{target_crew_limit:crews}',
  "billing?.provider==='stripe'",
]) {
  if (!billing.includes(marker)) throw new Error(`billing.html is missing safe upgrade UI state: ${marker}`);
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

for (const marker of ['enforce_active_crew_plan_limit','pg_advisory_xact_lock','up to % active crews','before insert or update of active, company_id']) {
  if (!crewLimitMigration.includes(marker)) throw new Error(`Active crew plan-limit migration missing ${marker}.`);
}

for (const marker of ['planForSubscriptionEvent','BILLING_PLAN_PRICE_MAP','recalculate_company_crew_overage','last_stripe_event_created','eventCreatedSeconds','resolveCompanyId','assertEventEnvironment']) {
  if (!webhook.includes(marker)) throw new Error(`Stripe webhook missing hardened synchronization marker ${marker}.`);
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
if (!checkout.includes('readLinecrewPriceId')) throw new Error('Checkout must bind the single LineCrew Pro price server-side.');
if (!checkout.includes('["owner", "admin"].includes(String(profile.role).toLowerCase())')) throw new Error('Checkout must require company Owner or Admin role.');
for (const [name, source] of [
  ['Checkout', checkout],
  ['Billing portal', portal],
  ['Plan upgrade', upgrade],
]) {
  if (!source.includes('.getClaims(accessToken)') || !source.includes('claimsData?.claims?.aal !== "aal2"')) {
    throw new Error(`${name} must explicitly require a verified aal2 JWT before using the service client.`);
  }
}
if (!checkout.includes('already has a Stripe subscription')) throw new Error('Checkout must guard against duplicate live subscriptions.');
if (/\.update\(\{[^}]*\b(?:plan_code|status|access_enabled|trial_ends_at)\b/s.test(checkout)) {
  throw new Error('Starting Checkout must not overwrite an existing company entitlement.');
}
if ((checkout.match(/status:\s*"incomplete"/g) || []).length !== 1 ||
    (checkout.match(/access_enabled:\s*false/g) || []).length !== 1) {
  throw new Error('Only a brand-new subscription seed may start incomplete and blocked.');
}
for (const marker of [
  'if (existing)',
  'stripe_customer_id: customerId',
  '.is("stripe_customer_id", null)',
  'metadata[plan_code]',
  'subscription_data[metadata][plan_code]',
]) {
  if (!checkout.includes(marker)) throw new Error(`Checkout is missing metadata-only entitlement safety marker: ${marker}`);
}
if (!app.includes('companyAccessInactive(accessStatusError)') ||
    !app.includes("window.location.replace('/billing.html?billing=access-blocked')")) {
  throw new Error('Blocked Owner/Admin access must route to the exempt Company Billing recovery page.');
}
if (!portal.includes('["owner", "admin"].includes(String(profile.role).toLowerCase())')) throw new Error('Billing portal must require company Owner or Admin role.');
if (!portal.includes('/billing.html?billing=portal-return')) throw new Error('Billing portal must return to the contractor billing page.');
for (const marker of ['STRIPE_MANAGE_PORTAL_CONFIGURATION_ID','linecrew_manage_only_v1','subscription_update','update?.enabled !== true','params.set("configuration", portalConfiguration)']) {
  if (!portal.includes(marker)) throw new Error(`Manage Billing portal is missing required safety marker: ${marker}`);
}
for (const marker of [
  'STRIPE_UPGRADE_PORTAL_CONFIGURATION_ID',
  'linecrew_crew_quantity_v1',
  'allowedUpdates.length === 1',
  'update?.proration_behavior === "always_invoice"',
  'linecrew-crew-quantity-portal-${upgradePortalPurpose}',
  'BILLING_PLAN_PRICE_MAP',
  '["owner", "admin"].includes(String(profile.role).toLowerCase())',
  'subscription.customer !== stored.stripe_customer_id',
  'items.length !== 1',
  'targetCrewLimit < currentCrewLimit',
  'proration_behavior", "none"',
  'flow_data[type]',
  'subscription_update_confirm',
  'flow_data[subscription_update_confirm][items][0][price]',
  '/billing.html?billing=capacity-return&target_crews=',
]) {
  if (!upgrade.includes(marker)) throw new Error(`Upgrade function is missing required safety marker: ${marker}`);
}
for (const marker of ['59900', '8500', "when 'linecrew' then 5", 'p_included_crew_limit', 'coalesce(subscription.included_crew_limit']) {
  if (!licensedBilling.toLowerCase().includes(marker.toLowerCase())) throw new Error(`Licensed crew billing migration is missing ${marker}.`);
}
if (!webhook.includes('stripe-signature') || !webhook.includes('verifyStripeSignature')) throw new Error('Stripe webhook signature validation is missing.');
if (!webhook.includes('eventInsertError.code !== "23505"')) throw new Error('Stripe webhook must recognize unique-event retries by PostgreSQL error code.');
if (!webhook.includes('priorEvent?.processed_at')) throw new Error('Stripe webhook must distinguish completed duplicates from retryable failed events.');
if (!webhook.includes('invoice.paid is intentionally audit-only')) throw new Error('Stripe invoice.paid must not blindly reactivate a subscription.');
if (!webhook.includes('scheduledCancelUnix') || !webhook.includes('scheduledCancelUnix === currentPeriodEndUnix')) {
  throw new Error('Stripe webhook must recognize cancel_at resolved to the current period end.');
}
if (!webhook.includes('Checkout completion only links Stripe identities')) {
  throw new Error('Checkout completion must not overwrite subscription plan or price state.');
}
if (!webhookLogic.includes('eventType === "customer.subscription.deleted"')) throw new Error('Cancellation must be handled independently of the current price map.');
if (!webhookLogic.includes('return prior') || !webhookTests.includes('deleted event keeps prior plan without map')) throw new Error('Cancellation-with-rotated-price regression coverage is missing.');
if (!webhookTests.includes('older events are stale')) throw new Error('Out-of-order Stripe event regression coverage is missing.');
if (!webhookTests.includes('customer-metadata mismatch rejects')) throw new Error('Stripe customer/company ownership regression coverage is missing.');
if (!webhookTests.includes('mismatched livemode rejects')) throw new Error('Stripe live/test separation regression coverage is missing.');
if (!upgrade.includes('if (configuredId)') || !upgrade.includes('configuration ID is invalid')) throw new Error('Upgrade portal must reject a malformed explicit configuration ID.');
const authCheckPosition = upgrade.indexOf('["owner", "admin"].includes(String(profile.role).toLowerCase())');
const portalResolutionPosition = upgrade.indexOf('const portalConfiguration = await resolveUpgradePortalConfiguration');
if (authCheckPosition < 0 || portalResolutionPosition < authCheckPosition) throw new Error('Upgrade portal contacts Stripe before verifying the company Admin.');

for (const marker of [
  'revoke all on function public.set_billing_export_batch_status(uuid,text)',
  'revoke update on table public.companies from authenticated',
  "when 'pilot' then 5",
  "now() + interval '14 days'",
  'v_subscription_found',
  "v_status = 'past_due'",
  "now() - interval '7 days'",
  "v_role not in ('owner','admin')",
]) {
  if (!entitlementHardening.toLowerCase().includes(marker.toLowerCase())) {
    throw new Error(`Subscription entitlement hardening is missing ${marker}`);
  }
}
if (!webhookLogic.includes('return ["active", "trialing", "past_due"].includes(status)')) {
  throw new Error('Stripe access helper must deny incomplete and terminal statuses.');
}
if (!webhookTests.includes('incomplete access is disabled')) {
  throw new Error('Stripe incomplete-access regression coverage is missing.');
}

for (const [name, verifyJwt] of [
  ['stripe-webhook', false],
  ['complete-team-invitation-signup', false],
  ['capture-crew-usage', false],
  ['create-billing-checkout', false],
  ['create-billing-portal', false],
  ['create-plan-upgrade', false],
  ['linecrew-assistant', false],
  ['parse-utility-job-packet', false],
  ['send-team-invitation', false],
]) {
  const block = new RegExp(`\\[functions\\.${name}\\]\\s+verify_jwt\\s*=\\s*${verifyJwt}`, 'm');
  if (!block.test(functionConfig)) throw new Error(`supabase/config.toml must explicitly set verify_jwt=${verifyJwt} for ${name}.`);
}

for (const [name, source] of [
  ['create-billing-checkout', checkout],
  ['create-billing-portal', portal],
  ['create-plan-upgrade', upgrade],
  ['linecrew-assistant', assistant],
  ['parse-utility-job-packet', packetParser],
  ['send-team-invitation', teamInvitation],
]) {
  if (!source.includes('headers.get("Authorization")')) {
    throw new Error(`${name} must require an Authorization header before running with verify_jwt=false.`);
  }
  if (!source.includes('.getUser()')) {
    throw new Error(`${name} must validate the caller through Supabase Auth before running with verify_jwt=false.`);
  }
}

for (const marker of ['DISPOSABLE_ONLY','SUPABASE_PRODUCTION_PROJECT_REF','platform_owner_company_dashboard','my_company_billing_summary','my_company_subscription_access','company_subscriptions','platform_owners','Foreman accessed company Admin billing summary']) {
  if (!isolation.includes(marker)) throw new Error(`billing isolation harness is missing ${marker}`);
}
if (!isolationWorkflow.includes('environment: isolation-test')) throw new Error('billing isolation workflow must use the protected isolation-test environment.');
if (!isolationWorkflow.includes('LINECREW_ISOLATION_TEST_CONFIRM')) throw new Error('billing isolation workflow is missing disposable-project confirmation.');

const publicFiles = [owner, billing, checkout, portal, upgrade, webhook].join('\n');
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

for (const marker of ['SUPABASE_PUBLISHABLE_KEYS', 'SUPABASE_SECRET_KEYS', 'edge_functions_admin']) {
  if (!edgeApiKeys.includes(marker)) throw new Error(`Edge API-key helper is missing ${marker}.`);
}
for (const marker of ['req.headers.get("apikey")', 'req.headers.get("x-linecrew-cron-secret")', 'getSecretKey()']) {
  if (!crewUsage.includes(marker)) throw new Error(`capture-crew-usage is missing dual-auth marker ${marker}.`);
}
for (const [name, source] of [
  ['create-billing-checkout', checkout],
  ['create-billing-portal', portal],
  ['create-plan-upgrade', upgrade],
  ['stripe-webhook', webhook],
  ['capture-crew-usage', crewUsage],
]) {
  if (/SUPABASE_(?:ANON_KEY|SERVICE_ROLE_KEY)/.test(source)) {
    throw new Error(`${name} still depends on a legacy Supabase API key.`);
  }
  if (!source.includes('getSecretKey()') && !source.includes('getPublishableKey()')) {
    throw new Error(`${name} is not wired to the named Supabase API-key environment.`);
  }
}

console.log('PASS: platform owner, crew-tier and subscription billing validation passed.');
