/* LineCrew Pro - Admin/Owner searchable long-term pay-period archive */
(() => {
  'use strict';
  const PAGE_SIZE=25;
  const byId=id=>document.getElementById(id);
  const esc=v=>String(v??'').replace(/[&<>"']/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
  const num=v=>Number(v||0)||0;
  const profile=()=>typeof currentProfile!=='undefined'?currentProfile:window.currentProfile;
  const role=()=>String(profile()?.role||'').toLowerCase();
  const allowed=()=>['admin','owner'].includes(role());
  const getSb=()=>{try{return typeof sb!=='undefined'?sb:(window.sb||window.supabaseClient||null);}catch(_){return window.sb||window.supabaseClient||null;}};
  const toast=(m,t='info')=>window.LineCrewUI?.toast?.(m,t)||console.log(m);
  let periods=[],audits=[],entries=[],names=new Map(),page=0,totalCount=0,loading=false;

  function addStyles(){
    if(byId('tkHistoryStyles'))return;
    const s=document.createElement('style');s.id='tkHistoryStyles';s.textContent=`
      #timekeepingPage .tk-history-card{border:1px solid #dce5ed;background:#fff}
      #timekeepingPage .tk-history-head{display:flex;justify-content:space-between;align-items:flex-start;gap:10px;flex-wrap:wrap}
      #timekeepingPage .tk-history-search{display:grid;grid-template-columns:repeat(4,minmax(125px,1fr)) auto auto;gap:8px;align-items:end;margin-top:10px}
      #timekeepingPage .tk-history-search label{font-size:11px;color:#607181;margin:0}
      #timekeepingPage .tk-history-search input,#timekeepingPage .tk-history-search select{margin-top:3px}
      #timekeepingPage .tk-history-search button{width:auto!important;margin:0!important}
      #timekeepingPage .tk-history-list{display:grid;gap:6px;margin-top:10px}
      #timekeepingPage .tk-history-row{border:1px solid #e3eaf0;border-radius:8px;background:#fbfdff;overflow:hidden}
      #timekeepingPage .tk-history-main{display:grid;grid-template-columns:minmax(150px,1.5fr) 86px repeat(4,minmax(74px,.7fr)) auto;gap:8px;align-items:center;padding:8px 10px;font-size:12px}
      #timekeepingPage .tk-history-main strong{font-size:13px;color:#102235}
      #timekeepingPage .tk-history-status{font-weight:800;text-transform:uppercase;font-size:10px;letter-spacing:.04em}
      #timekeepingPage .tk-history-meta{color:#667786}
      #timekeepingPage .tk-history-actions{display:flex;gap:5px;justify-content:flex-end}
      #timekeepingPage .tk-history-actions button{width:auto!important;margin:0!important;padding:5px 8px!important;font-size:11px!important}
      #timekeepingPage .tk-history-audit{border-top:1px solid #e3eaf0;padding:8px 10px;background:#fff;font-size:12px}
      #timekeepingPage .tk-history-audit.hidden{display:none}
      #timekeepingPage .tk-history-audit-line{padding:4px 0;border-bottom:1px dashed #edf1f4}
      #timekeepingPage .tk-history-audit-line:last-child{border-bottom:0}
      #timekeepingPage .tk-history-empty{padding:10px;color:#687a8a;font-size:12px}
      #timekeepingPage .tk-history-pager{display:flex;align-items:center;justify-content:space-between;gap:10px;margin-top:10px;font-size:12px;color:#667786}
      #timekeepingPage .tk-history-pager-actions{display:flex;gap:6px}
      #timekeepingPage .tk-history-pager button{width:auto!important;margin:0!important;padding:5px 9px!important;font-size:11px!important}
      @media(max-width:900px){#timekeepingPage .tk-history-main{grid-template-columns:1.5fr .7fr .7fr .7fr}#timekeepingPage .tk-history-actions{grid-column:1/-1;justify-content:flex-start}#timekeepingPage .tk-history-search{grid-template-columns:1fr 1fr 1fr}}
      @media(max-width:560px){#timekeepingPage .tk-history-main{grid-template-columns:1fr 1fr}#timekeepingPage .tk-history-search{grid-template-columns:1fr 1fr}}
    `;document.head.appendChild(s);
  }

  function fmtDate(v){if(!v)return '';const [y,m,d]=String(v).slice(0,10).split('-');return `${m}/${d}/${y}`;}
  function fmtStamp(v){if(!v)return '';try{return new Date(v).toLocaleString();}catch(_){return String(v);}}
  function actor(id){return names.get(id)||'Admin/Owner';}
  function filters(){return {from:byId('tkHistoryFrom')?.value||'',through:byId('tkHistoryThrough')?.value||'',year:byId('tkHistoryYear')?.value||'',status:byId('tkHistoryStatus')?.value||''};}

  function installCard(){
    if(!allowed())return;
    const payroll=byId('tkPayrollCard');
    if(!payroll||byId('tkPayPeriodHistoryCard'))return;
    const card=document.createElement('div');card.id='tkPayPeriodHistoryCard';card.className='card tk-history-card';
    card.innerHTML=`<div class="tk-history-head"><div><h3 style="margin-bottom:3px">Pay Period History / Archived Timesheets</h3><p class="muted" style="margin:0">Search the full payroll archive by year, date range or status. Older records stay available here without loading years of data at once.</p></div><button id="tkRefreshHistoryBtn" type="button" class="secondary" style="width:auto;margin:0">Refresh History</button></div>
      <div class="tk-history-search">
        <label>Year<select id="tkHistoryYear"><option value="">All years</option></select></label>
        <label>From<input id="tkHistoryFrom" type="date"></label>
        <label>Through<input id="tkHistoryThrough" type="date"></label>
        <label>Status<select id="tkHistoryStatus"><option value="">All statuses</option><option value="open">Open</option><option value="approved">Approved</option><option value="locked">Locked</option></select></label>
        <button id="tkHistorySearchBtn" type="button" class="secondary">Search</button>
        <button id="tkHistoryClearBtn" type="button" class="secondary">Clear</button>
      </div>
      <div id="tkHistoryList" class="tk-history-list"><div class="tk-history-empty">Loading saved pay periods…</div></div>
      <div class="tk-history-pager"><span id="tkHistoryPageText"></span><div class="tk-history-pager-actions"><button id="tkHistoryPrevBtn" type="button" class="secondary">Previous</button><button id="tkHistoryNextBtn" type="button" class="secondary">Next</button></div></div>`;
    payroll.insertAdjacentElement('afterend',card);
    byId('tkRefreshHistoryBtn').onclick=()=>loadHistory(false);
    byId('tkHistorySearchBtn').onclick=()=>{page=0;loadHistory(false);};
    byId('tkHistoryClearBtn').onclick=()=>{['tkHistoryFrom','tkHistoryThrough','tkHistoryYear','tkHistoryStatus'].forEach(id=>{if(byId(id))byId(id).value='';});page=0;loadHistory(false);};
    byId('tkHistoryPrevBtn').onclick=()=>{if(page>0){page--;loadHistory(false);}};
    byId('tkHistoryNextBtn').onclick=()=>{if((page+1)*PAGE_SIZE<totalCount){page++;loadHistory(false);}};
  }

  async function populateYears(client,companyId){
    const select=byId('tkHistoryYear');if(!select||select.dataset.loaded==='1')return;
    const {data,error}=await client.from('timekeeping_pay_periods').select('period_start').eq('company_id',companyId).order('period_start',{ascending:false});
    if(error)return;
    const years=[...new Set((data||[]).map(x=>String(x.period_start||'').slice(0,4)).filter(Boolean))];
    select.innerHTML='<option value="">All years</option>'+years.map(y=>`<option value="${esc(y)}">${esc(y)}</option>`).join('');
    select.dataset.loaded='1';
  }

  async function loadHistory(resetPage=true){
    if(!allowed()||loading)return;
    installCard();
    const client=getSb(),companyId=profile()?.company_id;if(!client||!companyId)return;
    if(resetPage)page=0;
    loading=true;
    const list=byId('tkHistoryList');if(list)list.innerHTML='<div class="tk-history-empty">Loading saved pay periods…</div>';
    try{
      await populateYears(client,companyId);
      const f=filters();let q=client.from('timekeeping_pay_periods').select('id,company_id,period_start,period_end,status,approved_by,approved_at,locked_by,locked_at,notes,created_at,updated_at',{count:'exact'}).eq('company_id',companyId);
      if(f.year){q=q.gte('period_start',`${f.year}-01-01`).lte('period_start',`${f.year}-12-31`);}
      if(f.from)q=q.gte('period_end',f.from);
      if(f.through)q=q.lte('period_start',f.through);
      if(f.status)q=q.eq('status',f.status);
      const start=page*PAGE_SIZE,end=start+PAGE_SIZE-1;
      const {data:p,error:pe,count}=await q.order('period_start',{ascending:false}).range(start,end);
      if(pe)throw pe;periods=p||[];totalCount=count||0;
      if(!periods.length){audits=[];entries=[];names=new Map();render();return;}
      const min=periods.reduce((a,x)=>!a||x.period_start<a?x.period_start:a,'');
      const max=periods.reduce((a,x)=>!a||x.period_end>a?x.period_end:a,'');
      const [{data:a,error:ae},{data:e,error:ee},{data:people,error:ne}]=await Promise.all([
        client.from('timekeeping_pay_period_audit').select('id,period_start,period_end,action,actor_id,detail,created_at').eq('company_id',companyId).gte('period_start',min).lte('period_end',max).order('created_at',{ascending:false}),
        client.from('timekeeping_entries').select('employee_id,work_date,regular_hours,overtime_hours,per_diem').eq('company_id',companyId).gte('work_date',min).lte('work_date',max),
        client.from('profiles').select('id,full_name').eq('company_id',companyId)
      ]);
      if(ae)throw ae;if(ee)throw ee;
      audits=a||[];entries=e||[];names=new Map((people||[]).map(x=>[x.id,x.full_name||'']));
      if(ne)console.warn('Pay-period history could not load actor names:',ne.message);
      render();
    }catch(error){if(list)list.innerHTML=`<div class="tk-history-empty">Could not load pay-period history: ${esc(error.message||error)}</div>`;}
    finally{loading=false;updatePager();}
  }

  function summary(period){
    const rows=entries.filter(r=>r.work_date>=period.period_start&&r.work_date<=period.period_end);
    const employees=new Set(rows.map(r=>r.employee_id).filter(Boolean));
    const reg=rows.reduce((s,r)=>s+num(r.regular_hours),0),ot=rows.reduce((s,r)=>s+num(r.overtime_hours),0);
    const pd=new Set(rows.filter(r=>r.per_diem).map(r=>`${r.employee_id}|${r.work_date}`)).size;
    return {employees:employees.size,reg,ot,pd};
  }
  function auditFor(period){return audits.filter(a=>a.period_start===period.period_start&&a.period_end===period.period_end);}
  function updatePager(){
    const text=byId('tkHistoryPageText'),prev=byId('tkHistoryPrevBtn'),next=byId('tkHistoryNextBtn');
    const first=totalCount?page*PAGE_SIZE+1:0,last=Math.min((page+1)*PAGE_SIZE,totalCount);
    if(text)text.textContent=totalCount?`Showing ${first}–${last} of ${totalCount} saved pay periods`:'No saved pay periods found';
    if(prev)prev.disabled=page<=0;if(next)next.disabled=(page+1)*PAGE_SIZE>=totalCount;
  }

  function render(){
    const list=byId('tkHistoryList');if(!list)return;
    if(!periods.length){list.innerHTML='<div class="tk-history-empty">No saved pay periods match these filters.</div>';updatePager();return;}
    list.innerHTML=periods.map((p,i)=>{
      const s=summary(p),a=auditFor(p);const approved=p.approved_at?`Approved ${fmtStamp(p.approved_at)} by ${esc(actor(p.approved_by))}`:'',locked=p.locked_at?`Locked ${fmtStamp(p.locked_at)} by ${esc(actor(p.locked_by))}`:'';
      return `<div class="tk-history-row"><div class="tk-history-main"><div><strong>${esc(fmtDate(p.period_start))} – ${esc(fmtDate(p.period_end))}</strong><div class="tk-history-meta">${approved}${approved&&locked?' • ':''}${locked}</div></div><div><span class="tk-history-status">${esc(p.status||'open')}</span></div><div><b>${s.employees}</b><br><span class="tk-history-meta">Employees</span></div><div><b>${s.reg.toFixed(2)}</b><br><span class="tk-history-meta">Reg</span></div><div><b>${s.ot.toFixed(2)}</b><br><span class="tk-history-meta">OT</span></div><div><b>${s.pd}</b><br><span class="tk-history-meta">Per Diem</span></div><div class="tk-history-actions"><button type="button" class="secondary" data-open-period="${i}">Open Period</button><button type="button" class="secondary" data-audit-period="${i}">Audit (${a.length})</button></div></div><div id="tkHistoryAudit${i}" class="tk-history-audit hidden">${a.length?a.map(x=>`<div class="tk-history-audit-line"><strong>${esc(String(x.action||'action').replaceAll('_',' '))}</strong> — ${esc(actor(x.actor_id))} — ${esc(fmtStamp(x.created_at))}${x.detail?`<br><span class="tk-history-meta">${esc(x.detail)}</span>`:''}</div>`).join(''):'No audit events recorded for this period.'}</div></div>`;
    }).join('');
    list.querySelectorAll('[data-open-period]').forEach(btn=>btn.onclick=()=>openPeriod(periods[Number(btn.dataset.openPeriod)]));
    list.querySelectorAll('[data-audit-period]').forEach(btn=>btn.onclick=()=>byId(`tkHistoryAudit${btn.dataset.auditPeriod}`)?.classList.toggle('hidden'));
    updatePager();
  }

  async function openPeriod(period){
    if(!period)return;
    const from=byId('tkFromDate'),through=byId('tkThroughDate'),pay=byId('tkPayPeriodFilter');
    if(from)from.value=period.period_start;if(through)through.value=period.period_end;if(pay)pay.value='custom';
    await window.LineCrewTimekeepingReport?.run?.();
    byId('tkPayrollCard')?.scrollIntoView({behavior:'smooth',block:'start'});
    toast(`Loaded archived pay period ${fmtDate(period.period_start)} – ${fmtDate(period.period_end)}. Its saved status remains unchanged.`,'success');
  }

  function init(){
    addStyles();installCard();loadHistory(true);
    document.addEventListener('linecrew:timekeeping-report',()=>{if(allowed()&&byId('timekeepingPage')&&!byId('timekeepingPage').classList.contains('hidden')&&byId('tkPayPeriodHistoryCard'))loadHistory(false);});
    let timer;new MutationObserver(()=>{clearTimeout(timer);timer=setTimeout(()=>{if(allowed()){installCard();}},120);}).observe(document.body,{subtree:true,childList:true,attributes:true,attributeFilter:['class']});
  }

  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',init);else init();
})();
