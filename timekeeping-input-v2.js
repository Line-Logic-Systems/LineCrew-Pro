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
  let employeeEquipment=new Map(),equipment=[],foremenById=new Map(),wrappedSave=null,loadedReport='';
  let assignmentSearch='',assignmentFilter='all',loadedCompanyId='',refreshingData=false;

  function toast(message,type='info'){if(window.LineCrewUI?.toast)window.LineCrewUI.toast(message,type);else if(type==='error')console.error(message);}
  function addStyles(){if(byId('tkLaunchDetailStyles'))return;const style=document.createElement('style');style.id='tkLaunchDetailStyles';style.textContent=`
    .tk-crew-row>label:has(.tk-regular),.tk-crew-row>label:has(.tk-ot){display:none!important}
    #dailyCrewTimeRows .tk-crew-row{border-bottom:3px solid #8b9dad;padding-bottom:16px;margin-bottom:16px}
    #dailyCrewTimeRows .tk-crew-row:last-child{border-bottom:0;margin-bottom:0}
    .tk-detail-row{grid-column:1/-1;display:grid;grid-template-columns:110px 110px 100px minmax(150px,1fr) auto auto;gap:10px;padding:8px 0 2px;border-top:1px solid #c2cdd7;align-items:end}
    .tk-detail-row label{font-size:11px;margin:0}.tk-detail-row input,.tk-detail-row select{margin:0;padding:8px}.tk-clock24{font-variant-numeric:tabular-nums;letter-spacing:.4px}
    .tk-detail-check{display:flex;gap:6px;align-items:center;padding-bottom:10px}.tk-detail-check input{width:auto;min-width:0}.tk-hours-worked{font-size:12px;color:#5f7080;grid-column:1/-1}
    .tk-equipment-card{margin-top:14px;border-top:1px solid #dce5ed;padding-top:12px}
    .tk-equipment-grid{display:grid;gap:8px}.tk-equipment-line{display:grid;grid-template-columns:minmax(170px,1fr) minmax(220px,1fr) 70px;gap:8px;align-items:center}.tk-equipment-line select{margin:0}.tk-equipment-save-state{font-size:12px;color:#617284}.tk-equipment-save-state.saved{color:#198754;font-weight:700}
    .tk-equipment-upload{display:flex;gap:8px;flex-wrap:wrap;align-items:end;margin:10px 0 14px}.tk-equipment-upload label{margin:0;min-width:220px}.tk-equipment-upload button{width:auto;margin:0}.tk-equipment-roster{font-size:12px;color:#5f7080;margin:6px 0 12px}
    .tk-saved-roster{border:1px solid #dce5ed;border-radius:12px;margin:10px 0 16px;background:#f8fafc;overflow:hidden}.tk-saved-roster summary{cursor:pointer;padding:11px 12px;font-weight:800}.tk-saved-roster-body{padding:0 12px 12px}.tk-saved-equipment-table{width:100%;border-collapse:collapse;font-size:12px}.tk-saved-equipment-table th,.tk-saved-equipment-table td{padding:8px 6px;border-bottom:1px solid #dce5ed;text-align:left}.tk-saved-equipment-table th{color:#617284}.tk-saved-equipment-table button{width:auto;margin:0;padding:6px 8px}.tk-unit-inactive{opacity:.55}.tk-assignment-heading{margin:14px 0 6px}
    .tk-assignment-tools{display:grid;grid-template-columns:minmax(200px,1fr) 180px;gap:8px;margin:10px 0}.tk-assignment-tools input,.tk-assignment-tools select{margin:0}
    .tk-assignment-group{border:1px solid #dce5ed;border-radius:12px;background:#fff;overflow:hidden}.tk-assignment-group summary{cursor:pointer;padding:10px 12px;font-weight:800;background:#f5f8fb}.tk-assignment-group-body{display:grid;gap:7px;padding:10px 12px}.tk-assignment-count{font-weight:400;color:#617284}
    @media(max-width:760px){.tk-detail-row{grid-template-columns:1fr 1fr}.tk-detail-row>label:nth-child(4){grid-column:1/-1}.tk-equipment-line{grid-template-columns:1fr}.tk-saved-roster-body{overflow-x:auto}.tk-saved-equipment-table{min-width:560px}.tk-assignment-tools{grid-template-columns:1fr}}
  `;document.head.appendChild(style);}

  function normalizeClock(input){let v=String(input.value||'').replace(/[^0-9:]/g,'').slice(0,5);if(/^\d{3,4}$/.test(v)){v=v.padStart(4,'0');v=v.slice(0,2)+':'+v.slice(2);}if(/^\d{1,2}:\d{1,2}$/.test(v)){let [h,m]=v.split(':').map(Number);if(h>=0&&h<=23&&m>=0&&m<=59)v=String(h).padStart(2,'0')+':'+String(m).padStart(2,'0');}input.value=v;}
  function clockMinutes(v){if(!v||!/^([01]\d|2[0-3]):[0-5]\d$/.test(v))return null;const [h,m]=v.split(':').map(Number);return h*60+m;}
  function workedHours(row){const s=clockMinutes(row.querySelector('.tk-start')?.value),e=clockMinutes(row.querySelector('.tk-stop')?.value);if(s===null||e===null)return null;let mins=e-s;if(mins<0)mins+=1440;mins-=Math.max(0,num(row.querySelector('.tk-lunch')?.value));return Math.max(0,mins/60);}
  function syncPayrollFromClock(row){const total=workedHours(row),out=row.querySelector('.tk-hours-worked');if(total===null){if(out)out.textContent='Worked: —';return;}const ri=row.querySelector('.tk-regular'),oi=row.querySelector('.tk-ot');if(ri)ri.value=total.toFixed(2);if(oi)oi.value='0.00';ri?.dispatchEvent(new Event('change',{bubbles:true}));oi?.dispatchEvent(new Event('change',{bubbles:true}));if(out)out.textContent=`Worked: ${total.toFixed(2)} h · Weekly OT is calculated after save`;}

  function assignedEmployeeForUnit(unit,excludeId=''){return [...employeeEquipment.values()].find(e=>e.active!==false&&e.id!==excludeId&&e.default_equipment===unit)||null;}
  async function refreshData(){
    const c=getSb(),cid=companyId();
    if(!c||!cid||refreshingData)return false;
    refreshingData=true;
    try{
      const requests=[
        c.from('timekeeping_employees').select('id,full_name,employee_number,classification,active,default_equipment,linked_profile_id,assigned_foreman_id,default_crew_name').eq('company_id',cid).order('full_name'),
        c.from('timekeeping_equipment').select('id,unit_number,description,active').eq('company_id',cid).order('unit_number')
      ];
      if(canManageEquipment())requests.push(c.from('profiles').select('id,full_name,role,active').eq('company_id',cid).eq('role','foreman').eq('active',true).order('full_name'));
      const [er,qr,fr]=await Promise.all(requests);
      if(er.error||qr.error){console.warn('Unable to load timekeeping equipment data:',er.error?.message||qr.error?.message);return false;}
      employeeEquipment=new Map((er.data||[]).map(e=>[e.id,e]));
      equipment=qr.data||[];
      if(fr&&!fr.error)foremenById=new Map((fr.data||[]).map(f=>[f.id,f]));
      loadedCompanyId=cid;
      renderEquipmentManager();
      ensureForemanRow();
      document.querySelectorAll('#dailyCrewTimeRows .tk-crew-row').forEach(r=>{renderEquipmentSelect(r);applyDefaultEquipment(r,false);});
      sortForemanFirst();
      return true;
    }finally{
      refreshingData=false;
    }
  }
  function ensureDataLoaded(){const cid=companyId();if(!cid||loadedCompanyId===cid)return;refreshData().then(ok=>{if(ok)scan();});}
  function equipmentOptions(selected='',employeeId='',showAssignments=false){return '<option value="">Select truck / equipment</option>'+equipment.filter(e=>e.active!==false).map(e=>{const assigned=showAssignments?assignedEmployeeForUnit(e.unit_number,employeeId):null;const label=`${e.unit_number}${e.description?' — '+e.description:''}${assigned?' — Assigned: '+(assigned.full_name||assigned.employee_number||'Employee'):''}`;return `<option value="${esc(e.unit_number)}" ${e.unit_number===selected?'selected':''} ${assigned?'style="color:#9aa6b2"':''}>${esc(label)}</option>`;}).join('');}
  function installEquipmentManager(){
    const roster=byId('timekeepingRosterCard');if(!roster||byId('tkDefaultEquipmentCard')||!canManageEquipment())return;
    const box=document.createElement('div');box.id='tkDefaultEquipmentCard';box.className='tk-equipment-card';
    box.innerHTML=`<h4>Truck / Equipment Roster</h4><p class="tk-help">The saved company roster stays in LineCrew Pro even when no equipment is assigned. Upload another file any time to add new units or update matching unit numbers.</p><details id="tkSavedEquipmentRoster" class="tk-saved-roster"><summary id="tkSavedEquipmentSummary">Saved Company Equipment Roster</summary><div class="tk-saved-roster-body" id="tkSavedEquipmentList"></div></details><div class="tk-equipment-upload"><label>Add / Update Equipment Roster<input id="tkEquipmentCsv" type="file" accept=".xlsx,.xls,.csv,.tsv,.txt,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet,application/vnd.ms-excel,text/csv,text/tab-separated-values,text/plain"></label><button id="tkUploadEquipment" type="button" class="secondary small">Save / Update Roster</button></div><h4 class="tk-assignment-heading">Employee Equipment Assignments</h4><p class="tk-help">Assignments save automatically. Search by employee or unit, or open only the Foreman/crew you need. Units assigned to someone else stay selectable but are faded and labeled.</p><div class="tk-assignment-tools"><input id="tkEquipmentEmployeeSearch" type="search" placeholder="Search employee, #, class, or unit"><select id="tkEquipmentAssignmentFilter"><option value="all">All employees</option><option value="assigned">Assigned only</option><option value="unassigned">Unassigned only</option></select></div><div id="tkDefaultEquipmentList" class="tk-equipment-grid"></div>`;
    roster.appendChild(box);
    byId('tkUploadEquipment').onclick=uploadEquipmentRoster;
    byId('tkEquipmentEmployeeSearch').addEventListener('input',e=>{assignmentSearch=e.target.value||'';renderEquipmentAssignments();});
    byId('tkEquipmentAssignmentFilter').addEventListener('change',e=>{assignmentFilter=e.target.value||'all';renderEquipmentAssignments();});
    renderEquipmentManager();
  }
  function normalizeEquipmentMatrix(matrix){const clean=(matrix||[]).map(row=>(Array.isArray(row)?row:[row]).map(v=>String(v??'').trim())).filter(row=>row.some(Boolean));if(!clean.length)return[];const header=clean[0].map(v=>v.toLowerCase().replace(/[^a-z0-9]/g,''));const find=patterns=>header.findIndex(h=>patterns.some(p=>h.includes(p)));let unitIndex=find(['unitnumber','unitno','unit','trucknumber','equipmentnumber','assetnumber','fleetnumber']);let descriptionIndex=find(['description','equipmenttype','type','equipment','trucktype','category']);const looksLikeHeader=unitIndex>=0||header.some(h=>['description','equipmenttype','trucktype','category'].some(p=>h.includes(p)));if(unitIndex<0)unitIndex=0;if(descriptionIndex<0)descriptionIndex=unitIndex===0?1:0;return(looksLikeHeader?clean.slice(1):clean).map(row=>({company_id:companyId(),unit_number:String(row[unitIndex]??'').trim(),description:String(row[descriptionIndex]??'').trim()||null,active:true})).filter(r=>r.unit_number);}
  function parseDelimitedEquipment(text,delimiter){const rows=[];let row=[],cell='',quoted=false;for(let i=0;i<text.length;i++){const ch=text[i];if(ch==='"'){if(quoted&&text[i+1]==='"'){cell+='"';i++;}else quoted=!quoted;}else if(ch===delimiter&&!quoted){row.push(cell);cell='';}else if((ch==='\n'||ch==='\r')&&!quoted){if(ch==='\r'&&text[i+1]==='\n')i++;row.push(cell);if(row.some(v=>String(v).trim()))rows.push(row);row=[];cell='';}else cell+=ch;}row.push(cell);if(row.some(v=>String(v).trim()))rows.push(row);return rows;}
  async function readEquipmentMatrix(file){const name=String(file.name||'').toLowerCase(),ext=name.includes('.')?name.split('.').pop():'';if(['xlsx','xls'].includes(ext)){if(typeof XLSX==='undefined')throw new Error('Excel reader is not available. Refresh LineCrew Pro and try again.');const data=await file.arrayBuffer(),workbook=XLSX.read(data,{type:'array'}),sheetName=workbook.SheetNames?.[0];if(!sheetName)throw new Error('The workbook does not contain a worksheet.');return XLSX.utils.sheet_to_json(workbook.Sheets[sheetName],{header:1,raw:false,defval:''});}const text=await file.text();if(ext==='tsv')return parseDelimitedEquipment(text,'\t');if(ext==='csv')return parseDelimitedEquipment(text,',');if(ext==='txt'){const firstLine=text.split(/\r?\n/,1)[0]||'',delimiter=firstLine.includes('\t')?'\t':firstLine.includes(',')?',':null;if(!delimiter)throw new Error('Text rosters must be comma- or tab-delimited.');return parseDelimitedEquipment(text,delimiter);}throw new Error('Unsupported file type. Use Excel (.xlsx/.xls), CSV, TSV, or delimited TXT.');}
  async function uploadEquipmentRoster(){const file=byId('tkEquipmentCsv')?.files?.[0];if(!file)return toast('Choose an equipment roster first.','error');try{const matrix=await readEquipmentMatrix(file),rows=normalizeEquipmentMatrix(matrix);if(!rows.length)return toast('No equipment unit numbers were found. Include a Unit Number column, or place unit numbers in the first column.','error');const seen=new Set(),deduped=rows.filter(r=>{const key=r.unit_number.toLowerCase();if(seen.has(key))return false;seen.add(key);return true;});const {error}=await getSb().from('timekeeping_equipment').upsert(deduped,{onConflict:'company_id,unit_number'});if(error)throw error;toast(`${deduped.length} equipment roster rows saved from ${file.name}.`,'success');if(byId('tkEquipmentCsv'))byId('tkEquipmentCsv').value='';await refreshData();}catch(error){toast('Could not upload equipment roster: '+(error?.message||String(error)),'error');}}
  function renderSavedEquipmentRoster(){const summary=byId('tkSavedEquipmentSummary'),box=byId('tkSavedEquipmentList');if(!summary||!box)return;const active=equipment.filter(e=>e.active!==false).length;summary.textContent=`Saved Company Equipment Roster — ${active} active / ${equipment.length} total`;if(!equipment.length){box.innerHTML='<p class="muted">No equipment has been saved yet.</p>';return;}box.innerHTML=`<table class="tk-saved-equipment-table"><thead><tr><th>Unit #</th><th>Type / Description</th><th>Assigned To</th><th>Status</th><th></th></tr></thead><tbody>${equipment.map(e=>{const assigned=assignedEmployeeForUnit(e.unit_number);return `<tr class="${e.active===false?'tk-unit-inactive':''}"><td><strong>${esc(e.unit_number)}</strong></td><td>${esc(e.description||'')}</td><td>${assigned?esc(assigned.full_name||assigned.employee_number||'Employee'):'Unassigned'}</td><td>${e.active===false?'Inactive':'Active'}</td><td><button type="button" class="secondary small" data-tk-toggle-equipment="${esc(e.id)}" data-active="${e.active===false?'1':'0'}">${e.active===false?'Reactivate':'Deactivate'}</button></td></tr>`;}).join('')}</tbody></table>`;box.querySelectorAll('[data-tk-toggle-equipment]').forEach(b=>b.onclick=()=>toggleEquipmentActive(b.dataset.tkToggleEquipment,b.dataset.active==='1'));}
  async function toggleEquipmentActive(id,active){const unit=equipment.find(e=>e.id===id);if(!unit)return;const assigned=assignedEmployeeForUnit(unit.unit_number);if(!active&&assigned)return toast(`Unassign ${unit.unit_number} from ${assigned.full_name||'the employee'} before deactivating it.`,'error');const {error}=await getSb().from('timekeeping_equipment').update({active}).eq('id',id).eq('company_id',companyId());if(error)return toast('Could not update equipment: '+error.message,'error');await refreshData();}

  function employeeMatchesAssignmentSearch(e){
    if(assignmentFilter==='assigned'&&!e.default_equipment)return false;
    if(assignmentFilter==='unassigned'&&e.default_equipment)return false;
    const q=assignmentSearch.trim().toLowerCase();if(!q)return true;
    const eq=equipment.find(x=>x.unit_number===e.default_equipment);
    return [e.full_name,e.employee_number,e.classification,e.default_crew_name,e.default_equipment,eq?.description].some(v=>String(v||'').toLowerCase().includes(q));
  }
  function assignmentGroupName(e){
    if(e.assigned_foreman_id){
      const f=foremenById.get(e.assigned_foreman_id);
      return f?.full_name?`${f.full_name} Crew`:'Assigned Crew';
    }
    return 'Unassigned Employees';
  }
  function renderAssignmentEmployee(e){return `<div class="tk-equipment-line"><strong>${esc(e.full_name||e.employee_number||'Employee')}</strong><select data-tk-default-equipment="${esc(e.id)}">${equipmentOptions(e.default_equipment||'',e.id,true)}</select><span class="tk-equipment-save-state ${e.default_equipment?'saved':''}" data-tk-save-state="${esc(e.id)}">${e.default_equipment?'Saved':''}</span></div>`;}
  function renderEquipmentAssignments(){
    const box=byId('tkDefaultEquipmentList');if(!box)return;
    const search=byId('tkEquipmentEmployeeSearch');if(search&&search.value!==assignmentSearch)search.value=assignmentSearch;
    const filter=byId('tkEquipmentAssignmentFilter');if(filter&&filter.value!==assignmentFilter)filter.value=assignmentFilter;
    const rows=[...employeeEquipment.values()].filter(e=>e.active!==false&&employeeMatchesAssignmentSearch(e));
    if(!rows.length){box.innerHTML='<span class="muted">No employees match that search/filter.</span>';return;}
    const groups=new Map();
    rows.forEach(e=>{const name=assignmentGroupName(e);if(!groups.has(name))groups.set(name,[]);groups.get(name).push(e);});
    const searching=!!assignmentSearch.trim()||assignmentFilter!=='all';
    box.innerHTML=[...groups.entries()].sort((a,b)=>a[0].localeCompare(b[0])).map(([name,members])=>`<details class="tk-assignment-group" ${searching?'open':''}><summary>${esc(name)} <span class="tk-assignment-count">— ${members.length} employee${members.length===1?'':'s'}</span></summary><div class="tk-assignment-group-body">${members.map(renderAssignmentEmployee).join('')}</div></details>`).join('');
    box.querySelectorAll('[data-tk-default-equipment]').forEach(s=>s.onchange=()=>saveDefaultEquipment(s.dataset.tkDefaultEquipment));
  }
  function renderEquipmentManager(){renderSavedEquipmentRoster();renderEquipmentAssignments();}
  async function saveDefaultEquipment(id){const input=document.querySelector(`[data-tk-default-equipment="${CSS.escape(id)}"]`),state=document.querySelector(`[data-tk-save-state="${CSS.escape(id)}"]`);if(!input)return;const value=input.value||null;if(state){state.textContent='Saving…';state.classList.remove('saved');}if(value){const others=[...employeeEquipment.values()].filter(e=>e.id!==id&&e.default_equipment===value);for(const other of others){const {error}=await getSb().from('timekeeping_employees').update({default_equipment:null,updated_at:new Date().toISOString()}).eq('id',other.id).eq('company_id',companyId());if(error){if(state)state.textContent='Error';return toast('Could not move equipment assignment: '+error.message,'error');}other.default_equipment=null;employeeEquipment.set(other.id,other);}}
    const {error}=await getSb().from('timekeeping_employees').update({default_equipment:value,updated_at:new Date().toISOString()}).eq('id',id).eq('company_id',companyId());if(error){if(state)state.textContent='Error';return toast('Could not save equipment assignment: '+error.message,'error');}const e=employeeEquipment.get(id)||{id};e.default_equipment=value;employeeEquipment.set(id,e);if(state){state.textContent='Saved';state.classList.add('saved');}renderEquipmentManager();document.querySelectorAll('#dailyCrewTimeRows .tk-crew-row').forEach(r=>{renderEquipmentSelect(r);applyDefaultEquipment(r,false);});}

  function renderEquipmentSelect(row){
    const s=row.querySelector('.tk-equipment');if(!s)return;
    const id=row.querySelector('.tk-employee')?.value||'';
    const current=s.value||'';
    const fallback=employeeEquipment.get(id)?.default_equipment||'';
    const selected=current||fallback;
    s.innerHTML=equipmentOptions(selected);
    s.value=selected;
  }
  function applyDefaultEquipment(row,force=false){
    const id=row.querySelector('.tk-employee')?.value||'',s=row.querySelector('.tk-equipment'),n=row.querySelector('.tk-equipment-not-used');if(!s)return;
    if(n?.checked){s.disabled=true;return;}
    s.disabled=false;
    const fallback=employeeEquipment.get(id)?.default_equipment||'';
    if(force||!s.value)s.value=fallback;
  }

  function ownForemanEmployee(){if(role()!=='foreman')return null;const viewer=profile()?.id;return [...employeeEquipment.values()].find(e=>e.active!==false&&e.linked_profile_id===viewer)||null;}
  function ensureForemanRow(){const ownEmp=ownForemanEmployee(),box=byId('dailyCrewTimeRows');if(!ownEmp||!box)return;const rows=[...box.querySelectorAll('.tk-crew-row')],existing=rows.find(r=>r.querySelector('.tk-employee')?.value===ownEmp.id);if(existing){if(box.firstElementChild!==existing)box.insertBefore(existing,box.firstElementChild);return;}if(!rows.length)return;const row=rows[0].cloneNode(true);row.dataset.tkLaunchDetails='';row.querySelector('.tk-detail-row')?.remove();const sel=row.querySelector('.tk-employee');if(sel)sel.value=ownEmp.id;const reg=row.querySelector('.tk-regular'),ot=row.querySelector('.tk-ot');if(reg)reg.value='0';if(ot)ot.value='0';const remove=row.querySelector('.tk-remove');if(remove){remove.textContent='Foreman';remove.disabled=true;remove.classList.remove('danger');remove.classList.add('secondary');}box.insertBefore(row,box.firstElementChild);}
  function sortForemanFirst(){if(role()!=='foreman')return;ensureForemanRow();const box=byId('dailyCrewTimeRows'),ownEmp=ownForemanEmployee();if(!box||!ownEmp)return;const own=[...box.querySelectorAll('.tk-crew-row')].find(r=>r.querySelector('.tk-employee')?.value===ownEmp.id);if(!own)return;if(box.firstElementChild!==own)box.insertBefore(own,box.firstElementChild);const remove=own.querySelector('.tk-remove');if(remove){remove.textContent='Foreman';remove.disabled=true;remove.classList.remove('danger');remove.classList.add('secondary');}}

  function enhanceRow(row){
    if(row.dataset.tkLaunchDetails==='1'){renderEquipmentSelect(row);applyDefaultEquipment(row,false);return;}
    row.dataset.tkLaunchDetails='1';
    const detail=document.createElement('div');detail.className='tk-detail-row';
    detail.innerHTML=`<label>Start (24 hr)<input class="tk-start tk-clock24" type="text" inputmode="numeric" maxlength="5" value="" aria-label="Start time in 24-hour format"></label><label>Stop (24 hr)<input class="tk-stop tk-clock24" type="text" inputmode="numeric" maxlength="5" value="" aria-label="Stop time in 24-hour format"></label><label>Lunch (min)<input class="tk-lunch" type="number" min="0" max="720" step="5" value="0"></label><label>Truck / Equipment<select class="tk-equipment"></select></label><label class="tk-detail-check"><input class="tk-equipment-not-used" type="checkbox"> Not used today</label><label class="tk-detail-check"><input class="tk-per-diem" type="checkbox" checked> Per diem</label><div class="tk-hours-worked">Worked: —</div>`;
    row.appendChild(detail);
    row.querySelectorAll('.tk-start,.tk-stop').forEach(el=>{el.addEventListener('blur',()=>{normalizeClock(el);syncPayrollFromClock(row);});el.addEventListener('input',()=>syncPayrollFromClock(row));});
    row.querySelector('.tk-lunch')?.addEventListener('input',()=>syncPayrollFromClock(row));
    row.querySelector('.tk-employee')?.addEventListener('change',()=>{renderEquipmentSelect(row);applyDefaultEquipment(row,true);setTimeout(sortForemanFirst,0);});
    row.querySelector('.tk-equipment-not-used')?.addEventListener('change',()=>applyDefaultEquipment(row,false));
    renderEquipmentSelect(row);applyDefaultEquipment(row,true);
  }
  function collectDetails(){const out=[];document.querySelectorAll('#dailyCrewTimeRows .tk-crew-row').forEach(row=>{const employee_id=row.querySelector('.tk-employee')?.value||'';if(!employee_id)return;const st=row.querySelector('.tk-start'),sp=row.querySelector('.tk-stop');if(st)normalizeClock(st);if(sp)normalizeClock(sp);out.push({employee_id,start_time:st?.value||null,stop_time:sp?.value||null,lunch_minutes:Math.max(0,Math.min(720,Math.round(num(row.querySelector('.tk-lunch')?.value)))),per_diem:!!row.querySelector('.tk-per-diem')?.checked,equipment_used:row.querySelector('.tk-equipment')?.value||null,equipment_not_used:!!row.querySelector('.tk-equipment-not-used')?.checked});});return out;}
  async function saveDetails(reportId){if(!reportId)return;for(const item of collectDetails()){const payload={start_time:item.start_time,stop_time:item.stop_time,lunch_minutes:item.lunch_minutes,per_diem:item.per_diem,equipment_used:item.equipment_not_used?null:item.equipment_used,equipment_not_used:item.equipment_not_used,updated_at:new Date().toISOString()};const {error}=await getSb().from('timekeeping_entries').update(payload).eq('daily_report_id',reportId).eq('employee_id',item.employee_id).eq('company_id',companyId());if(error)throw error;}}
  function installSaveWrapper(){const current=window.saveDailyReportCrewTime;if(typeof current!=='function'||current===wrappedSave||current.__lcLaunchWrapped)return;const original=current,wrapper=async reportId=>{document.querySelectorAll('#dailyCrewTimeRows .tk-crew-row').forEach(syncPayrollFromClock);await original(reportId);await saveDetails(reportId);};wrapper.__lcLaunchWrapped=true;wrapper.__lcOriginal=original;wrappedSave=wrapper;window.saveDailyReportCrewTime=wrapper;}
  async function loadExistingDetails(){
    const form=byId('dailyReportForm');if(!form||form.classList.contains('hidden')){loadedReport='';return;}
    const reportId=form.dataset.reportId||'';if(!reportId||reportId===loadedReport)return;
    ensureForemanRow();
    const rows=[...document.querySelectorAll('#dailyCrewTimeRows .tk-crew-row')];if(!rows.length)return;
    const {data,error}=await getSb().from('timekeeping_entries').select('employee_id,start_time,stop_time,lunch_minutes,per_diem,equipment_used,equipment_not_used').eq('daily_report_id',reportId).eq('company_id',companyId());if(error)return;
    const map=new Map((data||[]).map(x=>[x.employee_id,x]));
    rows.forEach(row=>{
      enhanceRow(row);
      const employeeId=row.querySelector('.tk-employee')?.value||'';
      const item=map.get(employeeId);
      renderEquipmentSelect(row);
      if(!item){applyDefaultEquipment(row,true);return;}
      row.querySelector('.tk-start').value=(item.start_time||'').slice(0,5);
      row.querySelector('.tk-stop').value=(item.stop_time||'').slice(0,5);
      row.querySelector('.tk-lunch').value=item.lunch_minutes||0;
      row.querySelector('.tk-per-diem').checked=!!item.per_diem;
      row.querySelector('.tk-equipment-not-used').checked=!!item.equipment_not_used;
      const savedDaily=item.equipment_used||'';
      if(savedDaily)row.querySelector('.tk-equipment').value=savedDaily;
      else applyDefaultEquipment(row,true);
      applyDefaultEquipment(row,false);
      syncPayrollFromClock(row);
    });
    loadedReport=reportId;sortForemanFirst();
  }
  function updateHelp(){const p=byId('dailyCrewTimeCard')?.querySelector('.tk-help');if(p&&!p.dataset.tkLaunchHelp){p.dataset.tkLaunchHelp='1';p.textContent='Your Foreman row appears first, followed by the assigned crew. Assigned equipment fills in automatically; change the dropdown only when someone uses a different unit that day. Enter Start and Stop in 24-hour time plus Lunch; LineCrew calculates hours for payroll. Per diem defaults on.';}}
  function scan(){addStyles();installSaveWrapper();installEquipmentManager();updateHelp();ensureForemanRow();document.querySelectorAll('#dailyCrewTimeRows .tk-crew-row').forEach(enhanceRow);loadExistingDetails();sortForemanFirst();}
  function init(){
    addStyles();
    scan();
    refreshData().then(ok=>{if(ok)scan();});
    let timer;
    new MutationObserver(()=>{clearTimeout(timer);timer=setTimeout(scan,50);}).observe(document.body,{subtree:true,childList:true,attributes:true,attributeFilter:['class']});
    setInterval(()=>{installSaveWrapper();ensureDataLoaded();},1000);
    setInterval(()=>{const form=byId('dailyReportForm');if(form&&!form.classList.contains('hidden'))sortForemanFirst();},250);
    ensureDataLoaded();
  }
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',init);else init();
})();