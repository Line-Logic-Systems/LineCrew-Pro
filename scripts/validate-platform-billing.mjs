#!/usr/bin/env node
import fs from 'node:fs';

const requiredFiles = [
  'owner.html',
  'supabase/migrations/20260818_platform_owner_and_billing.sql',
  'supabase/functions/create-billing-checkout/index.ts',
  'supabase/functions/create-billing-portal/index.ts',
  'supabase/functions/stripe-webhook/index.ts',
  'docs/PLATFORM_OWNER_BILLING.md',
];

for (const file of requiredFiles) {
  if (!fs.existsSync(file)) throw new Error(`Missing required platform billing file: ${file}`);
}

const owner = fs.readFileSync('owner.html', 'utf8');
const migration = fs.readFileSync('supabase/migrations/20260818_platform_owner_and_billing.sql', 'utf8');
const checkout = fs.readFileSync('supabase/functions/create-billing-checkout/index.ts', 'utf8');
const portal = fs.readFileSync('supabase/functions/create-billing-portal/index.ts', 'utf8');
const webhook = fs.readFileSync('supabase/functions/stripe-webhook/index.ts', 'utf8');

const requiredOwnerMarkers = ['is_platform_owner', 'platform_owner_company_dashboard', 'platform_owner_set_subscription'];
for (const marker of requiredOwnerMarkers) {
  if (!owner.includes(marker)) throw new Error(`owner.html is missing ${marker}`);
}

const requiredSqlMarkers = [
  'create table if not exists public.platform_owners',
  'create table if not exists public.company_subscriptions',
  'create table if not exists public.billing_events',
  'revoke all on public.platform_owners from anon, authenticated',
  'revoke all on public.company_subscriptions from anon, authenticated',
  'platform_owner_company_dashboard',
  'my_company_subscription_access',
];
for (const marker of requiredSqlMarkers) {
  if (!migration.toLowerCase().includes(marker.toLowerCase())) throw new Error(`billing migration is missing ${marker}`);
}

if (!checkout.includes('BILLING_ALLOWED_PRICE_IDS')) throw new Error('Checkout must restrict allowed Stripe Price IDs.');
if (!checkout.includes('String(profile.role).toLowerCase() !== "admin"')) throw new Error('Checkout must require company Admin role.');
if (!portal.includes('String(profile.role).toLowerCase() !== "admin"')) throw new Error('Billing portal must require company Admin role.');
if (!webhook.includes('stripe-signature') || !webhook.includes('verifyStripeSignature')) throw new Error('Stripe webhook signature validation is missing.');
if (!webhook.includes('provider_event_id')) throw new Error('Stripe webhook idempotency marker is missing.');

const publicFiles = [owner, checkout, portal, webhook].join('\n');
const forbiddenSecretAssignments = [
  /STRIPE_SECRET_KEY\s*=\s*['"][^'"]+['"]/i,
  /SUPABASE_SERVICE_ROLE_KEY\s*=\s*['"][^'"]+['"]/i,
  /STRIPE_WEBHOOK_SECRET\s*=\s*['"][^'"]+['"]/i,
];
for (const pattern of forbiddenSecretAssignments) {
  if (pattern.test(publicFiles)) throw new Error(`Potential hard-coded secret detected: ${pattern}`);
}

console.log('PASS: platform owner and subscription billing foundation validation passed.');
