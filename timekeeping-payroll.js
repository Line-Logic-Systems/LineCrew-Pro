/* LineCrew Pro - weekly timesheet exports, approvals, locks and exception review */
(() => {
  'use strict';
  const byId=id=>document.getElementById(id);
  const num=v=>Number(v||0)||0;
  const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const profile=()=>typeof currentProfile!=='undefined'?currentProfile:window.currentProfile;
  const role=()=>String(profile()?.role||'').toLowerCase();
  const getSb=()=>{try{return typeof sb!=='undefined'?sb:(window.sb||window.supabaseClient||null);}catch(_){return window.sb||window.supabaseClient||null;}};
  const toast=(m,t='info')=>window.LineCrewUI?.toast?.(m,t)||console.log(m);
  let periodState={status:'open'};
  let exceptions=[];

  const iso=d=>`${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
  const parseDate=s=>{const [y,m,d]=String(s||'').split('-').map(Number);return new Date(y,m-1,d);};
  const dayLabel=s=>parseDate(s).toLocaleDateString(undefined,{weekday:'short',month:'numeric',day:'numeric'});

  function datesBetween(from,through){
    const out=[];let d=parseDate(from),end=parseDate(through);
    while(d<=end){out.push(iso(d));d=new Date(d.getFullYear(),d.getMonth(),d.getDate()+1);}
    return out;
  }

  function weekRange(offset=0){
    const now=new Date();const day=(now.getDay()+6)%7;
    const start=new Date(now.getFullYear(),now.getMonth(),now.getDate()-day+(offset*7));
    const end=new Date(start.getFullYear(),start.getMonth(),start.getDate()+6);
    return [iso(start),iso(end)];
  }

  function addStyles(){
    if(byId('tkPayrollStyles'))return;
    const s=document.createElement('style');s.id='tkPayrollStyles';s.textContent=`
      #timekeepingPage .tk-payroll-card{border:1px solid #dce5ed;background:#fbfdff}
      #timekeepingPage .tk-payroll-top{display:flex;justify-content:space-between;gap:12px;align-items:flex-start;flex-wrap:wrap}
      #timekeepingPage .tk-period-badge{display:inline-flex;align-items:center;border-radius:999px;padding:6px 10px;font-size:12px;font-weight:800;text-transform:uppercase;background:#e9f0f6;color:#0b2d4d}
      #timekeepingPage .tk-period-badge.approved{background:#e8f6ee;color:#167546}
      #timekeepingPage .tk-period-badge.locked{background:#fff1df;color:#8b4b08}
      #timekeepingPage .tk-payroll-actions{display:flex;gap:8px;flex-wrap:wrap;margin:10px 0}
      #timekeepingPage .tk-payroll-actions button{width:auto!important;margin:0!important}
      #timekeepingPage .tk-exception-list{display:grid;gap:8px;margin-top:10px}
      #timekeepingPage .tk-exception{border:1px solid #ead7b3;border-left:4px solid #d97706;background:#fffaf1;border-radius:10px;padding:9px 11px;font-size:13px}
      #timekeepingPage .tk-exception.high{border-left-color:#b83232;background:#fff6f6}
      #timekeepingPage .tk-export-note{font-size:12px;color:#687a8a;margin-top:8px}
      @media(max-width:720px){#timekeepingPage .tk-payroll-actions{display:grid;grid-template-columns:1fr 1fr}#timekeepingPage .tk-payroll-actions button{width:100%!important}}
      @media(max-width:420px){#timekeepingPage .tk-payroll-actions{grid-template-columns:1fr}}
    `;document.head.appendChild(s);
  }

  function installFilters(){
    const grid=byId('tkRunReportBtn')?.closest('.card')?.querySelector('.tk-grid');
    if(!grid)return;
    if(!byId('tkCrewFilter')){
      const label=document.createElement('label');label.innerHTML='Crew<select id="tkCrewFilter"><option value="">All crews</option></select>';grid.appendChild(label);
    }
    if(!byId('tkPayPeriodFilter')){
      const label=document.createElement('label');label.innerHTML='Pay Period<select id="tkPayPeriodFilter"><option value="week">This Week (Mon-Sun)</option><option value="last">Last Week</option><option value="custom">Custom Dates</option></select>';grid.appendChild(label);
      byId('tkPayPeriodFilter').addEventListener('change',()=>{
        const value=byId('tkPayPeriodFilter').value;
        if(value==='custom')return;
        const [from,through]=weekRange(value==='last'?-1:0);
        byId('tkFromDate').value=from;byId('tkThroughDate').value=through;
        window.LineCrewTimekeepingReport?.run?.();
      });
      ['tkFromDate','tkThroughDate'].forEach(id=>byId(id)?.addEventListener('change',()=>{if(byId('tkPayPeriodFilter'))byId('tkPayPeriodFilter').value='custom';}));
    }
  }

  function installCard(){
    const reportCard=byId('tkRunReportBtn')?.closest('.card');
    if(!reportCard||byId('tkPayrollCard'))return;
    const card=document.createElement('div');card.id='tkPayrollCard';card.className='card tk-payroll-card';
    card.innerHTML=`
      <div class="tk-payroll-top"><div><h3>Payroll & Timesheet Export</h3><p class="muted">Review exceptions, approve weekly time, then export payroll-ready Excel, PDF or CSV.</p></div><span id="tkPeriodBadge" class="tk-period-badge">Open</span></div>
      <div id="tkPeriodStatus" class="tk-help"></div>
      <div class="tk-payroll-actions">
        <button id="tkExportExcelBtn" type="button" class="secondary">Export Excel Timesheet</button>
        <button id="tkExportPdfBtn" type="button" class="secondary">Export PDF Timesheet</button>
        <button id="tkReviewExceptionsBtn" type="button" class="secondary">Review Exceptions</button>
        <button id="tkApprovePeriodBtn" type="button" class="success hidden">Approve Pay Period</button>
        <button id="tkReopenPeriodBtn" type="button" class="secondary hidden">Reopen</button>
        <button id="tkLockPeriodBtn" type="button" class="warning hidden">Lock Pay Period</button>
        <button id="tkUnlockPeriodBtn" type="button" class="secondary hidden">Unlock</button>
      </div>
      <div id="tkExceptionsBox" class="hidden"></div>
      <div class="tk-export-note">Approved time automatically returns to Open if someone changes an entry. Locked time cannot be changed until an Admin or Owner unlocks the pay period.</div>`;
    reportCard.insertAdjacentElement('afterend',card);
    byId('tkExportExcelBtn').onclick=exportExcel;
    byId('tkExportPdfBtn').onclick=exportPdf;
    byId('tkReviewExceptionsBtn').onclick=()=>{renderExceptions(true);};
    byId('tkApprovePeriodBtn').onclick=()=>setPeriod('approve');
    byId('tkReopenPeriodBtn').onclick=()=>setPeriod('reopen');
    byId('tkLockPeriodBtn').onclick=()=>setPeriod('lock');
    byId('tkUnlockPeriodBtn').onclick=()=>setPeriod('unlock');
  }

  function currentRange(){return [byId('tkFromDate')?.value||'',byId('tkThroughDate')?.value||''];}

  async function refreshPeriod(){
    const [from,through]=currentRange();const client=getSb();if(!from||!through||!client)return;
    const {data,error}=await client.rpc('timekeeping_period_state',{p_start:from,p_end:through});
    if(error){toast('Could not load pay-period status: '+error.message,'error');return;}
    periodState=(data&&data[0])||{period_start:from,period_end:through,status:'open'};
    renderPeriodState();
  }

  function renderPeriodState(){
    const status=periodState.status||'open';const badge=byId('tkPeriodBadge');if(!badge)return;
    badge.textContent=status;badge.className='tk-period-badge '+status;
    const text=[];
    if(status==='approved'&&periodState.approved_at)text.push('Approved '+new Date(periodState.approved_at).toLocaleString());
    if(status==='locked'&&periodState.locked_at)text.push('Locked '+new Date(periodState.locked_at).toLocaleString());
    byId('tkPeriodStatus').textContent=text.join(' • ')||'This pay period is open for edits.';
    const r=role();const approver=['gf','admin','owner'].includes(r),locker=['admin','owner'].includes(r);
    byId('tkApprovePeriodBtn').classList.toggle('hidden',!approver||status!=='open');
    byId('tkReopenPeriodBtn').classList.toggle('hidden',!approver||status!=='approved');
    byId('tkLockPeriodBtn').classList.toggle('hidden',!locker||status!=='approved');
    byId('tkUnlockPeriodBtn').classList.toggle('hidden',!locker||status!=='locked');
  }

  async function setPeriod(action){
    const [from,through]=currentRange();if(!from||!through)return;
    if(action==='approve'){
      await buildExceptions();
      if(exceptions.length&&!confirm(`There are ${exceptions.length} Timekeeping exception${exceptions.length===1?'':'s'} for this period. Approve anyway?`))return;
    }
    if(action==='lock'&&!confirm('Lock this pay period? Time entries in the period cannot be changed until it is unlocked.'))return;
    const button=byId({approve:'tkApprovePeriodBtn',reopen:'tkReopenPeriodBtn',lock:'tkLockPeriodBtn',unlock:'tkUnlockPeriodBtn'}[action]);
    const done=window.LineCrewUI?.loadingButton?.(button,action==='approve'?'Approving…':action==='lock'?'Locking…':'Working…')||(()=>{});
    try{
      const client=getSb();if(!client)throw new Error('Database connection is not ready.');
      const {data,error}=await client.rpc('timekeeping_set_period_status',{p_start:from,p_end:through,p_action:action});
      if(error)throw error;periodState=(data&&data[0])||periodState;renderPeriodState();toast(`Pay period ${action==='approve'?'approved':action==='lock'?'locked':action==='unlock'?'unlocked':'reopened'}.`,'success');
    }catch(error){toast(error.message||'Could not update pay period.','error');}finally{done();}
  }

  async function ensureReport(){
    if(!window.LineCrewTimekeepingReport)return [];
    let rows=window.LineCrewTimekeepingReport.getRows?.()||[];
    if(!rows.length){await window.LineCrewTimekeepingReport.run?.();rows=window.LineCrewTimekeepingReport.getRows?.()||[];}
    return rows;
  }

  async function buildExceptions(){
    const rows=await ensureReport();const api=window.LineCrewTimekeepingReport;
    const employeeMap=api?.getEmployees?.()||new Map();
    const [from,through]=currentRange();const dates=datesBetween(from,through);
    const selectedEmployee=byId('tkEmployeeFilter')?.value||'';const crew=(byId('tkCrewFilter')?.value||'').toLowerCase();
    const activeEmployees=[...employeeMap.values()].filter(e=>e.active!==false&&(!selectedEmployee||e.id===selectedEmployee)&&(!crew||String(e.default_crew_name||'').toLowerCase()===crew));
    const byPersonDay=new Map();
    rows.forEach(r=>{const key=`${r.employee_id}|${r.work_date}`;if(!byPersonDay.has(key))byPersonDay.set(key,[]);byPersonDay.get(key).push(r);});
    const out=[];
    activeEmployees.forEach(e=>dates.forEach(date=>{const d=parseDate(date);if(d.getDay()===0||d.getDay()===6)return;const segs=byPersonDay.get(`${e.id}|${date}`)||[];if(!segs.length)out.push({type:'missing',employee:e.full_name,date,message:'No time recorded on this weekday.'});}));
    byPersonDay.forEach((segs,key)=>{
      const [employeeId,date]=key.split('|');const employee=employeeMap.get(employeeId)||{};const total=segs.reduce((s,r)=>s+num(r.regular_hours)+num(r.overtime_hours),0);const jobs=new Set(segs.map(r=>r.job_id).filter(Boolean));
      if(total>16)out.push({type:'high',employee:employee.full_name||'',date,message:`${total.toFixed(2)} total hours recorded.`});
      if(jobs.size>1)out.push({type:'multijob',employee:employee.full_name||'',date,message:`Time is split across ${jobs.size} jobs.`});
      const signatures=new Map();segs.forEach(r=>{const sig=[r.job_id,r.crew_name,num(r.regular_hours).toFixed(2),num(r.overtime_hours).toFixed(2),r.storm_work?'1':'0'].join('|');signatures.set(sig,(signatures.get(sig)||0)+1);});
      if([...signatures.values()].some(v=>v>1))out.push({type:'duplicate',employee:employee.full_name||'',date,message:'Possible duplicate time segment detected.'});
    });
    exceptions=out;return out;
  }

  async function renderExceptions(show=true){
    await buildExceptions();const box=byId('tkExceptionsBox');if(!box)return;
    box.classList.toggle('hidden',!show);
    if(!show)return;
    if(!exceptions.length){box.innerHTML='<div class="tk-empty-state"><strong>No Timekeeping exceptions found</strong>This period has no missing weekday time, high-hour totals, multi-job review flags, or possible duplicate segments.</div>';return;}
    box.innerHTML=`<strong>${exceptions.length} exception${exceptions.length===1?'':'s'} to review</strong><div class="tk-exception-list">${exceptions.map(x=>`<div class="tk-exception ${x.type==='high'?'high':''}"><strong>${esc(x.employee||'Employee')} — ${esc(x.date)}</strong><br>${esc(x.message)}</div>`).join('')}</div>`;
  }

  function timeText(v){return v?String(v).slice(0,5):'';}
  function detailData(rows){
    const api=window.LineCrewTimekeepingReport;const employeeMap=api.getEmployees(),jobMap=api.getJobs();
    return rows.map(r=>{const e=employeeMap.get(r.employee_id)||{},j=jobMap.get(r.job_id)||{};const equipment=r.equipment_not_used?'Not used':(r.equipment_used||e.default_equipment||'');return [e.employee_number||'',e.full_name||'',e.classification||'',r.work_date||'',j.job_number||'',j.job_name||'',r.crew_name||e.default_crew_name||'',timeText(r.start_time),timeText(r.stop_time),num(r.lunch_minutes),num(r.regular_hours),num(r.overtime_hours),num(r.regular_hours)+num(r.overtime_hours),r.per_diem?'Yes':'No',equipment,r.storm_work?'Yes':'No'];});
  }

  async function exportExcel(){
    const rows=await ensureReport();if(!rows.length)return toast('There is no Timekeeping data to export for these filters.','warning');
    if(typeof XLSX==='undefined')return toast('Excel export library is still loading. Try again in a moment.','warning');
    await buildExceptions();const api=window.LineCrewTimekeepingReport,employeeMap=api.getEmployees();const [from,through]=currentRange();const dates=datesBetween(from,through);
    const grouped=new Map();rows.forEach(r=>{if(!grouped.has(r.employee_id))grouped.set(r.employee_id,new Map());const day=grouped.get(r.employee_id);if(!day.has(r.work_date))day.set(r.work_date,{reg:0,ot:0,perDiem:false});const x=day.get(r.work_date);x.reg+=num(r.regular_hours);x.ot+=num(r.overtime_hours);x.perDiem=x.perDiem||!!r.per_diem;});
    const header=['Employee #','Employee','Classification','Crew'];dates.forEach(d=>header.push(dayLabel(d)+' Reg',dayLabel(d)+' OT'));header.push('Total Reg','Total OT','Total Hours','Per Diem Days');
    const aoa=[['LineCrew Pro Weekly Timesheet'],[`Period: ${from} through ${through}`],[`Status: ${(periodState.status||'open').toUpperCase()}`],[],header];
    [...grouped.entries()].sort((a,b)=>String(employeeMap.get(a[0])?.full_name||'').localeCompare(String(employeeMap.get(b[0])?.full_name||''))).forEach(([employeeId,days])=>{const e=employeeMap.get(employeeId)||{};const row=[e.employee_number||'',e.full_name||'',e.classification||'',e.default_crew_name||''];let tr=0,to=0,pd=0;dates.forEach(d=>{const x=days.get(d)||{reg:0,ot:0,perDiem:false};row.push(x.reg,x.ot);tr+=x.reg;to+=x.ot;if(x.perDiem)pd++;});row.push(tr,to,tr+to,pd);aoa.push(row);});
    const wb=XLSX.utils.book_new();const summary=XLSX.utils.aoa_to_sheet(aoa);summary['!cols']=header.map((_,i)=>({wch:i===1?24:i<4?16:11}));XLSX.utils.book_append_sheet(wb,summary,'Weekly Timesheet');
    const detail=[['Employee #','Employee','Classification','Date','Job #','Job Name','Crew','Start','Stop','Lunch Minutes','Regular Hours','OT Hours','Total Hours','Per Diem','Equipment','Storm'],...detailData(rows)];XLSX.utils.book_append_sheet(wb,XLSX.utils.aoa_to_sheet(detail),'Detail');
    const ex=[['Type','Employee','Date','Review Note'],...exceptions.map(x=>[x.type,x.employee,x.date,x.message])];XLSX.utils.book_append_sheet(wb,XLSX.utils.aoa_to_sheet(ex),'Exceptions');
    XLSX.writeFile(wb,`linecrew-timesheet-${from}-to-${through}.xlsx`);toast('Excel timesheet exported.','success');
  }

  function loadScript(src,integrity){return new Promise((resolve,reject)=>{const existing=document.querySelector(`script[src="${src}"]`);if(existing){if(existing.dataset.loaded==='1')return resolve();existing.addEventListener('load',resolve,{once:true});existing.addEventListener('error',reject,{once:true});return;}const s=document.createElement('script');s.src=src;s.integrity=integrity;s.crossOrigin='anonymous';s.onload=()=>{s.dataset.loaded='1';resolve();};s.onerror=()=>reject(new Error('A protected PDF library failed its integrity check or could not be loaded.'));document.head.appendChild(s);});}

  async function exportPdf(){
    const rows=await ensureReport();if(!rows.length)return toast('There is no Timekeeping data to export for these filters.','warning');
    const button=byId('tkExportPdfBtn');const done=window.LineCrewUI?.loadingButton?.(button,'Building PDF…')||(()=>{});
    try{
      if(!window.jspdf?.jsPDF)await loadScript('https://cdn.jsdelivr.net/npm/jspdf@2.5.2/dist/jspdf.umd.min.js','sha384-en/ztfPSRkGfME4KIm05joYXynqzUgbsG5nMrj/xEFAHXkeZfO3yMK8QQ+mP7p1/');
      if(!window.jspdf?.jsPDF)throw new Error('PDF library did not load.');
      if(!window.jspdf.jsPDF.API.autoTable)await loadScript('https://cdn.jsdelivr.net/npm/jspdf-autotable@3.8.4/dist/jspdf.plugin.autotable.min.js','sha384-Xl/CUCfJbzsngMp0CFxkmF0VW/8C160IsGujqeQlIhaGxKz2+JsIGORFqtCPeldF');
      await buildExceptions();const {jsPDF}=window.jspdf;const doc=new jsPDF({orientation:'landscape',unit:'pt',format:'letter'});const [from,through]=currentRange();
      doc.setFontSize(16);doc.text('LineCrew Pro Weekly Timesheet',36,34);doc.setFontSize(10);doc.text(`Period: ${from} through ${through}    Status: ${(periodState.status||'open').toUpperCase()}`,36,52);
      doc.autoTable({startY:66,head:[['Date','Employee','Job','Crew','Start','Stop','Lunch','Regular','OT','Total','Per Diem','Equipment','Storm']],body:detailData(rows).map(r=>[r[3],r[1],r[4],r[6],r[7],r[8],r[9],Number(r[10]).toFixed(2),Number(r[11]).toFixed(2),Number(r[12]).toFixed(2),r[13],r[14],r[15]]),styles:{fontSize:6.5,cellPadding:2},headStyles:{fontStyle:'bold'}});
      if(exceptions.length){const y=(doc.lastAutoTable?.finalY||66)+18;doc.setFontSize(11);doc.text('Exceptions / Review Flags',36,y);doc.autoTable({startY:y+8,head:[['Type','Employee','Date','Review Note']],body:exceptions.map(x=>[x.type,x.employee,x.date,x.message]),styles:{fontSize:8,cellPadding:3}});}
      doc.save(`linecrew-timesheet-${from}-to-${through}.pdf`);toast('PDF timesheet exported.','success');
    }catch(error){toast('Could not create PDF: '+error.message,'error');}finally{done();}
  }

  async function refreshAll(){
    installFilters();installCard();
    if(!byId('timekeepingPage')||byId('timekeepingPage').classList.contains('hidden'))return;
    await refreshPeriod();
  }

  function init(){
    addStyles();refreshAll();
    document.addEventListener('linecrew:timekeeping-report',()=>{refreshPeriod();buildExceptions();});
    document.addEventListener('change',e=>{if(['tkFromDate','tkThroughDate','tkEmployeeFilter','tkJobFilter','tkCrewFilter'].includes(e.target?.id)){setTimeout(()=>{refreshPeriod();buildExceptions();},50);}});
    let timer;new MutationObserver(()=>{clearTimeout(timer);timer=setTimeout(refreshAll,80);}).observe(document.body,{subtree:true,childList:true,attributes:true,attributeFilter:['class']});
  }
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',init);else init();
})();