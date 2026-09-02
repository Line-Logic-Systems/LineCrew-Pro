import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';

const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
const app = fs.readFileSync(path.join(root, 'index.html'), 'utf8');
const migration = fs.readFileSync(
  path.join(root, 'supabase/migrations/archive/20260830002006_company_logo_upload.sql'),
  'utf8'
);

const checks = [
  ['URL-only logo field removed', !app.includes('id="companyLogoUrl"')],
  ['direct image input exists', app.includes('id="companyLogoFile"') && app.includes('accept="image/png,image/jpeg,image/webp"')],
  ['client validates a 2 MB limit', app.includes("COMPANY_LOGO_MAX_BYTES = 2 * 1024 * 1024")],
  ['uploads use the company logo bucket', app.includes("const COMPANY_LOGO_BUCKET = 'company-logos'")],
  ['uploads are company-folder scoped', app.includes("currentCompany.id + '/logo-' + Date.now()")],
  ['failed settings save cleans up a new upload', app.includes("if(uploadedLogo){\nawait sb.storage.from(COMPANY_LOGO_BUCKET).remove")],
  ['desktop and mobile header branding exists', app.includes('id="companyBrandBadge"') && app.includes('@media(max-width:600px)')],
  ['printed reports retain the company logo', app.includes("const logo = currentCompany?.logo_url")],
  ['bucket allows only supported image types', migration.includes("array['image/png','image/jpeg','image/webp']")],
  ['bucket enforces the 2 MB limit', migration.includes('2097152')],
  ['upload policy requires company settings capability', migration.includes("public.linecrew_has_capability('company_settings')")],
  ['storage paths are tenant scoped', migration.includes("(storage.foldername(name))[1]") && migration.includes('p.company_id::text')],
  ['anonymous writes are not granted', !migration.match(/to\s+anon/i)]
];

let failed = 0;
for (const [name, ok] of checks) {
  console.log(`${ok ? 'PASS' : 'FAIL'} ${name}`);
  if (!ok) failed += 1;
}

if (failed) {
  console.error(`\n${failed} company-logo validation check(s) failed.`);
  process.exit(1);
}

console.log(`\nAll ${checks.length} company-logo upload checks passed.`);
