/* LineCrew Pro - complete Timekeeping reporting, including preserved split-day segments */
(() => {
  'use strict';
  const byId=id=>document.getElementById(id);
  const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const num=v=>Number(v||0)||0;
  const getSb=()=>{try{return typeof sb!=='undefined'?sb:(window.sb||window.supabaseClient||null);}catch(_){return window.sb||window.supabaseClient||null;}};
  const profile=()=>typeof currentProfile!=='undefined'?currentProfile:window.currentProfile;
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
      .tk-report-toolbar{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin:8px 0 12px}
      .tk-report-toolbar button{width:auto;margin:0;padding:8px 12px}
      .tk-employee-summary{border:1px solid #dce5ed;border-radius:12px;background:#fff;margin:8px 0;overflow:hidden}
      .tk-employee-summary>summary{cursor:pointer;list-style:none;padding:11px 12px;display:grid;grid-template-columns:minmax(150px,1.7fr) repeat(4,minmax(74px,.75fr));gap:8px;align-items:center}
      .tk-employee-summary>summary::-webkit-details-marker{display:none}
      .tk-employee-summary>summary:before{content:'▸';font-size:12px;margin-right:4px}
      .tk-employee-summary[open]>summary:before{content:'▾'}
      .tk-employee-name{display:flex;align-items:center;gap:4px;min-width:0;font-weight:800}
      .tk-employee-meta{font-size:12px;color:#617284;font-weight:400;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
      .tk-employee-metric{text-align:right;font-variant-numeric:tabular-nums}
      .tk-employee-metric strong{display:block;color:#0b2d4d;font-size:14px}
      .tk-employee-metric span{display:block;color:#617284;font-size:10px;text-transform:uppercase}
      .tk-employee-detail{padding:0 12px 12px;background:#f8fafc;border-top:1px solid #dce5ed}
      .tk-employee-detail .tk-table{min-width:980px;background:#fff}
      .tk-per-diem-yes{font-weight:800}
      @media(max-width:760px){
        .tk-employee-summary>summary{grid-template-columns:1fr 1fr 1fr;padding:10px}
        .tk-employee-name{grid-column:1/-1}
        .tk-employee-metric{text-align:left}
        .tk-employee-summary>summary .tk-employee-metric:last-child{grid-column:3}
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
      const {data,error}=await client.rpc('timekeeping_report_rows_v2',{p_from:from,p_through:through,p_employee:emp,p_job:job});
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
  function detailRows(group){
    return [...group].sort((a,b)=>String(b.work_date||'').localeCompare(String(a.work_date||''))).map(r=>{
      const e=employees.get(r.employee_id)||{};
      const j=jobs.get(r.job_id)||{};
      return `<tr><td>${esc(r.work_date)}</td><td>${esc(j.job_number||'')}</td><td>${esc(r.crew_name||e.default_crew_name||'')}</td><td>${esc(timeText(r.start_time))}</td><td>${esc(timeText(r.stop_time))}</td><td>${num(r.lunch_minutes)}</td><td>${num(r.regular_hours).toFixed(2)}</td><td>${num(r.overtime_hours).toFixed(2)}</td><td>${(num(r.regular_hours)+num(r.overtime_hours)).toFixed(2)}</td><td class="${r.per_diem?'tk-per-diem-yes':''}">${r.per_diem?'Yes':'No'}</td><td>${esc(equipmentText(r,e))}</td><td>${r.storm_work?'Yes':'No'}</td></tr>`;
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
    box.innerHTML=`<div class="tk-report-toolbar"><span class="muted">${view.length} time segment${view.length===1?'':'s'} grouped into ${groups.length} employee${groups.length===1?'':'s'}.</span><button id="tkExpandEmployees" class="secondary small" type="button">Expand All</button><button id="tkCollapseEmployees" class="secondary small" type="button">Collapse All</button></div>`+
      groups.map(([employeeId,group])=>{
        const e=employees.get(employeeId)||{};
        const er=group.reduce((s,r)=>s+num(r.regular_hours),0);
        const eo=group.reduce((s,r)=>s+num(r.overtime_hours),0);
        const epd=new Set(group.filter(r=>r.per_diem).map(r=>r.work_date)).size;
        const crew=[...new Set(group.map(r=>r.crew_name||e.default_crew_name||'').filter(Boolean))].join(', ');
        const meta=[e.classification||'',crew].filter(Boolean).join(' · ');
        return `<details class="tk-employee-summary"><summary><span class="tk-employee-name"><span>${esc(e.full_name||'Employee')}</span>${meta?`<span class="tk-employee-meta">${esc(meta)}</span>`:''}</span><span class="tk-employee-metric"><strong>${er.toFixed(2)}</strong><span>Regular</span></span><span class="tk-employee-metric"><strong>${eo.toFixed(2)}</strong><span>OT</span></span><span class="tk-employee-metric"><strong>${(er+eo).toFixed(2)}</strong><span>Total</span></span><span class="tk-employee-metric"><strong>${epd}</strong><span>Per Diem</span></span></summary><div class="tk-employee-detail"><div class="tk-table-wrap"><table class="tk-table"><thead><tr><th>Date</th><th>Job</th><th>Crew</th><th>Start</th><th>Stop</th><th>Lunch</th><th>Regular</th><th>OT</th><th>Total</th><th>Per Diem</th><th>Equipment</th><th>Storm</th></tr></thead><tbody>${detailRows(group)}</tbody></table></div></div></details>`;
      }).join('');
    byId('tkExpandEmployees').onclick=()=>box.querySelectorAll('.tk-employee-summary').forEach(detail=>detail.open=true);
    byId('tkCollapseEmployees').onclick=()=>box.querySelectorAll('.tk-employee-summary').forEach(detail=>detail.open=false);
  }

  function csvCell(value){let s=String(value??'');if(typeof value==='string'&&(/^[\t\r\n]/.test(s)||/^\s*[=+\-@]/.test(s)))s="'"+s;return /[",\n]/.test(s)?'"'+s.replace(/"/g,'""')+'"':s;}

  function exportCsv(){
    const view=filteredRows();
    if(!view.length){toast('Run the Timekeeping report before exporting.','warning');return;}
    const out=[['Employee #','Employee','Classification','Date','Job #','Job Name','Crew','Start','Stop','Lunch Minutes','Regular Hours','OT Hours','Total Hours','Per Diem','Equipment','Storm']];
    view.forEach(r=>{
      const e=employees.get(r.employee_id)||{};
      const j=jobs.get(r.job_id)||{};
      out.push([e.employee_number||'',e.full_name||'',e.classification||'',r.work_date||'',j.job_number||'',j.job_name||'',r.crew_name||e.default_crew_name||'',timeText(r.start_time),timeText(r.stop_time),num(r.lunch_minutes),num(r.regular_hours).toFixed(2),num(r.overtime_hours).toFixed(2),(num(r.regular_hours)+num(r.overtime_hours)).toFixed(2),r.per_diem?'Yes':'No',equipmentText(r,e),r.storm_work?'Yes':'No']);
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
