import fs from 'node:fs';

const read = path => fs.readFileSync(path, 'utf8');
const app = read('index.html');
const workspace = read('role-workspace-polish.js');
const migration = read('supabase/migrations/20260910190000_manager_and_safety_roles.sql');

const requireText = (source, text, message) => {
  if (!source.includes(text)) throw new Error(message);
};

requireText(app, "['owner','manager','admin'].includes(currentUserRole())", 'Manager is missing from full-access frontend authorization.');
requireText(app, "if(userIsSafety()) return ['dashboardPage','safetyPage'].includes(page);", 'Safety page allowlist is missing.');
requireText(app, "const readOnly = userIsSafety();", 'Safety JSA mutation controls are not disabled.');
requireText(app, "if(target === 'owner') return [];", 'Manager Owner-protection UI is missing.');
requireText(workspace, "safety:{title:'Safety Workspace'", 'Safety workspace is missing.');
requireText(workspace, "manager:{title:'Manager Workspace'", 'Manager workspace is missing.');
requireText(migration, "Managers cannot change, suspend, replace or assign the company Owner.", 'Database Owner protection is missing.');
requireText(migration, "lower(coalesce((select public.my_role()),'')) = 'safety'", 'Safety JSA read policy is missing.');
requireText(migration, "('foreman','gf','superintendent','admin','manager','owner','safety')", 'Seven-role database constraint is missing.');
if (/safety_read_company_jsas[\s\S]{0,300}for (insert|update|delete)/i.test(migration)) {
  throw new Error('Safety must not receive JSA mutation policies.');
}

console.log('PASS: Manager has broad operational UI access with database Owner protection; Safety is restricted to read-only JSA review/export.');
