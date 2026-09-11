import fs from 'node:fs';

const path='gf-review-theme-enhancements.js';
if(!fs.existsSync(path)) throw new Error(`Missing ${path}`);
const source=fs.readFileSync(path,'utf8');
const need=(token,message)=>{ if(!source.includes(token)) throw new Error(message); };

for(const [token,message] of [
  ["linecrew-pro-theme:", 'Per-user theme storage key is missing.'],
  ["lc-industrial-dark", 'Industrial dark mode class wiring is missing.'],
  ["lcThemeToggle", 'Dark/light mode toggle is missing.'],
  ["Production Needs Review", 'GF Production review alert copy is missing.'],
  [".eq('status', 'submitted')", 'GF review badge must stay scoped to submitted Daily Reports.'],
  ["linecrewGfCrewScope", 'GF review badge must continue honoring GF crew scope.'],
  ["timekeeping_report_rows_v2", 'GF crew-time review lookup is missing.'],
  ["daily_report_id===reportId", 'GF crew-time rows must stay scoped to the selected Daily Report.'],
  ["role() !== 'gf'", 'GF-only review behavior guard is missing.'],
  ["Crew Time", 'GF crew-time review panel is missing.']
]) need(token,message);

console.log('GF review/theme regression guard passed.');
