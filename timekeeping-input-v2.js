/* LineCrew Pro - launch timekeeping detail capture */
(() => {
  'use strict';
  const byId=id=>document.getElementById(id);
  const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot',"'":'&#39;'}[c]));
  const getSb=()=>{try{return typeof sb!=='undefined'?sb:(window.sb||window.supabaseClient||null);}catch(_){return window.sb||window.supabaseClient||null;}};
  const profile=()=>typeof currentProfile!=='undefined'?currentProfile:window.currentProfile;
  const companyId=()=>profile()?.company_id||null;
  const role=()=>String(profile()?.role||'').toLowerCase();
  const canManageEquipment=()=>['owner','admin'].includes(role());
  let employeeEquipment=new Map();
  let equipment=[];
  let wrappedSave=null;
  let loadedReport='';

  function toast(message,type='info'){
    if(window.LineCrewUI?.toast) window.LineCrewUI.toast(message,type);
    else if(type==='error') console.error(message);
  }

  function addStyles(){
    if(byId('tkLaunchDetailStyles')) return;
    const style=document.createElement('style');
    style.id='tkLaunchDetailStyles';
    style.textContent=`
      .tk-detail-row{grid-column:1/-1;display:grid;grid-template-columns:minmax(150px,1fr) auto auto;gap:10px;padding:8px 0 2px;border-top:1px dashed #d7e0e8;align-items:end}
      .tk-detail-row label{font-size:11px;margin:0}.tk-detail-row select{margin:0;padding:8px}
      .tk-detail-check{display:flex;gap:6px;align-items:center;padding-bottom:10px}.tk-detail-check input{width:auto;min-width:0}
      .tk-equipment-card{margin-top:14px;border-top:1px solid #dce5ed;padding-top:12px}.tk-equipment-grid{display:grid;gap:7px}.tk-equipment-line{display:grid;grid-template-columns:minmax(170px,1fr) minmax(180px,1fr) auto;gap:8px;align-items:center}.tk-equipment-line select,.tk-equipment-line button{margin:0}
      .tk-equipment-upload{display:flex;gap:8px;flex-wrap:wrap;align-items:end;margin:10px 0}.tk-equipment-upload label{margin:0;min-width:190px}.tk-equipment-upload button{width:auto;margin:0}
      .tk-equipment-roster{font-size:12px;color:#5f7080;margin:6px 0 12px}
      @media(max-width:600px){.tk-detail-row{grid-template-columns:1fr 1fr}.tk-detail-row>label:first-child{grid-column:1/-1}.tk-equipment-line{grid-template-columns:1fr}.tk-equipment-line button{width:100%}}
    `;
    document.head.appendChild(style);
  }

  async function refreshData(){
    const client=getSb();
    if(!client||!companyId()) return;
    const [empRes,equipRes]=await Promise.all([
      client.from('timekeeping_employees').select('id,full_name,employee_number,active,default_equipment').eq('company_id',companyId()).order('full_name'),
      client.from('timekeeping_equipment').select('id,unit_number,description,active').eq('company_id',companyId()).order('unit_number')
    ]);
    if(empRes.error) console.warn('Could not load employee equipment assignments',empRes.error);
    else employeeEquipment=new Map((empRes.data||[]).map(e=>[e.id,e]));
    if(equipRes.error) console.warn('Could not load equipment roster',equipRes.error);
    else equipment=equipRes.data||[];
    renderEquipmentManager();
    document.querySelectorAll('#dailyCrewTimeRows .tk-crew-row').forEach(row=>{renderEquipmentSelect(row);applyDefaultEquipment(row,false);});
  }

  function equipmentOptions(selected=''){
    const active=equipment.filter(e=>e.active!==false);
    return '<option value="">Select truck / equipment</option>'+active.map(e=>`<option value="${esc(e.unit_number)}" ${e.unit_number===selected?'selected':''}>${esc(e.unit_number)}${e.description?' — '+esc(e.description):''}</option>`).join('');
  }

  function installEquipmentManager(){
    const roster=byId('timekeepingRosterCard');
    if(!roster||byId('tkDefaultEquipmentCard')||!canManageEquipment()) return;
    const box=document.createElement('div');
    box.id='tkDefaultEquipmentCard';
    box.className='tk-equipment-card';
    box.innerHTML=`<h4>Truck / Equipment Roster</h4>
      <p class="tk-help">Upload the company truck/equipment roster, then assign each employee's normal unit. Foremen can only choose from this roster on Daily Reports.</p>
      <div class="tk-equipment-upload"><label>Roster CSV<input id="tkEquipmentCsv" type="file" accept=".csv,text/csv"></label><button id="tkUploadEquipment" type="button" class="secondary small">Upload roster</button></div>
      <div class="tk-equipment-roster" id="tkEquipmentRosterSummary"></div>
      <div id="tkDefaultEquipmentList" class="tk-equipment-grid"></div>`;
    roster.appendChild(box);
    byId('tkUploadEquipment').onclick=uploadEquipmentRoster;
    renderEquipmentManager();
  }

  async function uploadEquipmentRoster(){
    const file=byId('tkEquipmentCsv')?.files?.[0];
    if(!file) return toast('Choose a CSV equipment roster first.','error');
    const text=await file.text();
    const lines=text.split(/\r?\n/).map(x=>x.trim()).filter(Boolean);
    if(!lines.length) return toast('That roster is empty.','error');
    const first=lines[0].split(',').map(x=>x.trim().replace(/^"|"$/g,''));
    const hasHeader=/unit|truck|equipment|number/i.test(first.join(' '));
    const rows=(hasHeader?lines.slice(1):lines).map(line=>{
      const cols=line.split(',').map(x=>x.trim().replace(/^"|"$/g,''));
      return {company_id:companyId(),unit_number:cols[0]||'',description:cols[1]||null,active:true};
    }).filter(r=>r.unit_number);
    if(!rows.length) return toast('No truck/equipment numbers were found. Put the unit number in the first CSV column.','error');
    const {error}=await getSb().from('timekeeping_equipment').upsert(rows,{onConflict:'company_id,unit_number'});
    if(error) return toast('Could not upload equipment roster: '+error.message,'error');
    toast(`${rows.length} equipment roster row${rows.length===1?'':'s'} loaded.`,'success');
    await refreshData();
  }

  function renderEquipmentManager(){
    const summary=byId('tkEquipmentRosterSummary');
    if(summary) summary.textContent=`${equipment.filter(e=>e.active!==false).length} active truck/equipment unit${equipment.filter(e=>e.active!==false).length===1?'':'s'} available.`;
    const box=byId('tkDefaultEquipmentList');
    if(!box) return;
    const rows=[...employeeEquipment.values()].filter(e=>e.active!==false);
    if(!rows.length){box.innerHTML='<span class="muted">Add employees above before assigning equipment.</span>';return;}
    box.innerHTML=rows.map(e=>`<div class="tk-equipment-line"><strong>${esc(e.full_name||e.employee_number||'Employee')}</strong><select data-tk-default-equipment="${esc(e.id)}">${equipmentOptions(e.default_equipment||'')}</select><button type="button" class="secondary small" data-tk-save-equipment="${esc(e.id)}">Save assignment</button></div>`).join('');
    box.querySelectorAll('[data-tk-save-equipment]').forEach(button=>button.onclick=()=>saveDefaultEquipment(button.dataset.tkSaveEquipment));
  }

  async function saveDefaultEquipment(employeeId){
    const input=document.querySelector(`[data-tk-default-equipment="${CSS.escape(employeeId)}"]`);
    if(!input) return;
    const value=input.value||null;
    const {error}=await getSb().from('timekeeping_employees').update({default_equipment:value,updated_at:new Date().toISOString()}).eq('id',employeeId).eq('company_id',companyId());
    if(error){toast('Could not save equipment assignment: '+error.message,'error');return;}
    const existing=employeeEquipment.get(employeeId)||{id:employeeId};existing.default_equipment=value;employeeEquipment.set(employeeId,existing);
    document.querySelectorAll('#dailyCrewTimeRows .tk-crew-row').forEach(row=>applyDefaultEquipment(row,false));
    toast('Equipment assignment saved.','success');
  }

  function renderEquipmentSelect(row){
    const select=row.querySelector('.tk-equipment');
    if(!select) return;
    const selected=select.value;
    select.innerHTML=equipmentOptions(selected);
    select.value=selected;
  }

  function applyDefaultEquipment(row,force=false){
    const employeeId=row.querySelector('.tk-employee')?.value||'';
    const input=row.querySelector('.tk-equipment');
    const notUsed=row.querySelector('.tk-equipment-not-used');
    if(!input) return;
    if(notUsed?.checked){input.disabled=true;return;}
    input.disabled=false;
    const value=employeeEquipment.get(employeeId)?.default_equipment||'';
    if(force||!input.value) input.value=value;
  }

  function enhanceRow(row){
    if(row.dataset.tkLaunchDetails==='1') return;
    row.dataset.tkLaunchDetails='1';
    const detail=document.createElement('div');
    detail.className='tk-detail-row';
    detail.innerHTML=`<label>Truck / Equipment<select class="tk-equipment">${equipmentOptions()}</select></label><label class="tk-detail-check"><input class="tk-per-diem" type="checkbox"> Per diem</label><label class="tk-detail-check"><input class="tk-equipment-not-used" type="checkbox"> Not used today</label>`;
    row.appendChild(detail);
    row.querySelector('.tk-employee')?.addEventListener('change',()=>applyDefaultEquipment(row,true));
    row.querySelector('.tk-equipment-not-used')?.addEventListener('change',()=>applyDefaultEquipment(row,false));
    applyDefaultEquipment(row,false);
  }

  function collectDetails(){
    const out=[];
    document.querySelectorAll('#dailyCrewTimeRows .tk-crew-row').forEach(row=>{
      const employee_id=row.querySelector('.tk-employee')?.value||'';
      if(!employee_id) return;
      out.push({employee_id,per_diem:!!row.querySelector('.tk-per-diem')?.checked,equipment_used:row.querySelector('.tk-equipment')?.value||null,equipment_not_used:!!row.querySelector('.tk-equipment-not-used')?.checked});
    });
    return out;
  }

  async function saveDetails(reportId){
    if(!reportId)return;
    for(const item of collectDetails()){
      const payload={start_time:null,stop_time:null,lunch_minutes:0,per_diem:item.per_diem,equipment_used:item.equipment_not_used?null:item.equipment_used,equipment_not_used:item.equipment_not_used,updated_at:new Date().toISOString()};
      const {error}=await getSb().from('timekeeping_entries').update(payload).eq('daily_report_id',reportId).eq('employee_id',item.employee_id).eq('company_id',companyId());
      if(error) throw error;
    }
  }

  function installSaveWrapper(){
    const current=window.saveDailyReportCrewTime;
    if(typeof current!=='function'||current===wrappedSave||current.__lcLaunchWrapped) return;
    const original=current;
    const wrapper=async reportId=>{await original(reportId);await saveDetails(reportId);};
    wrapper.__lcLaunchWrapped=true;wrapper.__lcOriginal=original;wrappedSave=wrapper;window.saveDailyReportCrewTime=wrapper;
  }

  async function loadExistingDetails(){
    const form=byId('dailyReportForm');
    if(!form||form.classList.contains('hidden')){loadedReport='';return;}
    const reportId=form.dataset.reportId||'';
    if(!reportId||reportId===loadedReport) return;
    const rows=[...document.querySelectorAll('#dailyCrewTimeRows .tk-crew-row')];
    if(!rows.length) return;
    const {data,error}=await getSb().from('timekeeping_entries').select('employee_id,per_diem,equipment_used,equipment_not_used').eq('daily_report_id',reportId).eq('company_id',companyId());
    if(error){console.warn('Could not load timekeeping detail fields',error);return;}
    const map=new Map((data||[]).map(x=>[x.employee_id,x]));
    rows.forEach(row=>{
      enhanceRow(row);
      const item=map.get(row.querySelector('.tk-employee')?.value||'');if(!item)return;
      row.querySelector('.tk-per-diem').checked=!!item.per_diem;
      row.querySelector('.tk-equipment-not-used').checked=!!item.equipment_not_used;
      row.querySelector('.tk-equipment').value=item.equipment_used||employeeEquipment.get(item.employee_id)?.default_equipment||'';
      applyDefaultEquipment(row,false);
    });
    loadedReport=reportId;
  }

  function updateHelp(){
    const p=byId('dailyCrewTimeCard')?.querySelector('.tk-help');
    if(p&&!p.dataset.tkLaunchHelp){p.dataset.tkLaunchHelp='1';p.textContent='Your assigned crew and your own Foreman row load automatically. Enter Regular and OT hours, mark per diem when applicable, and select the assigned truck/equipment from the company roster.';}
  }

  function scan(){
    addStyles();installSaveWrapper();installEquipmentManager();updateHelp();
    document.querySelectorAll('#dailyCrewTimeRows .tk-crew-row').forEach(enhanceRow);
    loadExistingDetails();
  }

  function init(){
    addStyles();refreshData().then(scan);scan();
    let timer;new MutationObserver(()=>{clearTimeout(timer);timer=setTimeout(scan,50);}).observe(document.body,{subtree:true,childList:true,attributes:true,attributeFilter:['class']});
    setInterval(installSaveWrapper,1000);
  }
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',init);else init();
})();
