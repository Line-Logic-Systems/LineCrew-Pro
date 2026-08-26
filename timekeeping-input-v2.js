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
  const canManageEquipment=()=>['owner','admin','gf'].includes(role());
  let employeeEquipment=new Map();
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
      .tk-detail-row{grid-column:1/-1;display:grid;grid-template-columns:repeat(6,minmax(105px,1fr));gap:8px;padding:8px 0 2px;border-top:1px dashed #d7e0e8}
      .tk-detail-row label{font-size:11px;margin:0}.tk-detail-row input{margin:0;padding:8px}
      .tk-detail-check{display:flex;gap:6px;align-items:center;padding-top:22px}.tk-detail-check input{width:auto;min-width:0}
      .tk-worked{font-size:12px;color:#5f7080;align-self:end;padding:0 0 9px}.tk-worked.warn{color:#a15c00;font-weight:700}
      .tk-equipment-card{margin-top:14px;border-top:1px solid #dce5ed;padding-top:12px}.tk-equipment-grid{display:grid;gap:7px}.tk-equipment-line{display:grid;grid-template-columns:minmax(170px,1fr) minmax(180px,1fr) auto;gap:8px;align-items:center}.tk-equipment-line input,.tk-equipment-line button{margin:0}
      @media(max-width:900px){.tk-detail-row{grid-template-columns:repeat(3,1fr)}}
      @media(max-width:600px){.tk-detail-row{grid-template-columns:1fr 1fr}.tk-equipment-line{grid-template-columns:1fr}.tk-equipment-line button{width:100%}}
    `;
    document.head.appendChild(style);
  }

  async function refreshEquipmentMap(){
    const client=getSb();
    if(!client||!companyId()) return;
    const {data,error}=await client.from('timekeeping_employees')
      .select('id,full_name,employee_number,active,default_equipment')
      .eq('company_id',companyId())
      .order('full_name');
    if(error){console.warn('Could not load default equipment',error);return;}
    employeeEquipment=new Map((data||[]).map(e=>[e.id,e]));
    renderEquipmentManager();
    document.querySelectorAll('#dailyCrewTimeRows .tk-crew-row').forEach(row=>applyDefaultEquipment(row,false));
  }

  function installEquipmentManager(){
    const roster=byId('timekeepingRosterCard');
    if(!roster||byId('tkDefaultEquipmentCard')||!canManageEquipment()) return;
    const box=document.createElement('div');
    box.id='tkDefaultEquipmentCard';
    box.className='tk-equipment-card';
    box.innerHTML='<h4>Default Equipment</h4><p class="tk-help">Assign the truck or normal equipment each employee usually uses. It will prefill on Daily Reports and can be marked Not used today.</p><div id="tkDefaultEquipmentList" class="tk-equipment-grid"></div>';
    roster.appendChild(box);
    renderEquipmentManager();
  }

  function renderEquipmentManager(){
    const box=byId('tkDefaultEquipmentList');
    if(!box) return;
    const rows=[...employeeEquipment.values()].filter(e=>e.active!==false);
    if(!rows.length){box.innerHTML='<span class="muted">Add employees above before assigning equipment.</span>';return;}
    box.innerHTML=rows.map(e=>`<div class="tk-equipment-line"><strong>${esc(e.full_name||e.employee_number||'Employee')}</strong><input data-tk-default-equipment="${esc(e.id)}" value="${esc(e.default_equipment||'')}" placeholder="Truck, bucket, digger, trailer…"><button type="button" class="secondary small" data-tk-save-equipment="${esc(e.id)}">Save</button></div>`).join('');
    box.querySelectorAll('[data-tk-save-equipment]').forEach(button=>button.onclick=()=>saveDefaultEquipment(button.dataset.tkSaveEquipment));
  }

  async function saveDefaultEquipment(employeeId){
    const client=getSb();
    const input=document.querySelector(`[data-tk-default-equipment="${CSS.escape(employeeId)}"]`);
    if(!client||!input) return;
    const value=input.value.trim()||null;
    const {error}=await client.from('timekeeping_employees').update({default_equipment:value,updated_at:new Date().toISOString()}).eq('id',employeeId).eq('company_id',companyId());
    if(error){toast('Could not save default equipment: '+error.message,'error');return;}
    const existing=employeeEquipment.get(employeeId)||{id:employeeId};existing.default_equipment=value;employeeEquipment.set(employeeId,existing);
    document.querySelectorAll('#dailyCrewTimeRows .tk-crew-row').forEach(row=>applyDefaultEquipment(row,false));
    toast('Default equipment saved.','success');
  }

  function minutes(value){
    if(!value||!/^[0-2]\d:[0-5]\d/.test(value)) return null;
    const [h,m]=value.slice(0,5).split(':').map(Number);return h*60+m;
  }

  function workedHours(row){
    const start=minutes(row.querySelector('.tk-start')?.value);
    const stop=minutes(row.querySelector('.tk-stop')?.value);
    if(start===null||stop===null) return null;
    let span=stop-start;if(span<0) span+=1440;
    span-=Math.max(0,num(row.querySelector('.tk-lunch')?.value));
    return Math.max(0,span/60);
  }

  function updateWorked(row){
    const output=row.querySelector('.tk-worked');if(!output)return;
    const worked=workedHours(row);
    if(worked===null){output.textContent='Worked: —';output.classList.remove('warn');return;}
    const payroll=num(row.querySelector('.tk-regular')?.value)+num(row.querySelector('.tk-ot')?.value);
    const mismatch=Math.abs(worked-payroll)>0.01;
    output.textContent=`Worked: ${worked.toFixed(2)}h${mismatch?` • payroll split ${payroll.toFixed(2)}h`:''}`;
    output.classList.toggle('warn',mismatch);
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
    detail.innerHTML=`
      <label>Start<input class="tk-start" type="time"></label>
      <label>Stop<input class="tk-stop" type="time"></label>
      <label>Lunch (min)<input class="tk-lunch" type="number" min="0" max="720" step="5" value="0"></label>
      <label>Equipment<input class="tk-equipment" type="text" placeholder="Truck / equipment"></label>
      <label class="tk-detail-check"><input class="tk-per-diem" type="checkbox"> Per diem</label>
      <label class="tk-detail-check"><input class="tk-equipment-not-used" type="checkbox"> Not used today</label>
      <div class="tk-worked">Worked: —</div>`;
    row.appendChild(detail);
    row.querySelectorAll('.tk-start,.tk-stop,.tk-lunch,.tk-regular,.tk-ot').forEach(el=>el?.addEventListener('input',()=>updateWorked(row)));
    row.querySelector('.tk-employee')?.addEventListener('change',()=>applyDefaultEquipment(row,true));
    row.querySelector('.tk-equipment-not-used')?.addEventListener('change',()=>applyDefaultEquipment(row,false));
    applyDefaultEquipment(row,false);updateWorked(row);
  }

  function collectDetails(){
    const out=[];
    document.querySelectorAll('#dailyCrewTimeRows .tk-crew-row').forEach(row=>{
      const employee_id=row.querySelector('.tk-employee')?.value||'';
      if(!employee_id) return;
      out.push({
        employee_id,
        start_time:row.querySelector('.tk-start')?.value||null,
        stop_time:row.querySelector('.tk-stop')?.value||null,
        lunch_minutes:Math.max(0,Math.min(720,Math.round(num(row.querySelector('.tk-lunch')?.value)))),
        per_diem:!!row.querySelector('.tk-per-diem')?.checked,
        equipment_used:(row.querySelector('.tk-equipment')?.value||'').trim()||null,
        equipment_not_used:!!row.querySelector('.tk-equipment-not-used')?.checked
      });
    });
    return out;
  }

  async function saveDetails(reportId){
    const client=getSb();if(!client||!reportId)return;
    const details=collectDetails();
    for(const item of details){
      const payload={start_time:item.start_time,stop_time:item.stop_time,lunch_minutes:item.lunch_minutes,per_diem:item.per_diem,equipment_used:item.equipment_not_used?null:item.equipment_used,equipment_not_used:item.equipment_not_used,updated_at:new Date().toISOString()};
      const {error}=await client.from('timekeeping_entries').update(payload).eq('daily_report_id',reportId).eq('employee_id',item.employee_id).eq('company_id',companyId());
      if(error) throw error;
    }
  }

  function installSaveWrapper(){
    const current=window.saveDailyReportCrewTime;
    if(typeof current!=='function'||current===wrappedSave||current.__lcLaunchWrapped) return;
    const original=current;
    const wrapper=async reportId=>{await original(reportId);await saveDetails(reportId);};
    wrapper.__lcLaunchWrapped=true;wrapper.__lcOriginal=original;
    wrappedSave=wrapper;window.saveDailyReportCrewTime=wrapper;
  }

  async function loadExistingDetails(){
    const form=byId('dailyReportForm');
    if(!form||form.classList.contains('hidden')){loadedReport='';return;}
    const reportId=form.dataset.reportId||'';
    if(!reportId||reportId===loadedReport) return;
    const rows=[...document.querySelectorAll('#dailyCrewTimeRows .tk-crew-row')];
    if(!rows.length) return;
    const client=getSb();if(!client)return;
    const {data,error}=await client.from('timekeeping_entries').select('employee_id,start_time,stop_time,lunch_minutes,per_diem,equipment_used,equipment_not_used').eq('daily_report_id',reportId).eq('company_id',companyId());
    if(error){console.warn('Could not load timekeeping detail fields',error);return;}
    const map=new Map((data||[]).map(x=>[x.employee_id,x]));
    rows.forEach(row=>{
      enhanceRow(row);
      const item=map.get(row.querySelector('.tk-employee')?.value||'');if(!item)return;
      row.querySelector('.tk-start').value=(item.start_time||'').slice(0,5);
      row.querySelector('.tk-stop').value=(item.stop_time||'').slice(0,5);
      row.querySelector('.tk-lunch').value=item.lunch_minutes||0;
      row.querySelector('.tk-per-diem').checked=!!item.per_diem;
      row.querySelector('.tk-equipment-not-used').checked=!!item.equipment_not_used;
      row.querySelector('.tk-equipment').value=item.equipment_used||employeeEquipment.get(item.employee_id)?.default_equipment||'';
      applyDefaultEquipment(row,false);updateWorked(row);
    });
    loadedReport=reportId;
  }

  function updateHelp(){
    const p=byId('dailyCrewTimeCard')?.querySelector('.tk-help');
    if(p&&!p.dataset.tkLaunchHelp){p.dataset.tkLaunchHelp='1';p.textContent='Your assigned crew loads automatically. Record Start, Stop and Lunch for audit accuracy, then keep the Regular / OT split consistent with your company payroll rules. Per diem and equipment are carried into Timekeeping reporting.';}
  }

  function scan(){
    addStyles();installSaveWrapper();installEquipmentManager();updateHelp();
    document.querySelectorAll('#dailyCrewTimeRows .tk-crew-row').forEach(enhanceRow);
    loadExistingDetails();
  }

  function init(){
    addStyles();refreshEquipmentMap().then(scan);scan();
    let timer;new MutationObserver(()=>{clearTimeout(timer);timer=setTimeout(scan,50);}).observe(document.body,{subtree:true,childList:true,attributes:true,attributeFilter:['class']});
    setInterval(installSaveWrapper,1000);
    document.addEventListener('change',event=>{if(event.target?.matches?.('.tk-employee'))setTimeout(()=>{applyDefaultEquipment(event.target.closest('.tk-crew-row'),true);},0);});
  }
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',init);else init();
})();
