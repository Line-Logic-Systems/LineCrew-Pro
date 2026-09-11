import fs from 'node:fs';

const path='foreman-field-tools.js';
if(!fs.existsSync(path)) throw new Error(`Missing ${path}`);
const source=fs.readFileSync(path,'utf8');
const need=(token,message)=>{ if(!source.includes(token)) throw new Error(message); };

for(const [token,message] of [
  ["role() !== 'foreman'",'Remaining Units must stay Foreman-only.'],
  ["window.openLineCrewRemainingUnits = open",'Remaining Units open bridge is missing.'],
  ["rpc('get_remaining_job_units_for_field'",'Remaining Units RPC wiring is missing.'],
  ["Saved drafts and submitted reports reserve those quantities",'Remaining Units reservation guidance is missing.'],
  ["Redlines are kept separate",'Remaining Units redline separation guidance is missing.'],
  ["Work Points Left",'Remaining Units work-point summary is missing.'],
  ["Unit Lines Left",'Remaining Units unit-line summary is missing.'],
  ["Total Quantity Left",'Remaining Units quantity summary is missing.'],
  ["Crew Time",'Foreman Crew Time label is missing.'],
  ["Review your crew hours and per diem",'Foreman Crew Time description is missing.'],
  ["setAppHistory({ lineCrewPage:'remainingUnitsPage' })",'Remaining Units browser history integration is missing.']
]) need(token,message);

console.log('Foreman field tools regression guard passed.');
