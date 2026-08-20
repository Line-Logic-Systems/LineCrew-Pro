/* LineCrew Pro - Timekeeping usability polish */
(() => {
  'use strict';
  const byId=id=>document.getElementById(id);

  function addStyles(){
    if(byId('tkPolishStyles')) return;
    const s=document.createElement('style');s.id='tkPolishStyles';s.textContent=`
      #timekeepingPage .card{overflow:visible}
      #timekeepingPage .tk-table-wrap{border:1px solid #dce5ed;border-radius:12px;overflow:auto;background:#fff}
      #timekeepingPage .tk-table thead th{position:sticky;top:0;background:#f7fafc;z-index:1}
      #timekeepingPage .tk-table tbody tr:hover{background:#f8fbfe}
      #timekeepingPage .tk-filter-bar{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin:10px 0 4px}
      #timekeepingPage .tk-filter-bar button{width:auto!important;margin:0!important;padding:7px 10px!important}
      #timekeepingPage .tk-report-status{font-size:12px;color:#667788;margin:8px 0 0;min-height:18px}
      #timekeepingPage .tk-mobile-row-label{display:none}
      #timekeepingPage .tk-empty-state{border:1px dashed #c9d7e3;border-radius:12px;padding:18px;text-align:center;background:#fbfdff;color:#5f6f7f}
      #timekeepingPage .tk-empty-state strong{display:block;color:#17324d;margin-bottom:4px}
      #timekeepingPage button[data-busy="1"]{pointer-events:none;opacity:.65}
      @media(max-width:720px){
        #timekeepingPage .section-header{align-items:flex-start!important}
        #timekeepingPage .section-header>button{width:100%;margin-top:8px}
        #timekeepingPage .tk-grid{grid-template-columns:1fr!important}
        #timekeepingPage .tk-summary{grid-template-columns:1fr 1fr!important;gap:8px}
        #timekeepingPage .tk-summary>div{padding:10px 8px}
        #timekeepingPage .tk-summary strong{font-size:19px}
        #timekeepingPage .tk-inline-actions{display:grid;grid-template-columns:1fr 1fr;gap:8px}
        #timekeepingPage .tk-inline-actions button{width:100%!important;margin:0!important}
        #timekeepingPage .tk-table-wrap{border:0;overflow:visible;background:transparent}
        #timekeepingPage .tk-table{min-width:0!important;border-collapse:separate;border-spacing:0}
        #timekeepingPage .tk-table thead{display:none}
        #timekeepingPage .tk-table,#timekeepingPage .tk-table tbody,#timekeepingPage .tk-table tr,#timekeepingPage .tk-table td{display:block;width:100%}
        #timekeepingPage .tk-table tbody tr{border:1px solid #dce5ed;border-radius:12px;padding:8px 10px;margin:10px 0;background:#fff;box-shadow:0 1px 4px rgba(20,45,70,.04)}
        #timekeepingPage .tk-table td{display:grid;grid-template-columns:minmax(115px,.8fr) minmax(0,1.2fr);gap:10px;border:0!important;border-bottom:1px solid #eef3f6!important;padding:7px 2px!important;align-items:center}
        #timekeepingPage .tk-table td:last-child{border-bottom:0!important}
        #timekeepingPage .tk-table td::before{content:attr(data-label);font-size:11px;text-transform:uppercase;letter-spacing:.03em;color:#6b7b89;font-weight:800}
        #timekeepingPage .tk-table td[data-label="Employee"]{font-size:15px}
        #timekeepingPage .tk-row-actions button{width:100%!important}
        #timekeepingPage .tk-crew-row{grid-template-columns:1fr 1fr!important;gap:8px}
        #timekeepingPage .tk-crew-row .tk-person{grid-column:1/-1}
        #timekeepingPage .tk-crew-row button{width:100%!important}
      }
      @media(max-width:420px){
        #timekeepingPage .tk-summary{grid-template-columns:1fr!important}
        #timekeepingPage .tk-inline-actions{grid-template-columns:1fr}
      }
    `;document.head.appendChild(s);
  }

  function labelTables(){
    document.querySelectorAll('#timekeepingPage .tk-table').forEach(table=>{
      const headers=[...table.querySelectorAll('thead th')].map(th=>(th.textContent||'').trim());
      table.querySelectorAll('tbody tr').forEach(row=>{
        [...row.children].forEach((td,i)=>{if(td.tagName==='TD' && !td.dataset.label) td.dataset.label=headers[i]||'';});
      });
    });
  }

  function improveEmptyStates(){
    const report=byId('tkReportList');
    if(report && /No time entries match these filters\.|No time recorded for this view\./i.test(report.textContent||'')){
      report.innerHTML='<div class="tk-empty-state"><strong>No time recorded for this view</strong>Save crew time on a Daily Report or change the date, employee, or job filters.</div>';
    }
    const roster=byId('tkRosterList');
    if(roster && /No employees have been added yet\./i.test(roster.textContent||'')){
      roster.innerHTML='<div class="tk-empty-state"><strong>No employees yet</strong>Add an employee above or upload a company roster.</div>';
    }
  }

  function installFilterHelpers(){
    const run=byId('tkRunReportBtn');
    if(!run || byId('tkFilterHelpers')) return;
    const bar=document.createElement('div');bar.id='tkFilterHelpers';bar.className='tk-filter-bar';
    bar.innerHTML='<span class="tk-help">Quick dates:</span><button type="button" class="secondary small" data-tk-range="today">Today</button><button type="button" class="secondary small" data-tk-range="week">This Week</button>';
    run.closest('.tk-inline-actions')?.insertAdjacentElement('beforebegin',bar);
    const status=document.createElement('div');status.id='tkReportStatus';status.className='tk-report-status';status.setAttribute('aria-live','polite');
    byId('tkReportList')?.insertAdjacentElement('beforebegin',status);
    bar.querySelectorAll('[data-tk-range]').forEach(btn=>btn.onclick=()=>{
      const now=new Date();const iso=d=>`${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
      if(btn.dataset.tkRange==='today'){
        byId('tkFromDate').value=iso(now);byId('tkThroughDate').value=iso(now);
      }else{
        const d=new Date(now);const day=(d.getDay()+6)%7;d.setDate(d.getDate()-day);byId('tkFromDate').value=iso(d);byId('tkThroughDate').value=iso(now);
      }
      run.click();
    });
  }

  function updateReportStatus(){
    const status=byId('tkReportStatus');if(!status)return;
    const rows=document.querySelectorAll('#tkReportList .tk-table tbody tr').length;
    const from=byId('tkFromDate')?.value||'';const through=byId('tkThroughDate')?.value||'';
    if(rows) status.textContent=`Showing ${rows} time segment${rows===1?'':'s'}${from&&through?` from ${from} through ${through}`:''}.`;
    else if(byId('tkReportList')?.textContent?.trim()) status.textContent=from&&through?`No matching time from ${from} through ${through}.`:'';
  }

  function markBusyButtons(){
    document.querySelectorAll('#timekeepingPage button').forEach(btn=>{
      if(/Running|Saving|Importing|Working/i.test(btn.textContent||'')) btn.dataset.busy='1';
      else delete btn.dataset.busy;
    });
  }

  function polish(){labelTables();improveEmptyStates();installFilterHelpers();updateReportStatus();markBusyButtons();}
  function init(){addStyles();polish();let timer;const obs=new MutationObserver(()=>{clearTimeout(timer);timer=setTimeout(polish,35)});obs.observe(document.body,{subtree:true,childList:true,characterData:true,attributes:true,attributeFilter:['class','disabled']});}
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',init);else init();
})();