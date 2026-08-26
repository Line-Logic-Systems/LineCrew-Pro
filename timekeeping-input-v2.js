/* LineCrew Pro - launch timekeeping detail capture */
(() => {
  'use strict';
  const byId=id=>document.getElementById(id);
  const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const num=v=>Number(v||0)||0;
  const getSb=()=>{try{return typeof sb!=='undefined'?sb:(window.sb||window.supabaseClient||null);}catch(_){return window.sb||window.supabaseClient||null;}};
  const profile=()=>typeof currentProfile!=='undefined'?currentProfile:window.currentProfile;
  const companyId=()=>profile()?.company_id||null;
  const role=()=>String(profile()?.role||'').toLowerCase();
  const canManageEquipment=()=>['owner','admin'].includes(role());
  let employeeEquipment=new Map(), equipment=[], wrappedSave=null, loadedReport='';

  function toast(message,type='info'){if(window.LineCrewUI?.toast)window.LineCrewUI.toast(message,type);else if(type==='error')console.error(message);}
  function addStyles(){
    if(byId('tkLaunchDetailStyles'))return;
    const style=document.createElement('style');style.id='tkLaunchDetailStyles';
    style.textContent=`
      .tk-crew-row>label:has(.tk-regular),.tk-crew-row>label:has(.tk-ot){display:none!important}
      #dailyCrewTimeRows .tk-crew-row{border-bottom:3px solid #8b9dad;padding-bottom:16px;margin-bottom:16px}
      #dailyCrewTimeRows .tk-crew-row:last-child{border-bottom:0;margin-bottom:0}
      .tk-detail-row{grid-column:1/-1;display:grid;grid-template-columns:110px 110px 100px minmax(150px,1fr) auto auto;gap:10px;padding:8px 0 2px;border-top:1px solid #c2cdd7;align-items:end}
      .tk-detail-row label{font-size:11px;margin:0}.tk-detail-row input,.tk-detail-row select{margin:0;padding:8px}
      .tk-detail-check{display:flex;gap:6px;align-items:center;padding-bottom:10px}.tk-detail-check input{width:auto;min-width:0}
      .tk-hours-worked{font-size:12px;color:#5f7080;grid-column:1/-1}
      .tk-equipment-card{margin-top:14px;border-top:1px solid #dce5ed;padding-top:12px}.tk-equipment-grid{display:grid;gap:7px}.tk-equipment-line{display:grid;grid-template-columns:minmax(170px,1fr) minmax(180px,1fr) auto;gap:8px;align-items:center}.tk-equipment-line select,.tk-equipment-line button{margin:0}
      .tk-equipment-upload{display:flex;gap:8px;flex-wrap:wrap;align-items:end;margin:10px 0}.tk-equipment-upload label{margin:0;min-width:190px}.tk-equipment-upload button{width:auto;margin:0}.tk-equipment-roster{font-size:12px;color:#5f7080;margin:6px 0 12px}
      @media(max-width:760px){.tk-detail-row{grid-template-columns:1fr 1fr}.tk-detail-row>label:nth-child(4){grid-column:1/-1}.tk-equipment-line{grid-template-columns:1fr}.tk-equipment-line button{width:100%}}
    `;document.head.appendChild(style);
  }

  function clockMinutes(v){if(!v||!/^[0-2]\d:[0-5]\d/.test(v))return null;const [h,m]=v.slice(0,5).split(':').map(Number);return h*60+m;}
  function workedHours(row){const s=clockMinutes(row.querySelector('.tk-start')?.value),e=clockMinutes(row.querySelector('.tk-stop')?.value);if(s===null||e===null)return null;let mins=e-s;if(mins<0)mins+=1440;mins-=Math.max(0,num(row.querySelector('.tk-lunch')?.value));return Math.max(0,mins/60);}
  function syncPayrollFromClock(row){
    const total=workedHours(row), out=row.querySelector('.tk-hours-worked');
    if(total===null){if(out)out.textContent='Worked: —';return;}
    const reg=Math.min(8,total),ot=Math.max(0,total-8);
    const regInput=row.querySelector('.tk-regular'),otInput=row.querySelector('.tk-ot');
    if(regInput)regInput.value=reg.toFixed(2);if(otInput)otInput.value=ot.toFixed(2);
    regInput?.dispatchEvent(new Event('change',{bubbles:true}));otInput?.dispatchEvent(new Event('change',{bubbles:true}));
    if(out)out.textContent=`Worked: ${total.toFixed(2)} h`;
  }

  async function refreshData(){
    const client=getSb();if(!client||!companyId())return;
    const [empRes,equipRes]=await Promise.all([
      client.from('timekeeping_employees').select('id,full_name,employee_number,active,default_equipment').eq('company_id',companyId()).order('full_name'),
      client.from('timekeeping_equipment').select('id,unit_number,description,active').eq('company_id',companyId()).order('unit_number')
    ]);
    if(!empRes.error)employeeEquipment=new Map((empRes.data||[]).map(e=>[e.id,e]));
    if(!equipRes.error)equipment=equipRes.data||[];
    renderEquipmentManager();document.querySelectorAll('#dailyCrewTimeRows .tk-crew-row').forEach(row=>{renderEquipmentSelect(row);applyDefaultEquipment(row,false);});
  }
  function equipmentOptions(selected=''){return '<option value="">Select truck / equipment</option>'+equipment.filter(e=>e.active!==false).map(e=>`<option value="${esc(e.unit_number)}" ${e.unit_number===selected?'selected':''}>${esc(e.unit_number)}${e.description?' — '+esc(e.description):''}</option>`).join('');}
  function installEquipmentManager(){
    const roster=byId('timekeepingRosterCard');if(!roster||byId('tkDefaultEquipmentCard')||!canManageEquipment())return;
    const box=document.createElement('div');box.id='tkDefaultEquipmentCard';box.className='tk-equipment-card';
    box.innerHTML=`<h4>Truck / Equipment Roster</h4><p class="tk-help">Upload the company equipment roster, then assign each employee's normal unit. Foremen select from this roster on Daily Reports.</p><div class="tk-equipment-upload"><label>Roster CSV<input id="tkEquipmentCsv" type="file" accept=".csv,text/csv"></label><button id="tkUploadEquipment" type="button" class="secondary small">Upload roster</button></div><div class="tk-equipment-roster" id="tkEquipmentRosterSummary"></div><div id="tkDefaultEquipmentList" class="tk-equipment-grid"></div>`;
    roster.appendChild(box);byId('tkUploadEquipment').onclick=uploadEquipmentRoster;renderEquipmentManager();
  }
  async function uploadEquipmentRoster(){
    const file=byId('tkEquipmentCsv')?.files?.[0];if(!file)return toast('Choose a CSV equipment roster first.','error');
    const text=await file.text(),lines=text.split(/\r?\n/).map(x=>x.trim()).filter(Boolean);if(!lines.length)return toast('That roster is empty.','error');
    const first=lines[0].split(',').map(x=>x.trim().replace(/^"|"$/g,'')),hasHeader=/unit|truck|equipment|number/i.test(first.join(' '));
    const rows=(hasHeader?lines.slice(1):lines).map(line=>{const c=line.split(',').map(x=>x.trim().replace(/^"|"$/g,''));return{company_id:companyId(),unit_number:c[0]||'',description:c[1]||null,active:true};}).filter(r=>r.unit_number);
    if(!rows.length)return toast('No unit numbers were found in the first CSV column.','error');
    const {error}=await getSb().from('timekeeping_equipment').upsert(rows,{onConflict:'company_id,unit_number'});if(error)return toast('Could not upload equipment roster: '+error.message,'error');
    toast(`${rows.length} equipment roster rows loaded.`,'success');await refreshData();
  }
  function renderEquipmentManager(){
    const summary=byId('tkEquipmentRosterSummary');if(summary)summary.textContent=`${equipment.filter(e=>e.active!==false).length} active units available.`;
    const box=byId('tkDefaultEquipmentList');if(!box)return;const rows=[...employeeEquipment.values()].filter(e=>e.active!==false);
    if(!rows.length){box.innerHTML='<span class="muted">Add employees above before assigning equipment.</span>';return;}
    box.innerHTML=rows.map(e=>`<div class="tk-equipment-line"><strong>${esc(e.full_name||e.employee_number||'Employee')}</strong><select data-tk-default-equipment="${esc(e.id)}">${equipmentOptions(e.default_equipment||'')}</select><button type="button" class="secondary small" data-tk-save-equipment="${esc(e.id)}">Save assignment</button></div>`).join('');
    box.querySelectorAll('[data-tk-save-equipment]').forEach(b=>b.onclick=()=>saveDefaultEquipment(b.dataset.tkSaveEquipment));
  }
  async function saveDefaultEquipment(id){const input=document.querySelector(`[data-tk-default-equipment="${CSS.escape(id)}"]`);if(!input)return;const value=input.value||null;const {error}=await getSb().from('timekeeping_employees').update({default_equipment:value,updated_at:new Date().toISOString()}).eq('id',id).eq('company_id',companyId());if(error)return toast('Could not save equipment assignment: '+error.message,'error');const e=employeeEquipment.get(id)||{id};e.default_equipment=value;employeeEquipment.set(id,e);toast('Equipment assignment saved.','success');}
  function renderEquipmentSelect(row){const s=row.querySelector('.tk-equipment');if(!s)return;const v=s.value;s.innerHTML=equipmentOptions(v);s.value=v;}
  function applyDefaultEquipment(row,force=false){const id=row.querySelector('.tk-employee')?.value||'',s=row.querySelector('.tk-equipment'),n=row.querySelector('.tk-equipment-not-used');if(!s)return;if(n?.checked){s.disabled=true;return;}s.disabled=false;const v=employeeEquipment.get(id)?.default_equipment||'';if(force||!s.value)s.value=v;}

  function enhanceRow(row){
    if(row.dataset.tkLaunchDetails==='1')return;row.dataset.tkLaunchDetails='1';
    const detail=document.createElement('div');detail.className='tk-detail-row';
    detail.innerHTML=`<label>Start<input class="tk-start" type="time"></label><label>Stop<input class="tk-stop" type="time"></label><label>Lunch (min)<input class="tk-lunch" type="number" min="0" max="720" step="5" value="0"></label><label>Truck / Equipment<select class="tk-equipment">${equipmentOptions()}</select></label><label class="tk-detail-check"><input class="tk-equipment-not-used" type="checkbox"> Not used today</label><label class="tk-detail-check"><input class="tk-per-diem" type="checkbox" checked> Per diem</label><div class="tk-hours-worked">Worked: —</div>`;
    row.appendChild(detail);
    row.querySelectorAll('.tk-start,.tk-stop,.tk-lunch').forEach(el=>el.addEventListener('input',()=>syncPayrollFromClock(row)));
    row.querySelector('.tk-employee')?.addEventListener('change',()=>applyDefaultEquipment(row,true));row.querySelector('.tk-equipment-not-used')?.addEventListener('change',()=>applyDefaultEquipment(row,false));applyDefaultEquipment(row,false);
  }
  function collectDetails(){const out=[];document.querySelectorAll('#dailyCrewTimeRows .tk-crew-row').forEach(row=>{const employee_id=row.querySelector('.tk-employee')?.value||'';if(!employee_id)return;out.push({employee_id,start_time:row.querySelector('.tk-start')?.value||null,stop_time:row.querySelector('.tk-stop')?.value||null,lunch_minutes:Math.max(0,Math.min(720,Math.round(num(row.querySelector('.tk-lunch')?.value)))),per_diem:!!row.querySelector('.tk-per-diem')?.checked,equipment_used:row.querySelector('.tk-equipment')?.value||null,equipment_not_used:!!row.querySelector('.tk-equipment-not-used')?.checked});});return out;}
  async function saveDetails(reportId){if(!reportId)return;for(const item of collectDetails()){const payload={start_time:item.start_time,stop_time:item.stop_time,lunch_minutes:item.lunch_minutes,per_diem:item.per_diem,equipment_used:item.equipment_not_used?null:item.equipment_used,equipment_not_used:item.equipment_not_used,updated_at:new Date().toISOString()};const {error}=await getSb().from('timekeeping_entries').update(payload).eq('daily_report_id',reportId).eq('employee_id',item.employee_id).eq('company_id',companyId());if(error)throw error;}}
  function installSaveWrapper(){const current=window.saveDailyReportCrewTime;if(typeof current!=='function'||current===wrappedSave||current.__lcLaunchWrapped)return;const original=current;const wrapper=async reportId=>{document.querySelectorAll('#dailyCrewTimeRows .tk-crew-row').forEach(syncPayrollFromClock);await original(reportId);await saveDetails(reportId);};wrapper.__lcLaunchWrapped=true;wrapper.__lcOriginal=original;wrappedSave=wrapper;window.saveDailyReportCrewTime=wrapper;}
  async function loadExistingDetails(){
    const form=byId('dailyReportForm');if(!form||form.classList.contains('hidden')){loadedReport='';return;}const reportId=form.dataset.reportId||'';if(!reportId||reportId===loadedReport)return;
    const rows=[...document.querySelectorAll('#dailyCrewTimeRows .tk-crew-row')];if(!rows.length)return;const {data,error}=await getSb().from('timekeeping_entries').select('employee_id,start_time,stop_time,lunch_minutes,per_diem,equipment_used,equipment_not_used').eq('daily_report_id',reportId).eq('company_id',companyId());if(error)return;
    const map=new Map((data||[]).map(x=>[x.employee_id,x]));rows.forEach(row=>{enhanceRow(row);const item=map.get(row.querySelector('.tk-employee')?.value||'');if(!item)return;row.querySelector('.tk-start').value=(item.start_time||'').slice(0,5);row.querySelector('.tk-stop').value=(item.stop_time||'').slice(0,5);row.querySelector('.tk-lunch').value=item.lunch_minutes||0;row.querySelector('.tk-per-diem').checked=!!item.per_diem;row.querySelector('.tk-equipment-not-used').checked=!!item.equipment_not_used;row.querySelector('.tk-equipment').value=item.equipment_used||employeeEquipment.get(item.employee_id)?.default_equipment||'';applyDefaultEquipment(row,false);syncPayrollFromClock(row);});loadedReport=reportId;
  }
  function updateHelp(){const p=byId('dailyCrewTimeCard')?.querySelector('.tk-help');if(p&&!p.dataset.tkLaunchHelp){p.dataset.tkLaunchHelp='1';p.textContent='Your assigned crew and your own Foreman row load automatically. Enter Start, Stop and Lunch; LineCrew calculates hours for payroll. Per diem defaults on and can be unchecked when it does not apply. Select assigned equipment or mark Not used today.';}}
  function scan(){addStyles();installSaveWrapper();installEquipmentManager();updateHelp();document.querySelectorAll('#dailyCrewTimeRows .tk-crew-row').forEach(enhanceRow);loadExistingDetails();}
  function init(){addStyles();refreshData().then(scan);scan();let timer;new MutationObserver(()=>{clearTimeout(timer);timer=setTimeout(scan,50);}).observe(document.body,{subtree:true,childList:true,attributes:true,attributeFilter:['class']});setInterval(installSaveWrapper,1000);}
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',init);else init();
})();
