import fs from 'node:fs';
import path from 'node:path';

const dir='supabase/migrations';
const excluded=new Set([
  'public.set_company_member_role',
  'public.set_company_member_active'
]);

function capabilityFor(source,fn){
  const f=fn.toLowerCase();
  if(/storm/.test(f)) return 'storm_mode';
  if(/jsa|safety/.test(f)) return 'safety_records';
  if(/price_book/.test(f)) return 'price_books';
  if(/field_value/.test(f)) return 'actual_pricing';
  if(/job_package|work_point|authorized_unit/.test(f)) return 'job_packages';
  if(/job_progress|reporting|export/.test(f)) return 'reporting';
  if(/job_leader|contract_job|set_job|create_job|delete_job/.test(f)) return 'jobs';
  if(/company_settings/.test(f)) return 'company_settings';
  if(/join_code/.test(f)) return 'team_management';
  if(/daily_report|daily_unit|attachment/.test(f)) return 'production_review';
  if(source.includes('job_package')) return 'job_packages';
  if(source.includes('storm')) return 'storm_mode';
  if(source.includes('jsa')) return 'safety_records';
  if(source.includes('daily')) return 'production_review';
  if(source.includes('price_book')) return 'price_books';
  if(source.includes('job_')) return 'jobs';
  return null;
}

function transformRoles(sql){
  sql=sql.replace(/\b(in|not in)\s*\(([^)]*'admin'[^)]*)\)/gi,(full,op,list)=>{
    let next=list.trim();
    if(!/'owner'/i.test(next)) next += ", 'owner'";
    if(!/'superintendent'/i.test(next)) next += ", 'superintendent'";
    return `${op} (${next})`;
  });
  sql=sql.replace(/lower\(coalesce\(v_role,\s*''\)\)\s*<>\s*'admin'/gi,"lower(coalesce(v_role, '')) not in ('admin','owner','superintendent')");
  sql=sql.replace(/\bv_role\s*<>\s*'admin'/gi,"v_role not in ('admin','owner','superintendent')");
  sql=sql.replace(/\bv_caller_role\s*<>\s*'admin'/gi,"v_caller_role not in ('admin','owner','superintendent')");
  sql=sql.replace(/\bv_role\s*=\s*'admin'/gi,"v_role in ('admin','owner','superintendent')");
  sql=sql.replace(/\bv_caller_role\s*=\s*'admin'/gi,"v_caller_role in ('admin','owner','superintendent')");
  return sql;
}

function injectCapability(sql,cap){
  const marker=/\bbegin\s*\n/i;
  if(!marker.test(sql)) throw new Error('No BEGIN found');
  const gate=`begin\n  if exists (\n    select 1 from public.profiles p\n    where p.id = auth.uid()\n      and lower(coalesce(p.role,'')) = 'superintendent'\n  ) and not public.linecrew_has_capability('${cap}') then\n    raise exception using\n      errcode = '42501',\n      message = 'This Superintendent does not have ${cap.replaceAll('_',' ')} permission.';\n  end if;\n`;
  return sql.replace(marker,gate);
}

const latest=new Map();
for(const name of fs.readdirSync(dir).sort()){
  if(!name.endsWith('.sql')) continue;
  if(name.startsWith('20260818_owner_') || name.startsWith('20260819')) continue;
  const text=fs.readFileSync(path.join(dir,name),'utf8');
  const re=/create\s+or\s+replace\s+function\s+([^\s(]+)[\s\S]*?\n\$\$;/gi;
  for(const match of text.matchAll(re)){
    const fn=String(match[1]||'').toLowerCase();
    if(excluded.has(fn) || fn.startsWith('public.linecrew_')) continue;
    if(!/admin/i.test(match[0])) continue;
    const cap=capabilityFor(name,fn);
    if(!cap) continue;
    latest.set(fn,{source:name,fn,cap,sql:match[0]});
  }
}

let out='-- Generated capability-aware Superintendent compatibility layer.\n';
out+='-- Applies after Owner/Superintendent foundation migrations.\n';
out+='-- Existing Admin/Owner/GF/Foreman behavior is preserved; Superintendent access is gated by the named capability.\n\nbegin;\n\n';
for(const block of latest.values()){
  let sql=transformRoles(block.sql);
  sql=injectCapability(sql,block.cap);
  out+=`-- Source: ${block.source}\n-- Superintendent capability: ${block.cap}\n${sql}\n\n`;
}
out+='commit;\n';
fs.writeFileSync('supabase/migrations/202608190200_superintendent_legacy_compatibility.sql',out);
console.log(`Generated Superintendent compatibility for ${latest.size} functions.`);
for(const b of latest.values()) console.log('-',b.fn,b.cap,'<-',b.source);
