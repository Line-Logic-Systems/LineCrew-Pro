/* LineCrew Pro - complete Timekeeping reporting, including preserved split-day segments */
(() => {
  'use strict';
  const byId=id=>document.getElementById(id);
  const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const num=v=>Number(v||0)||0;
  const getSb=()=>{try{return typeof sb!=='undefined'?sb:(window.sb||window.supabaseClient||null);}catch(_){return window.sb||window.supabaseClient||null;}};
  const profile=()=>typeof currentProfile!=='undefined'?currentProfile:window.currentProfile;
  const role=()=>String(profile()?.role||'').toLowerCase();
  const canEditTime=()=>['owner','admin'].includes(role());
  let rows=[];
  let employees=new Map();
  let jobs=new Map();
  let reportRunInFlight=null;

  function toast(message,type='info'){ window.LineCrewUI?.toast?.(message,type); }

  function addStyles(){
    if(byId('tkReportV2Styles'))return;
    const style=document.createElement('style');
    style.id='tkReportV2Styles';
    style.textContent=`
      .tk-report-toolbar{display:flex;gap:6px;flex-wrap:wrap;align-items:center;margin:6px 0 8px}
      .tk-report-toolbar button{width:auto;margin:0;padding:6px 9px;font-size:12px}
      #tkSummary{display:flex!important;align-items:center;gap:0!important;flex-wrap:wrap;margin:6px 0 8px!important;padding:0!important;background:#f8fafc;border:1px solid #dce5ed;border-radius:9px;overflow:hidden}
      #tkSummary>div{display:flex!important;align-items:baseline;gap:4px;min-width:0!important;width:auto!important;flex:0 0 auto!important;padding:5px 9px!important;margin:0!important;border:0!important;border-right:1px solid #dce5ed!important;border-radius:0!important;background:transparent!important;box-shadow:none!important;font-size:10px!important;white-space:nowrap}
      #tkSummary>div:last-child{border-right:0!important}
      #tkSummary>div strong{font-size:13px!important;line-height:1!important;margin:0!important}
      @media(max-width:520px){#tkSummary>div{padding:5px 6px!important;font-size:9px!important}#tkSummary>div strong{font-size:12px!important}}
      .tk-employee-summary{border-bottom:1px solid #dce5ed;background:#fff;margin:0;overflow:hidden}
      .tk-employee-summary:first-of-type{border-top:1px solid #dce5ed}
      .tk-employee-summary>summary{cursor:pointer;list-style:none;padding:5px 7px;display:grid;grid-template-columns:18px minmax(150px,1.7fr) repeat(4,minmax(62px,.65fr));gap:5px;align-items:center;min-height:30px}
      .tk-employee-summary>summary::-webkit-details-marker{display:none}
      .tk-employee-toggle{font-size:10px;color:#1677d2;text-align:center}
      .tk-employee-summary[open] .tk-employee-toggle{transform:rotate(90deg)}
      .tk-employee-name{display:flex;align-items:center;gap:5px;min-width:0;font-weight:800;font-size:12px}
      .tk-employee-meta{font-size:10px;color:#617284;font-weight:400;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
      .tk-employee-metric{text-align:right;font-variant-numeric:tabular-nums;line-height:1}
      .tk-employee-metric strong{display:inline;color:#0b2d4d;font-size:12px}
      .tk-employee-metric span{display:block;color:#617284;font-size:8px;text-transform:uppercase;margin-top:2px}
      .tk-employee-detail{padding:6px;background:#f8fafc;border-top:1px solid #dce5ed}
      .tk-employee-detail .tk-table{min-width:980px;background:#fff;font-size:11px}
      .tk-employee-detail .tk-table th,.tk-employee-detail .tk-table td{padding:5px 6px}
      .tk-per-diem-yes{font-weight:800}
      .tk-edit-time-btn{width:auto!important;margin:0!important;padding:4px 7px!important;font-size:10px!important}
      .tk-edit-backdrop{position:fixed;inset:0;background:rgba(6,20,34,.6);z-index:80;display:flex;align-items:center;justify-content:center;padding:16px}
      .tk-edit-card{background:#fff;border-radius:16px;box-shadow:0 18px 48px rgba(0,0,0,.28);width:min(720px,100%);max-height:92vh;overflow:auto;padding:16px}
      .tk-edit-grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:8px}
      .tk-edit-grid label{margin:0;font-size:11px}
      .tk-edit-grid input{padding:8px;font-size:13px}
      .tk-edit-wide{grid-column:1/-1}
      .tk-edit-checks{display:flex;gap:16px;align-items:center;flex-wrap:wrap;margin:10px 0}
      .tk-edit-checks label{display:flex;align-items:center;gap:6px;margin:0;font-size:12px}
      .tk-edit-checks input{width:auto}
      .tk-edit-actions{display:flex;gap:8px;justify-content:flex-end}
      .tk-edit-actions button{width:auto;margin-top:8px}
      @media(max-width:760px){
        .tk-employee-summary>summary{grid-template-columns:16px minmax(120px,1fr) repeat(2,58px);padding:5px}
        .tk-employee-metric:nth-of-type(3),.tk-employee-metric:nth-of-type(5){display:none}
        .tk-employee-meta{display:none}
        .tk-edit-grid{grid-template-columns:repeat(2,minmax(0,1fr))}
      }
    `;
    document.head.appendChild(style);
  }

  async function refs(){
    const companyId=profile()?.company_id;
    const client=getSb();
    if(!companyId||!client) return;
    const [{data:e,error:ee},{data:j,error:je}]=await Promise.all([
      client.from('timekeeping_employees').select('id,employee_number,full_name,classification,default_crew_name,default_equipment,active').eq('company_id',companyId),
      client.from('jobs').select('id,job_number,job_name').eq('company_id',companyId)
    ]);
    if(ee) throw ee;
    if(je) throw je;
    employees=new Map((e||[]).map(x=>[x.id,x]));
    jobs=new Map((j||[]).map(x=>[x.id,x]));
  }

  function filteredRows(){
    const crew=(byId('tkCrewFilter')?.value||'').trim().toLowerCase();
    if(!crew) return [...rows];
    return rows.filter(row=>String(row.crew_name||employees.get(row.employee_id)?.default_crew_name||'').trim().toLowerCase()===crew);
  }

  function populateCrewFilter(){
    const select=byId('tkCrewFilter');
    if(!select) return;
    const current=select.value;
    const crews=new Set();
    employees.forEach(e=>{if(e.active!==false&&e.default_crew_name)crews.add(String(e.default_crew_name).trim());});
    rows.forEach(r=>{if(r.crew_name)crews.add(String(r.crew_name).trim());});
    select.innerHTML='<option value="">All crews</option>'+[...crews].filter(Boolean).sort((a,b)=>a.localeCompare(b)).map(c=>`<option value="${esc(c)}">${esc(c)}</option>`).join('');
    if([...select.options].some(o=>o.value===current)) select.value=current;
  }

  async function run(){
    if(reportRunInFlight) return reportRunInFlight;
    reportRunInFlight=runOnce();
    try{return await reportRunInFlight;}
    finally{reportRunInFlight=null;}
  }

  async function runOnce(){
    const box=byId('tkReportList');
    const client=getSb();
    if(!box||!client) return;
    const btn=byId('tkRunReportBtn');
    const done=window.LineCrewUI?.loadingButton?.(btn,'Running…')||(()=>{});
    try{
      await refs();
      const from=byId('tkFromDate')?.value;
      const through=byId('tkThroughDate')?.value;
      if(!from||!through) return;
      const emp=byId('tkEmployeeFilter')?.value||null;
      const job=byId('tkJobFilter')?.value||null;
      const {data,error}=await client.rpc('timekeeping_report_rows_v3',{p_from:from,p_through:through,p_employee:emp,p_job:job});
      if(error) throw error;
      rows=data||[];
      populateCrewFilter();
      render();
      document.dispatchEvent(new CustomEvent('linecrew:timekeeping-report',{detail:{rows:filteredRows()}}));
    }catch(error){
      toast('Could not load complete Timekeeping report: '+error.message,'error');
    }finally{done();}
  }

  function timeText(value){return value?String(value).slice(0,5):'';}
  function equipmentText(row,e){return row.equipment_not_used?'Not used':(row.equipment_used||e.default_equipment||'');}
  function employeeGroups(view){
    const grouped=new Map();
    view.forEach(row=>{
      if(!grouped.has(row.employee_id))grouped.set(row.employee_id,[]);
      grouped.get(row.employee_id).push(row);
    });
    return [...grouped.entries()].sort((a,b)=>String(employees.get(a[0])?.full_name||'').localeCompare(String(employees.get(b[0])?.full_name||'')));
  }

  function openTimeEditor(row){
    if(!canEditTime()||row.entry_kind==='leadership_self')return;
    byId('tkEditBackdrop')?.remove();
    const e=employees.get(row.employee_id)||{};
    const j=jobs.get(row.job_id)||{};
    const wrap=document.createElement('div');
    wrap.id='tkEditBackdrop';
    wrap.className='tk-edit-backdrop';
    wrap.innerHTML=`<div class="tk-edit-card">
      <h3>Edit Submitted Time</h3>
      <p class="muted">${esc(e.full_name||'Employee')} · ${esc(row.work_date||'')} · ${esc(j.job_number||row.labor_code||'')}</p>
      <div class="tk-edit-grid">
        <label>Start (24 hr)<input id="tkEditStart" type="text" inputmode="numeric" maxlength="5" placeholder="HH:MM" autocomplete="off" value="${esc(timeText(row.start_time))}"></label>
        <label>Stop (24 hr)<input id="tkEditStop" type="text" inputmode="numeric" maxlength="5" placeholder="HH:MM" autocomplete="off" value="${esc(timeText(row.stop_time))}"></label>
        <label>Lunch (min)<input id="tkEditLunch" type="number" min="0" max="720" step="1" value="${num(row.lunch_minutes)}"></label>
        <label>Equipment<input id="tkEditEquipment" type="text" value="${esc(row.equipment_used||'')}"></label>
        <label>Worked Hours<input id="tkEditWorked" type="text" readonly value="${(num(row.regular_hours)+num(row.overtime_hours)).toFixed(2)}"></label>
        <div class="tk-help">Regular and OT are calculated automatically from the employee's configured workweek.</div>
        <label class="tk-edit-wide">Reason for correction<input id="tkEditReason" type="text" placeholder="Required for audit trail"></label>
      </div>
      <div class="tk-edit-checks">
        <label><input id="tkEditPerDiem" type="checkbox" ${row.per_diem?'checked':''}> Per diem</label>
        <label><input id="tkEditEquipmentNotUsed" type="checkbox" ${row.equipment_not_used?'checked':''}> Equipment not used</label>
      </div>
      <p class="tk-help">The original Daily Report remains submitted/approved. Worked Hours are derived from Start, Stop and Lunch. Regular/OT are recalculated across the employee's full configured workweek. The original Daily Report remains submitted/approved, and the correction audit records who changed it, when, why, and the before/after values.</p>
      <div class="tk-edit-actions"><button id="tkEditCancel" type="button" class="secondary">Cancel</button><button id="tkEditSave" type="button" class="success">Save Correction</button></div>
    </div>`;
    document.body.appendChild(wrap);
    byId('tkEditCancel').onclick=()=>wrap.remove();
    wrap.addEventListener('click',ev=>{if(ev.target===wrap)wrap.remove();});
    const calculateWorked=()=>{
      const start=(byId('tkEditStart')?.value||'').trim();
      const stop=(byId('tkEditStop')?.value||'').trim();
      const lunch=Math.round(num(byId('tkEditLunch')?.value));
      const military=/^(?:[01]\d|2[0-3]):[0-5]\d$/;
      if(!military.test(start)||!military.test(stop)){byId('tkEditWorked').value='—';return null;}
      const toMinutes=value=>{const [h,m]=value.split(':').map(Number);return h*60+m;};
      let elapsed=toMinutes(stop)-toMinutes(start);
      if(elapsed<0)elapsed+=1440;
      const worked=(elapsed-lunch)/60;
      if(worked<0||worked>24){byId('tkEditWorked').value='—';return null;}
      byId('tkEditWorked').value=worked.toFixed(2);
      return worked;
    };
    ['tkEditStart','tkEditStop','tkEditLunch'].forEach(id=>byId(id)?.addEventListener('input',calculateWorked));
    calculateWorked();
    byId('tkEditSave').onclick=async()=>{
      const reason=(byId('tkEditReason')?.value||'').trim();
      if(!reason){toast('Enter a reason for the time correction.','warning');byId('tkEditReason')?.focus();return;}
      const start=(byId('tkEditStart')?.value||'').trim();
      const stop=(byId('tkEditStop')?.value||'').trim();
      const military=/^(?:[01]\d|2[0-3]):[0-5]\d$/;
      if(start&&!military.test(start)){toast('Start time must use 24-hour HH:MM, for example 06:30 or 17:00.','warning');byId('tkEditStart')?.focus();return;}
      if(stop&&!military.test(stop)){toast('Stop time must use 24-hour HH:MM, for example 06:30 or 17:00.','warning');byId('tkEditStop')?.focus();return;}
      const lunch=Math.round(num(byId('tkEditLunch')?.value));
      if(lunch<0||lunch>720){toast('Lunch must be between 0 and 720 minutes.','warning');return;}
      const worked=calculateWorked();
      if(worked===null){toast('Start, Stop and Lunch must produce a valid shift between 0 and 24 hours.','warning');return;}
      const btn=byId('tkEditSave');
      const done=window.LineCrewUI?.loadingButton?.(btn,'Saving…')||(()=>{});
      try{
        const {error}=await getSb().rpc('admin_update_timekeeping_entry',{
          p_daily_report_id:row.daily_report_id,
          p_employee_id:row.employee_id,
          p_start_time:start||null,
          p_stop_time:stop||null,
          p_lunch_minutes:lunch,
          p_regular_hours:worked,
          p_overtime_hours:0,
          p_per_diem:!!byId('tkEditPerDiem')?.checked,
          p_equipment_used:(byId('tkEditEquipment')?.value||'').trim()||null,
          p_equipment_not_used:!!byId('tkEditEquipmentNotUsed')?.checked,
          p_reason:reason
        });
        if(error)throw error;
        wrap.remove();
        toast('Submitted time corrected and audit history saved.','success');
        await run();
      }catch(error){toast('Could not update submitted time: '+error.message,'error');}
      finally{done();}
    };
  }

  function detailRows(group){
    return [...group].sort((a,b)=>String(b.work_date||'').localeCompare(String(a.work_date||''))).map((r,index)=>{
      const e=employees.get(r.employee_id)||{};
      const j=jobs.get(r.job_id)||{};
      const charge=j.job_number||r.labor_code||'';
      const editCell=canEditTime()?(r.entry_kind==='leadership_self'?'<td></td>':`<td><button type="button" class="secondary tk-edit-time-btn" data-tk-edit-row="${index}">Edit</button></td>`):'';
      return `<tr><td>${esc(r.work_date)}</td><td>${esc(charge)}</td><td>${esc(r.crew_name||e.default_crew_name||'')}</td><td>${esc(timeText(r.start_time))}</td><td>${esc(timeText(r.stop_time))}</td><td>${num(r.lunch_minutes)}</td><td>${num(r.regular_hours).toFixed(2)}</td><td>${num(r.overtime_hours).toFixed(2)}</td><td>${(num(r.regular_hours)+num(r.overtime_hours)).toFixed(2)}</td><td class="${r.per_diem?'tk-per-diem-yes':''}">${r.per_diem?'Yes':'No'}</td><td>${esc(equipmentText(r,e))}</td><td>${r.storm_work?'Yes':'No'}</td>${editCell}</tr>`;
    }).join('');
  }

  function render(){
    addStyles();
    const view=filteredRows();
    const reg=view.reduce((s,r)=>s+num(r.regular_hours),0);
    const ot=view.reduce((s,r)=>s+num(r.overtime_hours),0);
    const count=new Set(view.map(r=>r.employee_id)).size;
    const perDiem=new Set(view.filter(r=>r.per_diem).map(r=>`${r.employee_id}|${r.work_date}`)).size;
    const sum=byId('tkSummary');
    if(sum)sum.innerHTML=`<div><strong>${count}</strong>Employees</div><div><strong>${reg.toFixed(2)}</strong>Regular Hours</div><div><strong>${ot.toFixed(2)}</strong>OT Hours</div><div><strong>${(reg+ot).toFixed(2)}</strong>Total Hours</div><div><strong>${perDiem}</strong>Per Diem Days</div>`;
    const box=byId('tkReportList');
    if(!box)return;
    if(!view.length){box.innerHTML='<div class="tk-crew-card"><strong>No time recorded for this view.</strong><p class="tk-help">Create or save a Daily Report with crew time, or change the filters.</p></div>';return;}
    const groups=employeeGroups(view);
    box.innerHTML=`<div class="tk-report-toolbar"><span class="muted">${groups.length} employees · click a row for daily detail${canEditTime()?' and corrections':''}.</span><button id="tkExpandEmployees" class="secondary small" type="button">Expand All</button><button id="tkCollapseEmployees" class="secondary small" type="button">Collapse All</button></div>`+
      groups.map(([employeeId,group],groupIndex)=>{
        const e=employees.get(employeeId)||{};
        const er=group.reduce((s,r)=>s+num(r.regular_hours),0);
        const eo=group.reduce((s,r)=>s+num(r.overtime_hours),0);
        const epd=new Set(group.filter(r=>r.per_diem).map(r=>r.work_date)).size;
        const crew=[...new Set(group.map(r=>r.crew_name||e.default_crew_name||'').filter(Boolean))].join(', ');
        const meta=[e.classification||'',crew].filter(Boolean).join(' · ');
        return `<details class="tk-employee-summary" data-tk-group="${groupIndex}"><summary><span class="tk-employee-toggle">▶</span><span class="tk-employee-name"><span>${esc(e.full_name||'Employee')}</span>${meta?`<span class="tk-employee-meta">${esc(meta)}</span>`:''}</span><span class="tk-employee-metric"><strong>${er.toFixed(2)}</strong><span>Regular</span></span><span class="tk-employee-metric"><strong>${eo.toFixed(2)}</strong><span>OT</span></span><span class="tk-employee-metric"><strong>${(er+eo).toFixed(2)}</strong><span>Total</span></span><span class="tk-employee-metric"><strong>${epd}</strong><span>Per Diem</span></span></summary><div class="tk-employee-detail"><div class="tk-table-wrap"><table class="tk-table"><thead><tr><th>Date</th><th>Job / Labor Code</th><th>Crew</th><th>Start</th><th>Stop</th><th>Lunch</th><th>Regular</th><th>OT</th><th>Total</th><th>Per Diem</th><th>Equipment</th><th>Storm</th>${canEditTime()?'<th></th>':''}</tr></thead><tbody>${detailRows(group)}</tbody></table></div></div></details>`;
      }).join('');
    byId('tkExpandEmployees').onclick=()=>box.querySelectorAll('.tk-employee-summary').forEach(detail=>detail.open=true);
    byId('tkCollapseEmployees').onclick=()=>box.querySelectorAll('.tk-employee-summary').forEach(detail=>detail.open=false);
    if(canEditTime()){
      box.querySelectorAll('.tk-employee-summary').forEach((details,groupIndex)=>{
        const group=groups[groupIndex]?.[1]||[];
        const sorted=[...group].sort((a,b)=>String(b.work_date||'').localeCompare(String(a.work_date||'')));
        details.querySelectorAll('[data-tk-edit-row]').forEach(btn=>btn.onclick=()=>openTimeEditor(sorted[Number(btn.dataset.tkEditRow)]));
      });
    }
  }

  function csvCell(value){let s=String(value??'');if(typeof value==='string'&&(/^[\t\r\n]/.test(s)||/^\s*[=+\-@]/.test(s)))s="'"+s;return /[",\n]/.test(s)?'"'+s.replace(/"/g,'""')+'"':s;}

  function exportCsv(){
    const view=filteredRows();
    if(!view.length){toast('Run the Timekeeping report before exporting.','warning');return;}
    const out=[['Employee #','Employee','Classification','Date','Job #','Job Name','Crew','Start','Stop','Lunch Minutes','Regular Hours','OT Hours','Total Hours','Per Diem','Equipment','Storm']];
    view.forEach(r=>{
      const e=employees.get(r.employee_id)||{};
      const j=jobs.get(r.job_id)||{};
      out.push([e.employee_number||'',e.full_name||'',e.classification||'',r.work_date||'',j.job_number||r.labor_code||'',j.job_name||(r.labor_code?'Overhead':''),r.crew_name||e.default_crew_name||'',timeText(r.start_time),timeText(r.stop_time),num(r.lunch_minutes),num(r.regular_hours).toFixed(2),num(r.overtime_hours).toFixed(2),(num(r.regular_hours)+num(r.overtime_hours)).toFixed(2),r.per_diem?'Yes':'No',equipmentText(r,e),r.storm_work?'Yes':'No']);
    });
    const blob=new Blob([out.map(x=>x.map(csvCell).join(',')).join('\n')],{type:'text/csv;charset=utf-8'});
    const url=URL.createObjectURL(blob),a=document.createElement('a');
    a.href=url;a.download=`linecrew-timekeeping-${byId('tkFromDate')?.value||''}-to-${byId('tkThroughDate')?.value||''}.csv`;
    document.body.appendChild(a);a.click();a.remove();URL.revokeObjectURL(url);
    toast('Timekeeping CSV exported.','success');
  }

  function loadLaunchInput(){
    if(document.querySelector('script[data-linecrew-timekeeping-input-v2]'))return;
    const script=document.createElement('script');
    script.src='timekeeping-input-v2.js?v=20260826b';
    script.dataset.linecrewTimekeepingInputV2='1';
    document.head.appendChild(script);
  }

  window.LineCrewTimekeepingReport={run,render,getRows:()=>filteredRows(),getAllRows:()=>[...rows],getEmployees:()=>new Map(employees),getJobs:()=>new Map(jobs),refreshRefs:refs};

  document.addEventListener('change',e=>{
    if(e.target?.id==='tkCrewFilter'){
      render();
      document.dispatchEvent(new CustomEvent('linecrew:timekeeping-report',{detail:{rows:filteredRows()}}));
    }
  });

  document.addEventListener('click',e=>{
    const id=e.target?.id;
    if(id==='tkRunReportBtn'){e.preventDefault();e.stopImmediatePropagation();run();}
    if(id==='tkExportCsvBtn'){e.preventDefault();e.stopImmediatePropagation();exportCsv();}
  },true);

  let last='';
  new MutationObserver(()=>{
    const p=byId('timekeepingPage');
    if(p&&!p.classList.contains('hidden')){
      const key=(byId('tkFromDate')?.value||'')+'|'+(byId('tkThroughDate')?.value||'');
      if(key&&key!==last){last=key;setTimeout(run,80);}
    }else last='';
  }).observe(document.body,{subtree:true,childList:true,attributes:true,attributeFilter:['class']});

  addStyles();
  loadLaunchInput();
})();
