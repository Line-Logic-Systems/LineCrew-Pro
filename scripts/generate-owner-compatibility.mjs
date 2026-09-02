import fs from 'node:fs';
import path from 'node:path';

const dir = 'supabase/migrations/archive';
const excludedFunctions = new Set([
  // This function's TABLE return shape evolved after the legacy compatibility
  // layer was introduced. Replacing it here can abort with PostgreSQL 42P13.
  // Forward migrations own its current definition and role checks.
  'public.get_daily_report_unit_locations',
  'public.set_company_member_role',
  'public.set_company_member_active'
]);

function addOwnerToRoleLists(sql){
  sql = sql.replace(/\b(in|not in)\s*\(([^)]*'admin'[^)]*)\)/gi, (full, operator, list) => {
    if(/'owner'/i.test(list)) return full;
    return `${operator} (${list.trim()}, 'owner')`;
  });
  sql = sql.replace(/\bv_role\s*<>\s*'admin'/gi, "v_role not in ('admin','owner')");
  sql = sql.replace(/\bv_caller_role\s*<>\s*'admin'/gi, "v_caller_role not in ('admin','owner')");
  sql = sql.replace(/lower\(coalesce\(v_role,\s*''\)\)\s*<>\s*'admin'/gi, "lower(coalesce(v_role, '')) not in ('admin','owner')");
  sql = sql.replace(/\bv_role\s*=\s*'admin'/gi, "v_role in ('admin','owner')");
  return sql;
}

const blocks = [];
for(const name of fs.readdirSync(dir).sort()){
  if(!name.endsWith('.sql') || name.startsWith('20260818_owner_') || name.startsWith('20260819_')) continue;
  const text = fs.readFileSync(path.join(dir,name),'utf8');
  const re = /create\s+or\s+replace\s+function\s+([^\s(]+)[\s\S]*?\n\$\$;/gi;
  for(const match of text.matchAll(re)){
    const fn = String(match[1] || '').toLowerCase();
    if(excludedFunctions.has(fn) || fn.startsWith('public.linecrew_')) continue;
    if(!/admin/i.test(match[0])) continue;
    const transformed = addOwnerToRoleLists(match[0]);
    if(transformed !== match[0]){
      blocks.push({source:name, fn, sql:transformed});
    }
  }
}

const unique = new Map();
for(const block of blocks) unique.set(block.fn, block);
let out = '-- Generated Owner compatibility layer for legacy LineCrew Pro RPCs.\n';
out += '-- Keeps existing behavior while treating Owner as an Admin-equivalent where legacy functions authorize by role.\n';
out += '-- New role-management functions are intentionally excluded.\n\nbegin;\n\n';
for(const block of unique.values()){
  out += `-- Source: ${block.source}\n${block.sql}\n\n`;
}
out += 'commit;\n';
fs.writeFileSync('supabase/migrations/archive/202608190100_owner_legacy_compatibility.sql', out);
console.log(`Generated Owner compatibility for ${unique.size} functions.`);
for(const block of unique.values()) console.log('-', block.fn, '<-', block.source);
