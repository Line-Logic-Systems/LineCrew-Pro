import fs from 'node:fs';

const path='supabase/migrations/20260912005835_repair_company_ownership_transfer.sql';
if(!fs.existsSync(path)) throw new Error('Missing ownership transfer repair migration.');
const sql=fs.readFileSync(path,'utf8');
const need=(token,msg)=>{ if(!sql.includes(token)) throw new Error(msg); };

need("current_setting('linecrew.owner_change_authorized', true)", 'Owner trigger must require an explicit transaction-local transfer exemption.');
need("set_config('linecrew.owner_change_authorized','on',true)", 'Sanctioned ownership RPCs must enable the local exemption.');
need("set_config('linecrew.owner_change_authorized','off',true)", 'Ownership RPCs must clear the local exemption before returning.');
need("lower(coalesce(actor.role,'')) <> 'admin'", 'Admin recovery must remain Admin-only; Manager cannot alter ownership.');
need("actor.id = replacement_admin_id", 'Admin self-nomination guard is missing.');
need("current_owner.active is true", 'Admin recovery must reject an active Owner.');
need("An active Owner must transfer ownership themselves.", 'Active-Owner recovery rejection is missing.');
need("lower(coalesce(role,''))='owner' and active is not true", 'Recovery demotion must target only the inactive Owner.');
need("<> 1 then", 'Ownership RPC must verify exactly one Owner remains.');
need("company_ownership_transferred", 'Owner-initiated transfer audit record is missing.');
need("company_ownership_recovered_by_admin", 'Admin recovery audit record is missing.');
need("revoke all on function public.linecrew_admin_replace_company_owner", 'Ownership recovery RPC grant hardening is missing.');

console.log('Ownership transfer security guard passed.');
