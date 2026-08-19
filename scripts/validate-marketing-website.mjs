#!/usr/bin/env node
import fs from 'node:fs';
const files=['website/index.html','website/styles.css','website/features.html','website/pricing.html','website/demo.html','website/training.html','website/signup.html','website/privacy.html','website/terms.html','website/404.html','website/favicon.svg','website/README.md','hero-clean.jpg'];
for(const f of files){if(!fs.existsSync(f))throw new Error(`Missing ${f}`)}
const read=f=>fs.readFileSync(f,'utf8');
const html=read('website/index.html');
const signup=read('website/signup.html');
const styles=read('website/styles.css');
for(const marker of ['Daily Production','JSA &amp; Safety','Job Packets','Storm Mode','$499','$749','$1,199','$1,799','Request a Demo','BUILT BY LINEMEN. FOR LINEMEN.']){if(!html.includes(marker))throw new Error(`Homepage missing ${marker}`)}
if(!html.includes('https://app.linecrewpro.com/'))throw new Error('Homepage App Login must point to app.linecrewpro.com');
if(!styles.includes("../hero-clean.jpg"))throw new Error('Approved hero image is not wired into website CSS');
if(!signup.includes('Continue to secure checkout')||!signup.includes('disabled'))throw new Error('Signup preview must keep paid checkout disabled.');
for(const f of ['website/index.html','website/features.html','website/pricing.html','website/demo.html','website/training.html','website/signup.html']){
  const text=read(f);
  if(!text.includes('site-header'))throw new Error(`${f} is missing the unified header`);
  if(!text.includes('favicon.svg'))throw new Error(`${f} is missing the favicon`);
}
const allText=files.filter(f=>f.endsWith('.html')||f.endsWith('.css')).map(read).join('\n');
for(const obsolete of ['hero-reference.jpg','hero-realistic.svg','powerline-silhouette.svg']){if(allText.includes(obsolete))throw new Error(`Obsolete hero reference remains: ${obsolete}`)}
for(const secret of [/sk_live_[A-Za-z0-9]+/,/sk_test_[A-Za-z0-9]+/,/SUPABASE_SERVICE_ROLE_KEY/,/STRIPE_SECRET_KEY/]){if(secret.test(allText))throw new Error(`Potential secret in public website: ${secret}`)}
console.log('PASS: LineCrew Pro marketing website validation passed.');
