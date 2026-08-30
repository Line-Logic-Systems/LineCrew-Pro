import fs from 'node:fs';

function read(path){
  if(!fs.existsSync(path)) throw new Error(`Missing Beta onboarding file: ${path}`);
  return fs.readFileSync(path,'utf8');
}
function requireText(text,needle,message){if(!text.includes(needle))throw new Error(message)}
function rejectText(text,needle,message){if(text.includes(needle))throw new Error(message)}

const migration=read('supabase/migrations/20260830073000_beta_application_onboarding.sql');
const submit=read('supabase/functions/submit-beta-application/index.ts');
const review=read('supabase/functions/review-beta-application/index.ts');
const accept=read('beta-accept.html');
const owner=read('owner.html');
const polish=read('app-polish.js');
const convert=read('pilot-convert.html');
const vercel=read('vercel.json');
const pricing=read('docs/pricing.html');
const home=read('docs/index.html');
const beta=read('docs/beta.html');

for(const marker of [
  'alter table public.beta_applications enable row level security',
  'revoke all on table public.beta_applications from public, anon, authenticated',
  "grant all on table public.beta_applications to service_role",
  'public.is_platform_owner()',
  "intended_role, intended_full_name",
  "'admin'",
  "plan_code='pilot'",
  "monthly_price_cents=0",
  'p_pilot_ends_at',
  "trial_ends_at=p_pilot_ends_at",
  'platform_owner_audit_events',
]) requireText(migration,marker,`Beta migration security requirement missing: ${marker}`);

for(const signature of [
  'platform_owner_beta_applications()',
  'platform_owner_prepare_beta_company(uuid,text,timestamptz,timestamptz)',
  'platform_owner_mark_beta_invite_sent(uuid)',
  'platform_owner_decline_beta_application(uuid)',
]){
  requireText(migration,`revoke all on function public.${signature} from public, anon`,`${signature} must not be public/anonymous`);
}
rejectText(migration,'grant execute on function public.platform_owner_prepare_beta_company(uuid,text,timestamptz,timestamptz) to anon','Anonymous users must never approve Beta companies.');

for(const marker of ['ALLOWED_ORIGINS','content-length','website','request_fingerprint_hash','count: "exact"','getSecretKey()']){
  requireText(submit,marker,`Public Beta submission protection missing: ${marker}`);
}
rejectText(submit,'SUPABASE_SERVICE_ROLE_KEY','Public submission function must use the shared server secret helper, not a legacy hard-coded service-role variable.');

for(const marker of ['Authorization','admin.auth.getUser','platform_owners','platform_owner_prepare_beta_company','RESEND_API_KEY','base64Url','sha256Hex','beta-accept.html?invite=']){
  requireText(review,marker,`Owner review protection missing: ${marker}`);
}
rejectText(review,'inviteUserByEmail','Beta approval must not pre-create an Auth user before the applicant chooses a password.');
for(const marker of ['complete-team-invitation-signup','signInWithPassword','No additional email is required','autocomplete="new-password"']){
  requireText(accept,marker,`Beta account setup requirement missing: ${marker}`);
}
requireText(owner,"rpc('platform_owner_beta_applications')",'Platform Owner console must load Beta applications through the owner-only RPC.');
requireText(owner,"functions.invoke('review-beta-application'",'Platform Owner console must review Beta applications through the secured Edge Function.');
requireText(owner,'Approve','Platform Owner console is missing Approve.');
requireText(owner,'Decline','Platform Owner console is missing Decline.');

requireText(polish,"rpc('my_company_subscription_access')",'Pilot checklist must determine Pilot status from server-controlled subscription access.');
requireText(polish,"String(subscription?.plan_code||'').toLowerCase()!=='pilot'",'Pilot checklist must remain limited to Pilot companies.');
rejectText(polish,'raw_user_meta_data','Pilot UI must not authorize from user-controlled metadata.');
requireText(polish,'billing.html?pilot_conversion=1','Pilot checklist must link to the paid conversion route.');

for(const marker of ['create-billing-checkout','requested_plan','getAuthenticatorAssuranceLevel','my_company_billing_summary']){
  requireText(convert,marker,`Pilot conversion security requirement missing: ${marker}`);
}
requireText(vercel,'"pilot_conversion"','Vercel must route the Pilot conversion query to the dedicated chooser.');
requireText(vercel,'"destination": "/pilot-convert.html"','Pilot conversion rewrite is missing its destination.');

for(const [name,text] of [['pricing',pricing],['home',home]]){
  requireText(text,'href="beta.html"',`${name} Beta CTA must use the secure application form.`);
  rejectText(text,'LineCrew%20Pro%20Beta%2FPilot%20Application',`${name} must not retain the legacy Beta mailto application.`);
}
for(const marker of ['Submit Beta Application','/functions/v1/submit-beta-application','name="website"','No payment information is collected here.']){
  requireText(beta,marker,`Beta website form missing: ${marker}`);
}

console.log('Beta onboarding security guardrails passed.');
