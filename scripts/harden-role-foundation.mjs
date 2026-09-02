import fs from 'node:fs';
const path = 'supabase/migrations/archive/20260818_owner_superintendent_roles.sql';
let sql = fs.readFileSync(path,'utf8');
const changes=[];
function r(before,after,label){
  if(!sql.includes(before)) throw new Error('Missing target: '+label);
  sql=sql.replace(before,after); changes.push(label);
}
r(`    from public.profiles p\n    where p.id = auth.uid()\n  ), false);`,`    from public.profiles p\n    where p.id = auth.uid()\n      and p.active is true\n  ), false);`,'capability active gate');
r(`  if actor.id is null or lower(actor.role) <> 'admin' then\n    raise exception 'Current Admin access required';`,`  if actor.id is null or actor.active is not true or lower(actor.role) <> 'admin' then\n    raise exception 'Current active Admin access required';`,'initial owner active gate');
r(`  if actor.id is null or lower(actor.role) not in ('owner','admin','superintendent') then\n    raise exception 'Company management access required';`,`  if actor.id is null or actor.active is not true or lower(actor.role) not in ('owner','admin','superintendent') then\n    raise exception 'Active company management access required';`,'role management active gate');
r(`  if actor.id is null or lower(actor.role) not in ('owner','admin') then\n    raise exception 'Admin or Owner access required';`,`  if actor.id is null or actor.active is not true or lower(actor.role) not in ('owner','admin') then\n    raise exception 'Active Admin or Owner access required';`,'permission setter active gate');
fs.writeFileSync(path,sql);
console.log('Hardened:',changes.join(', '));
