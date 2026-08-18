#!/usr/bin/env node
import fs from 'node:fs';
const files=['website/index.html','website/styles.css','website/signup.html','website/README.md'];
for(const f of files){if(!fs.existsSync(f))throw new Error(`Missing ${f}`)}
const html=fs.readFileSync('website/index.html','utf8');
const signup=fs.readFileSync('website/signup.html','utf8');
for(const marker of ['Daily Production','JSA & Safety','Job Packets','Storm Mode','$499','$749','$1,199','$1,799','Request a Demo']){if(!html.includes(marker))throw new Error(`Homepage missing ${marker}`)}
if(!signup.includes('Continue to secure checkout')||!signup.includes('disabled'))throw new Error('Signup preview must keep paid checkout disabled.');
const publicText=html+'\n'+signup+'\n'+fs.readFileSync('website/styles.css','utf8');
for(const secret of [/sk_live_[A-Za-z0-9]+/,/sk_test_[A-Za-z0-9]+/,/SUPABASE_SERVICE_ROLE_KEY/,/STRIPE_SECRET_KEY/]){if(secret.test(publicText))throw new Error(`Potential secret in public website: ${secret}`)}
console.log('PASS: LineCrew Pro marketing website validation passed.');
