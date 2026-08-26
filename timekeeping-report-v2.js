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

  function render(){
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
    box.innerHTML=`<div class="tk-table-wrap"><table class="tk-table"><thead><tr><th>Date</th><th>Employee</th><th>Class</th><th>Job</th><th>Crew</th><th>Start</th><th>Stop</th><th>Lunch</th><th>Regular</th><th>OT</th><th>Total</th><th>Per Diem</th><th>Equipment</th><th>Storm</th></tr></thead><tbody>${view.map(r=>{
      const e=employees.get(r.employee_id)||{};
      const j=jobs.get(r.job_id)||{};
      return `<tr><td>${esc(r.work_date)}</td><td><strong>${esc(e.full_name||'')}</strong></td><td>${esc(e.classification||'')}</td><td>${esc(j.job_number||'')}</td><td>${esc(r.crew_name||e.default_crew_name||'')}</td><td>${esc(timeText(r.start_time))}</td><td>${esc(timeText(r.stop_time))}</td><td>${num(r.lunch_minutes)}</td><td>${num(r.regular_hours).toFixed(2)}</td><td>${num(r.overtime_hours).toFixed(2)}</td><td>${(num(r.regular_hours)+num(r.overtime_hours)).toFixed(2)}</td><td>${r.per_diem?'Yes':'No'}</td><td>${esc(equipmentText(r,e))}</td><td>${r.storm_work?'Yes':'No'}</td></tr>`;
    }).join('')}</tbody></table></div>`;
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
    script.src='timekeeping-input-v2.js?v=20260826';
    script.dataset.linecrewTimekeepingInputV2='1';
    document.head.appendChild(script);
  }

  window.LineCrewTimekeepingReport={
    run,
    render,
    getRows:()=>filteredRows(),
    getAllRows:()=>[...rows],
    getEmployees:()=>new Map(employees),
    getJobs:()=>new Map(jobs),
    refreshRefs:refs
  };

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

  loadLaunchInput();
})();
