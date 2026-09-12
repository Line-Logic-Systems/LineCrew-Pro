import fs from 'node:fs';
import assert from 'node:assert/strict';

const source = fs.readFileSync('offline-jsa.js','utf8');

function extractFunction(signature){
  const start = source.indexOf(signature);
  if(start < 0) throw new Error(`Missing Offline JSA function: ${signature}`);
  const brace = source.indexOf('{', start);
  if(brace < 0) throw new Error(`Missing function body: ${signature}`);
  let depth = 0;
  let quote = null;
  let escaped = false;
  let templateExprDepth = 0;
  for(let i = brace; i < source.length; i += 1){
    const ch = source[i];
    const next = source[i + 1];
    if(quote){
      if(escaped){ escaped = false; continue; }
      if(ch === '\\'){ escaped = true; continue; }
      if(quote === '`' && ch === '$' && next === '{'){
        templateExprDepth += 1;
        i += 1;
        continue;
      }
      if(quote === '`' && ch === '}' && templateExprDepth > 0){
        templateExprDepth -= 1;
        continue;
      }
      if(ch === quote && templateExprDepth === 0) quote = null;
      continue;
    }
    if(ch === '"' || ch === "'" || ch === '`'){ quote = ch; continue; }
    if(ch === '/' && next === '/'){
      const lineEnd = source.indexOf('\n', i + 2);
      i = lineEnd < 0 ? source.length : lineEnd;
      continue;
    }
    if(ch === '/' && next === '*'){
      const end = source.indexOf('*/', i + 2);
      if(end < 0) throw new Error('Unclosed block comment while extracting Offline JSA function.');
      i = end + 1;
      continue;
    }
    if(ch === '{') depth += 1;
    if(ch === '}'){
      depth -= 1;
      if(depth === 0) return source.slice(start, i + 1);
    }
  }
  throw new Error(`Unable to extract complete function: ${signature}`);
}

const backoffSource = extractFunction('function backoff(attemptCount)');
const failureSource = extractFunction('function nextSyncFailureState(item, error, nowMs = Date.now())');
const performSource = extractFunction('async function performSync(force = false)');

assert.match(source, /const MAX_SYNC_ATTEMPTS = 5;/, 'Offline JSA poison threshold must remain explicit.');
assert.match(performSource, /if \(item\.status === 'blocked'\) continue;/, 'Blocked JSAs must be skipped during automatic sync.');
assert.match(performSource, /continue;/, 'A failed JSA must continue to the next queue item.');
assert.doesNotMatch(performSource, /catch \(error\)[\s\S]*?break;/, 'A failed JSA must never break the whole outbox.');
assert.match(source, /Offline JSA Sync Needs Attention/, 'Blocked JSA recovery panel is missing.');
assert.match(source, /Export Recovery Copy/, 'Blocked JSA recovery export is missing.');
assert.match(source, /saved by another LineCrew Pro user/, 'Shared-device unsynced JSA warning is missing.');

const removed = [];
const persisted = [];
const rows = [
  {id:'a', type:'digital', status:'pending', company_id:'c1', user_id:'u1', created_at:'2026-09-11T10:00:00Z', attempted_at:'2026-09-11T10:00:00Z', attempt_count:0},
  {id:'b', type:'digital', status:'pending', company_id:'c1', user_id:'u1', created_at:'2026-09-11T10:01:00Z', attempted_at:'2026-09-11T10:01:00Z', attempt_count:0},
  {id:'c', type:'digital', status:'pending', company_id:'c1', user_id:'u1', created_at:'2026-09-11T10:02:00Z', attempted_at:'2026-09-11T10:02:00Z', attempt_count:0}
];

const deps = {
  navigator:{onLine:true},
  getClient:()=>({}),
  getProfile:()=>({id:'u1', company_id:'c1'}),
  all:async()=>rows.map(row => ({...row})),
  currentIdentityMatches:()=>true,
  syncUpload:async()=>({serverId:null}),
  syncDigital:async(_client,item)=>{
    if(item.id === 'b') throw new Error('poisoned test record');
    return `server-${item.id}`;
  },
  remove:async(id)=>{ removed.push(id); },
  put:async(item)=>{ persisted.push({...item}); },
  renderQueueCount:async()=>{},
  setStatus:()=>{},
  toast:()=>{},
  refreshSafetyViews:async()=>{}
};

const factory = new Function('deps', `
  const {navigator,getClient,getProfile,all,currentIdentityMatches,syncUpload,syncDigital,remove,put,renderQueueCount,setStatus,toast,refreshSafetyViews} = deps;
  const MAX_BACKOFF_MS = 5 * 60 * 1000;
  const MAX_SYNC_ATTEMPTS = 5;
  ${backoffSource}
  ${failureSource}
  ${performSource}
  return {performSync,nextSyncFailureState};
`);

const {performSync,nextSyncFailureState} = factory(deps);
await performSync(true);
assert.deepEqual(removed, ['a','c'], 'The queue must sync items after a poisoned middle record.');
assert.equal(persisted.length, 1, 'The failed record must remain persisted exactly once.');
assert.equal(persisted[0].id, 'b');
assert.equal(persisted[0].status, 'pending');
assert.equal(persisted[0].attempt_count, 1);
assert.match(persisted[0].last_error, /poisoned test record/);

const blocked = nextSyncFailureState({id:'x',status:'pending',attempt_count:4}, new Error('still bad'), Date.parse('2026-09-11T12:00:00Z'));
assert.equal(blocked.status, 'blocked', 'The fifth failed attempt must dead-letter the JSA locally.');
assert.equal(blocked.attempt_count, 5);
assert.equal(blocked.next_attempt_at, null, 'Blocked JSAs must stop automatic retry loops.');
assert.equal(blocked.last_error, 'still bad');

console.log('Offline JSA poison-queue behavior passed.');
