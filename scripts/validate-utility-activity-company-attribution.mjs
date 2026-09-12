import fs from 'node:fs';
import assert from 'node:assert/strict';

const path='supabase/migrations/20260912015254_repair_utility_activity_company_attribution.sql';
if(!fs.existsSync(path)) throw new Error(`Missing Utility activity attribution migration: ${path}`);
const sql=fs.readFileSync(path,'utf8');

for(const token of [
  'create or replace function public.linecrew_expand_utility_activity_company()',
  "when (new.company_id is null and new.utility_organization_id is not null)",
  'select distinct access.company_id',
  'access.granted_at <= new.created_at',
  '(access.revoked_at is null or access.revoked_at > new.created_at)',
  '(access.expires_at is null or access.expires_at > new.created_at)',
  'delete from public.utility_activity_log activity',
  'revoke all on function public.linecrew_expand_utility_activity_company() from public, anon, authenticated',
  'count(distinct access.company_id) as company_count',
  'historical_match.company_count = 1'
]){
  assert.ok(sql.includes(token), `Missing Utility activity attribution guard: ${token}`);
}

// The trigger must fan out org-level activity; it must never choose a company by
// arbitrary LIMIT 1, which would misattribute a multi-contractor utility.
assert.doesNotMatch(sql,/\blimit\s+1\b/i,'Utility activity attribution must not arbitrarily choose one contractor company.');

// Historical repair must preserve existing log rows whenever attribution is
// unambiguous rather than recreating their ids/timestamps.
assert.match(sql,/update public\.utility_activity_log activity\s+set company_id = historical_match\.company_id/is);

console.log('Utility activity company-attribution guard passed.');
