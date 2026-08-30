import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { extname, join } from 'node:path';

const root = new URL('..', import.meta.url).pathname;
const docsDir = join(root, 'docs');
const htmlFiles = readdirSync(docsDir).filter((file) => extname(file) === '.html').sort();
const markdownFiles = readdirSync(docsDir, { recursive: true })
  .filter((file) => extname(file) === '.md')
  .sort();
const failures = [];

const requiredCanonical = new Set([
  'index.html',
  'features.html',
  'pricing.html',
  'training.html',
  'demo.html',
  'contact.html',
  'privacy.html',
  'terms.html',
  'subscriber.html',
]);

const fail = (file, message) => failures.push(`${file}: ${message}`);

if (markdownFiles.length) {
  fail('docs/', `must contain public site assets only; move Markdown to internal-docs/: ${markdownFiles.join(', ')}`);
}
if (existsSync(join(docsDir, '.nojekyll'))) {
  fail('.nojekyll', 'must not bypass the Jekyll exclusions that protect internal runbooks');
}

for (const file of htmlFiles) {
  const html = readFileSync(join(docsDir, file), 'utf8');

  if (html.includes('Line Logic Systems')) fail(file, 'contains the former business name');
  if (!html.includes('© 2026 LineCrew Pro LLC')) fail(file, 'footer must identify LineCrew Pro LLC');

  if (!html.includes('styles.css?v=site7')) fail(file, 'must use the current site stylesheet version');
  if (!html.includes('accessibility.css?v=site5')) fail(file, 'must load the accessibility stylesheet');
  if (!html.includes('class="skip-link"')) fail(file, 'must include a keyboard skip link');
  if (!html.includes('<main id="main-content">')) fail(file, 'must identify the main content target');

  if (requiredCanonical.has(file) && !html.includes('<link rel="canonical"')) {
    fail(file, 'must include a canonical URL');
  }

  if (requiredCanonical.has(file)) {
    for (const marker of ['property="og:image"', 'name="twitter:card"', 'name="twitter:image"']) {
      if (!html.includes(marker)) fail(file, `missing social metadata: ${marker}`);
    }
  }

  const h1Count = (html.match(/<h1(?:\s[^>]*)?>/g) || []).length;
  if (h1Count !== 1) fail(file, `expected exactly one h1, found ${h1Count}`);

  if (/raw\.githubusercontent\.com|github\.com\/.+\/blob\/|localhost|127\.0\.0\.1/i.test(html)) {
    fail(file, 'contains a source-control, local, or preview URL');
  }

  for (const match of html.matchAll(/href="([^"]+)"/g)) {
    const href = match[1];
    if (/^(?:https?:|mailto:|tel:|#)/.test(href)) continue;
    const target = href.split('#')[0].split('?')[0];
    if (!target) continue;
    if (!existsSync(join(docsDir, target))) fail(file, `local link target does not exist: ${target}`);
  }

  if (/Request (?:a )?Demo|Request Demo|Contact Sales/.test(html)) {
    if (html.includes('href="demo.html"')) fail(file, 'demo actions must open a prewritten email instead of another page');
    if (!html.includes('mailto:sales@linecrewpro.com?subject=LineCrew%20Pro%20Demo%20Request')) {
      fail(file, 'demo actions must address sales@linecrewpro.com with the approved subject');
    }
    if (!html.includes('personalized%20demo') || !html.includes('Number%20of%20active%20crews')) {
      fail(file, 'demo email must include informative copy and qualification fields');
    }
  }
}

const home = readFileSync(join(docsDir, 'index.html'), 'utf8');
const pricing = readFileSync(join(docsDir, 'pricing.html'), 'utf8');
for (const [file, html] of [['index.html', home], ['pricing.html', pricing]]) {
  for (const marker of ['$1,799', '21–40 crews', 'Running 41+ active crews?', 'Get 41+ Crew Information']) {
    if (!html.includes(marker)) fail(file, `pricing presentation is missing: ${marker}`);
  }
  if (!html.includes('LineCrew%20Pro%2041%2B%20Crew%20Information')) {
    fail(file, '41+ crew action must open its dedicated prewritten sales email');
  }
  if (!html.includes('operates%20more%20than%2040%20active%20crews') || !html.includes('Active%20crew%20count')) {
    fail(file, '41+ crew email must use the approved concise custom-plan message');
  }
  for (const plan of ['starter', 'business', 'pro', 'enterprise']) {
    if (!html.includes(`https://app.linecrewpro.com/?plan=${plan}`)) {
      fail(file, `pricing must provide Start Now for the ${plan} plan`);
    }
  }
  for (const marker of ['Interested in becoming a Beta/Pilot company?', 'Approved pilots are free and require no card.', 'Apply for Beta/Pilot']) {
    if (!html.includes(marker)) fail(file, `Beta/Pilot presentation is missing: ${marker}`);
  }
  if (!html.includes('href="beta.html"')) {
    fail(file, 'Beta/Pilot action must open the secure website application form');
  }
  if (html.includes('LineCrew%20Pro%20Beta%2FPilot%20Application')) {
    fail(file, 'Beta/Pilot action must not use the legacy mailto application');
  }
}

const beta = readFileSync(join(docsDir, 'beta.html'), 'utf8');
for (const marker of [
  'Submit Beta Application',
  'name="company_name"',
  'name="contact_name"',
  'name="email"',
  'name="phone"',
  'name="active_crew_count"',
  'name="testing_notes"',
  'name="website"',
  '/functions/v1/submit-beta-application',
  'No payment information is collected here.',
]) {
  if (!beta.includes(marker)) fail('beta.html', `secure Beta/Pilot form is missing: ${marker}`);
}
if (!beta.includes("'apikey':SUPABASE_KEY")) {
  fail('beta.html', 'Beta/Pilot form must call the public Edge Function with the publishable API key');
}

const signup = readFileSync(join(docsDir, 'signup.html'), 'utf8');
for (const field of ['company-name', 'admin-email', 'primary-contact', 'phone', 'active-crews', 'state']) {
  if (!signup.includes(`for="${field}"`)) fail('signup.html', `label is not connected to ${field}`);
  if (!signup.includes(`id="${field}"`)) fail('signup.html', `field is missing id ${field}`);
}
if (!signup.includes('name="robots" content="noindex,follow"')) {
  fail('signup.html', 'inactive checkout preview must remain noindex');
}
if (!signup.includes('Checkout is not active yet.')) {
  fail('signup.html', 'must explain the disabled checkout beside the control');
}

const terms = readFileSync(join(docsDir, 'terms.html'), 'utf8');
if (terms.includes('Public paid subscriptions are not yet enabled')) {
  fail('terms.html', 'must not contradict the live paid-subscription funnel');
}
for (const marker of [
  'LineCrew Pro LLC',
  'automatically renew for successive one-month periods',
  'Cancellation takes effect at the end of the then-current paid billing period',
  'Payments are non-refundable',
  'Warranty disclaimer',
  'Limitation of liability',
  'laws of the State of Texas',
]) {
  if (!terms.includes(marker)) fail('terms.html', `subscription terms are missing: ${marker}`);
}

const privacy = readFileSync(join(docsDir, 'privacy.html'), 'utf8');
for (const marker of ['LineCrew Pro LLC', 'process commercial subscriptions and payments', 'Subscription payments are processed by Stripe', 'does not receive or store complete payment-card numbers']) {
  if (!privacy.includes(marker)) fail('privacy.html', `payment privacy disclosure is missing: ${marker}`);
}

const sitemap = readFileSync(join(docsDir, 'sitemap.xml'), 'utf8');
for (const page of requiredCanonical) {
  const url = page === 'index.html' ? 'https://linecrewpro.com/' : `https://linecrewpro.com/${page}`;
  if (!sitemap.includes(`<loc>${url}</loc>`)) fail('sitemap.xml', `missing ${url}`);
}
if (sitemap.includes('/signup.html')) fail('sitemap.xml', 'must not include the noindex signup preview');

const vercelIgnore = readFileSync(join(root, '.vercelignore'), 'utf8');
for (const ignored of ['docs/', 'internal-docs/', 'supabase/', 'scripts/', '.github/']) {
  if (!vercelIgnore.split(/\r?\n/).includes(ignored)) fail('.vercelignore', `missing ${ignored}`);
}

if (failures.length) {
  console.error(`Marketing validation failed (${failures.length}):`);
  for (const failure of failures) console.error(`- ${failure}`);
  process.exit(1);
}

console.log(`Marketing validation passed for ${htmlFiles.length} HTML pages.`);