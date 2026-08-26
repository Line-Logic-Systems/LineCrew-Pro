/* LineCrew Pro - offline-first JSA queue and sync */
(() => {
  'use strict';
  const QUEUE_KEY='linecrew-offline-jsa-queue-v1';
  const CACHE_KEY='linecrew-offline-jsa-context-v1';
  const byId=id=>document.getElementById(id);
  const getSb=()=>{try{return typeof sb!=='undefined'?sb:(window.sb||null);}catch(_){return window.sb||null;}};
  const profile=()=>{try{return typeof currentProfile!=='undefined'?currentProfile:window.currentProfile;}catch(_){return window.currentProfile;}};
  const toast=(m,t='info')=>window.LineCrewUI?.toast?.(m,t)||window.showToast?.(m)||console.log(m);
  const read=(key,fallback)=>{try{return JSON.parse(localStorage.getItem(key)||'null')??fallback;}catch(_){return fallback;}};
  const write=(key,value)=>localStorage.setItem(key,JSON.stringify(value));
  const val=id=>(byId(id)?.value||'').trim();
  const checked=name=>[...document.querySelectorAll(`[name="${name}"]:checked`)].map(el=>el.value);

  function statusBox(){
    let box=byId('offlineJsaStatus');
    if(box)return box;
    const form=byId('safetyJsaForm');if(!form)return null;
    box=document.createElement('div');box.id='offlineJsaStatus';
    box.style.cssText='display:none;margin:0 0 12px;padding:10px 12px;border-radius:10px;font-weight:800;font-size:13px';
    form.insertBefore(box,form.firstChild);return box;
  }
  function setStatus(text,type='pending'){
    const box=statusBox();if(!box)return;
    box.style.display='block';box.textContent=text;
    box.style.background=type==='synced'?'#eaf7ef':'#fff4da';
    box.style.border='1px solid '+(type==='synced'?'#79bd91':'#e3b64c');
    box.style.color=type==='synced'?'#155d2d':'#6a4300';
  }
  function queue(){return read(QUEUE_KEY,[])}
  function saveQueue(rows){write(QUEUE_KEY,rows);renderQueueCount()}
  function renderQueueCount(){
    const count=queue().filter(x=>x.status!=='synced').length;
    let pill=byId('offlineJsaQueuePill');
    const card=byId('safetyPage')?.querySelector('.section-header,.card');
    if(!pill&&card){pill=document.createElement('span');pill.id='offlineJsaQueuePill';pill.style.cssText='display:none;margin-left:8px;padding:4px 8px;border-radius:999px;background:#fff4da;border:1px solid #e3b64c;color:#6a4300;font-size:12px;font-weight:800';card.appendChild(pill)}
    if(pill){pill.style.display=count?'inline-block':'none';pill.textContent=`${count} JSA${count===1?'':'s'} waiting to sync`;}
  }

  function collectTasks(){return [...document.querySelectorAll('#jsaTaskRows .lc-jsa-task')].map(row=>({job_task:row.querySelector('.jsa-task-name')?.value.trim()||'',hazards:row.querySelector('.jsa-task-hazards')?.value.trim()||'',mitigation:row.querySelector('.jsa-task-mitigation')?.value.trim()||''})).filter(x=>x.job_task||x.hazards||x.mitigation)}
  function collectCrew(){const names=[...document.querySelectorAll('.jsa-printed-name-input')],sigs=[...document.querySelectorAll('.jsa-signature-input')];return names.map((n,i)=>({printed_name:n.value.trim(),signature:sigs[i]?.value.trim()||''})).filter(x=>x.printed_name||x.signature)}
  function buildDetails(attemptedAt){
    const base=window.LineCrewExpandedJsa?.detailsPayload?.()||{};
    return {...base,offline_submission:{attempted_at:attemptedAt,synced_at:null,device_recorded:true}};
  }
  function buildPayload(attemptedAt){
    const tasks=collectTasks(),crew=collectCrew();
    const emergency=[val('jsaLocalEmergency')&&`Local Emergency: ${val('jsaLocalEmergency')}`,val('jsaMedicalFacilityName')&&`Medical Facility: ${val('jsaMedicalFacilityName')}`,val('jsaMedicalFacilityAddress')&&`Address: ${val('jsaMedicalFacilityAddress')}`,val('jsaEmergencyMeetingPoint')&&`Meeting Point: ${val('jsaEmergencyMeetingPoint')}`].filter(Boolean).join(' | ')||'See expanded JSA details.';
    return {
      p_job_id:val('safetyJsaJob'),p_work_date:val('safetyJsaDate'),p_crew_name:val('safetyJsaCrew'),
      p_job_briefing:tasks.map((x,i)=>`${i+1}. ${x.job_task}`).join('\n')||'See expanded JSA details.',
      p_hazards:tasks.map((x,i)=>`${i+1}. ${x.hazards}`).join('\n')||'See expanded JSA details.',
      p_controls:tasks.map((x,i)=>`${i+1}. ${x.mitigation}`).join('\n')||'See expanded JSA details.',
      p_ppe:checked('jsaPpeItem').join(', ')||'See expanded JSA details.',p_emergency_plan:emergency,
      p_crew_members:crew.map(x=>`${x.printed_name}${x.signature?` | Signature: ${x.signature}`:''}`).join('\n'),
      p_weather_conditions:val('safetyJsaWeather')||null,p_special_equipment:val('safetyJsaEquipment')||null,
      p_foreman_acknowledged:true,p_details:buildDetails(attemptedAt)
    };
  }
  function validate(){
    const tasks=collectTasks(),crew=collectCrew();
    if(!val('safetyJsaJob')||!val('safetyJsaDate')||!val('safetyJsaTime')||!val('safetyJsaCrew')||!val('safetyJsaLeader'))return 'Complete Job, Date, Time, Crew, and JSA Leader.';
    if(!tasks.some(x=>x.job_task&&x.hazards&&x.mitigation))return 'Complete at least one Job Task / Hazards / Mitigation row.';
    if(!crew.some(x=>x.printed_name&&x.signature))return 'Enter at least one crew member printed name and signature.';
    if(!val('jsaPersonInChargeName')||!val('jsaPersonInChargeSignature'))return 'Complete the JSA Leader / Person in Charge name and signature.';
    if(!byId('safetyJsaAcknowledged')?.checked)return 'Check the final JSA certification before saving.';
    return '';
  }
  function localId(){return 'jsa-'+Date.now()+'-'+Math.random().toString(36).slice(2,8)}
  function queueCurrentJsa(){
    const error=validate(),msg=byId('safetyJsaMsg');if(error){if(msg)msg.textContent=error;return false;}
    const attemptedAt=new Date().toISOString(),p=profile();
    const item={id:localId(),company_id:p?.company_id||null,user_id:p?.id||null,foreman_name:p?.full_name||val('safetyJsaForeman'),attempted_at:attemptedAt,status:'pending',payload:buildPayload(attemptedAt)};
    const rows=queue();rows.push(item);saveQueue(rows);
    setStatus(`Submitted offline at ${new Date(attemptedAt).toLocaleString()} — waiting to sync.`,'pending');
    if(msg){msg.textContent='JSA saved on this device. It will send automatically when service returns.';msg.className='message success';}
    toast('JSA saved offline and queued for automatic sync.','success');
    byId('saveSafetyJsaBtn')?.setAttribute('disabled','disabled');
    setTimeout(()=>{byId('safetyJsaForm')?.classList.add('hidden');byId('createJsaBtn')?.classList.remove('hidden');},650);
    return true;
  }

  async function syncQueue(){
    if(!navigator.onLine)return;
    const client=getSb(),p=profile();if(!client||!p?.company_id)return;
    let rows=queue(),changed=false;
    for(const item of rows){
      if(item.status==='synced')continue;
      if(item.company_id&&item.company_id!==p.company_id)continue;
      try{
        const payload=structuredClone?structuredClone(item.payload):JSON.parse(JSON.stringify(item.payload));
        payload.p_details=payload.p_details||{};
        payload.p_details.offline_submission={...(payload.p_details.offline_submission||{}),attempted_at:item.attempted_at,synced_at:new Date().toISOString(),device_recorded:true};
        const {data,error}=await client.rpc('create_standalone_jsa_v2',payload);if(error)throw error;
        item.status='synced';item.synced_at=new Date().toISOString();item.server_id=data||null;changed=true;
        setStatus(`Offline JSA synced successfully. Field submission time: ${new Date(item.attempted_at).toLocaleString()}.`,'synced');
        toast('Offline JSA synced to LineCrew Pro.','success');
      }catch(error){item.last_error=error?.message||String(error);item.last_attempt_at=new Date().toISOString();changed=true;break;}
    }
    if(changed){rows=rows.filter(x=>x.status!=='synced'||(Date.now()-new Date(x.synced_at).getTime())<86400000);saveQueue(rows)}
    if(typeof window.loadSafetyJsas==='function')try{await window.loadSafetyJsas()}catch(_){}
  }

  function cacheContext(){
    const p=profile();if(!p?.company_id)return;
    const job=byId('safetyJsaJob');
    const context={company_id:p.company_id,foreman_id:p.id,foreman_name:p.full_name||'',jobs:job?[...job.options].filter(o=>o.value).map(o=>({id:o.value,label:o.textContent})):[],cached_at:new Date().toISOString()};
    if(context.jobs.length)write(CACHE_KEY,context);
  }
  function restoreCachedJobs(){
    const p=profile(),job=byId('safetyJsaJob'),ctx=read(CACHE_KEY,null);if(!job||!ctx||ctx.company_id!==p?.company_id)return;
    if([...job.options].some(o=>o.value))return;
    ctx.jobs.forEach(j=>{const o=document.createElement('option');o.value=j.id;o.textContent=j.label;job.appendChild(o)});
  }

  function bind(){
    const btn=byId('saveSafetyJsaBtn');if(!btn||btn.dataset.offlineJsaBound==='1')return;
    btn.dataset.offlineJsaBound='1';
    btn.addEventListener('click',e=>{
      cacheContext();
      if(navigator.onLine)return;
      e.preventDefault();e.stopImmediatePropagation();queueCurrentJsa();
    },true);
    byId('createJsaBtn')?.addEventListener('click',()=>setTimeout(()=>{restoreCachedJobs();cacheContext();const save=byId('saveSafetyJsaBtn');if(save)save.disabled=false;},80));
  }
  function init(){statusBox();bind();renderQueueCount();restoreCachedJobs();cacheContext();window.addEventListener('online',()=>setTimeout(syncQueue,250));document.addEventListener('visibilitychange',()=>{if(!document.hidden)syncQueue()});setInterval(()=>{bind();cacheContext();if(navigator.onLine)syncQueue()},30000);setTimeout(syncQueue,1200)}
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',init);else init();
  window.LineCrewOfflineJsa={sync:syncQueue,queueCount:()=>queue().filter(x=>x.status!=='synced').length};
})();
