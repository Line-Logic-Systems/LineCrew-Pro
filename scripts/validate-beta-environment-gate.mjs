import fs from 'node:fs';
import assert from 'node:assert/strict';

const beta=fs.readFileSync('docs/beta.html','utf8');

for(const host of ['linecrewpro.com','www.linecrewpro.com','app.linecrewpro.com']){
  assert.ok(beta.includes(`'${host}'`),`Beta page production host gate is missing ${host}.`);
}
assert.ok(beta.includes("LINECREW_PRODUCTION_HOSTS.has(window.location.hostname.toLowerCase())"),'Beta page must derive environment from the current host.');
assert.ok(beta.includes("IS_LINECREW_PRODUCTION?'https://ldgkyxuozbozgkvwzadg.supabase.co':'https://yvuxrqrdprquxypiffpa.supabase.co'"),'Beta page must route previews away from production Supabase.');
assert.ok(beta.includes("IS_LINECREW_PRODUCTION?'sb_publishable_U1i3_vuo8mMELcpcsW7aog_bcPNlYYF':'sb_publishable_4_B1KxInXhARmcfE6LLAyA_5O7bSoqx'"),'Beta page must keep the publishable key paired with the selected environment.');
assert.ok(beta.includes("const endpoint=SUPABASE_URL+'/functions/v1/submit-beta-application'"),'Beta form must derive its Edge Function endpoint from the gated Supabase URL.');
assert.ok(!/const SUPABASE_URL='https:\/\/ldgkyxuozbozgkvwzadg\.supabase\.co'/.test(beta),'Beta page must not hard-code production as the only submission target.');

console.log('Beta environment-gate validation passed.');
