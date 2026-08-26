/* LineCrew Pro - dark contrast + safe draft crew time restore */
(() => {
  'use strict';
  const byId=id=>document.getElementById(id);
  const getSb=()=>{try{return typeof sb!=='undefined'?sb:(window.sb||window.supabaseClient||null);}catch(_){return window.sb||window.supabaseClient||null;}};
  const companyId=()=>{try{return typeof currentProfile!=='undefined'?currentProfile?.company_id:(window.currentProfile?.company_id||null);}catch(_){return window.currentProfile?.company_id||null;}};

  function addStyles(){
    if(byId('lcDarkContrastDraftFixStyles')) return;
    const style=document.createElement('style');
    style.id='lcDarkContrastDraftFixStyles';
    style.textContent=`
      @media screen {
        html.lc-industrial-dark .role{
          color:#0b2d4d!important;
          background:#dcebf7!important;
          border-color:#b8d2e6!important;
        }
        html.lc-industrial-dark .daily-batch-entry,
        html.lc-industrial-dark .daily-saved-pole,
        html.lc-industrial-dark .tk-summary>div,
        html.lc-industrial-dark .closed-jobs-list,
        html.lc-industrial-dark .file-drop,
        html.lc-industrial-dark .jsa-attachment-page,
        html.lc-industrial-dark .tk-saved-roster,
        html.lc-industrial-dark .tk-assignment-group,
        html.lc-industrial-dark .tk-assignment-group summary{
          background:#10283a!important;
          color:#f5f9fd!important;
          border-color:#315f7f!important;
        }
        html.lc-industrial-dark .daily-batch-entry label,
        html.lc-industrial-dark .daily-batch-number,
        html.lc-industrial-dark .daily-saved-pole strong,
        html.lc-industrial-dark .tk-assignment-group strong,
        html.lc-industrial-dark .tk-saved-roster strong{
          color:#f5f9fd!important;
        }
        html.lc-industrial-dark .daily-batch-entry .muted,
        html.lc-industrial-dark .daily-saved-pole .muted,
        html.lc-industrial-dark .tk-assignment-count,
        html.lc-industrial-dark .tk-equipment-roster,
        html.lc-industrial-dark .tk-equipment-save-state,
        html.lc-industrial-dark .tk-saved-equipment-table th{
          color:#9eb2c5!important;
        }
        html.lc-industrial-dark .status:not(.active):not(.closed):not(.warning),
        html.lc-industrial-dark .billing-status:not(.paid):not(.void){
          color:#102235!important;
        }
      }
    `;
    document.head.appendChild(style);
  }

  function dedupeCrewRows(){
    const seen=new Set();
    document.querySelectorAll('#dailyCrewTimeRows .tk-crew-row').forEach(row=>{
      const employeeId=row.querySelector('.tk-employee')?.value||'';
      if(!employeeId) return;
      if(seen.has(employeeId)) row.remove();
      else seen.add(employeeId);
    });
  }

  function applySavedEntry(row,entry){
    if(!row||!entry)return;
    const regular=row.querySelector('.tk-regular');
    const ot=row.querySelector('.tk-ot');
    const start=row.querySelector('.tk-start');
    const stop=row.querySelector('.tk-stop');
    const lunch=row.querySelector('.tk-lunch');
    const perDiem=row.querySelector('.tk-per-diem');
    const equipment=row.querySelector('.tk-equipment');
    const equipmentNotUsed=row.querySelector('.tk-equipment-not-used');
    if(regular)regular.value=Number(entry.regular_hours||0).toFixed(2);
    if(ot)ot.value=Number(entry.overtime_hours||0).toFixed(2);
    if(start)start.value=String(entry.start_time||'').slice(0,5);
    if(stop)stop.value=String(entry.stop_time||'').slice(0,5);
    if(lunch)lunch.value=entry.lunch_minutes||0;
    if(perDiem)perDiem.checked=entry.per_diem===true;
    if(equipmentNotUsed)equipmentNotUsed.checked=entry.equipment_not_used===true;
    if(equipment)equipment.value=entry.equipment_not_used?'':(entry.equipment_used||'');
    start?.dispatchEvent(new Event('change',{bubbles:true}));
    stop?.dispatchEvent(new Event('change',{bubbles:true}));
    lunch?.dispatchEvent(new Event('change',{bubbles:true}));
  }

  async function restoreDraftCrewTime(){
    const form=byId('dailyReportForm');
    const reportId=form?.dataset.reportId||'';
    const client=getSb();
    const cid=companyId();
    if(!form||form.classList.contains('hidden')||!reportId||!client||!cid)return;
    try{
      const {data,error}=await client.from('timekeeping_entries')
        .select('employee_id,regular_hours,overtime_hours,start_time,stop_time,lunch_minutes,per_diem,equipment_used,equipment_not_used')
        .eq('company_id',cid)
        .eq('daily_report_id',reportId)
        .order('created_at');
      if(error)throw error;
      const saved=data||[];
      for(let attempt=0;attempt<6;attempt++){
        if(form.dataset.reportId!==reportId||form.classList.contains('hidden'))return;
        dedupeCrewRows();
        const rows=[...document.querySelectorAll('#dailyCrewTimeRows .tk-crew-row')];
        const map=new Map(rows.map(row=>[row.querySelector('.tk-employee')?.value||'',row]));
        let matched=0;
        saved.forEach(entry=>{
          const row=map.get(entry.employee_id);
          if(!row)return;
          applySavedEntry(row,entry);
          matched++;
        });
        if(!saved.length || matched===saved.length){
          dedupeCrewRows();
          return;
        }
        await new Promise(resolve=>setTimeout(resolve,120));
      }
      dedupeCrewRows();
    }catch(error){
      console.warn('Could not restore Daily Report draft crew time:',error?.message||error);
    }
  }

  function bindDraftEditButtons(){
    document.querySelectorAll('#productionPage button').forEach(btn=>{
      if(btn.dataset.lcDraftCrewReloadBound==='1') return;
      if(String(btn.textContent||'').trim()!=='Edit Report') return;
      btn.dataset.lcDraftCrewReloadBound='1';
      btn.addEventListener('click',()=>{
        setTimeout(restoreDraftCrewTime,80);
        setTimeout(restoreDraftCrewTime,350);
      });
    });
  }

  function scan(){addStyles();bindDraftEditButtons();}
  function init(){
    scan();
    const observer=new MutationObserver(scan);
    observer.observe(document.body,{subtree:true,childList:true});
    [250,800,1800].forEach(delay=>setTimeout(scan,delay));
  }
  if(document.readyState==='loading') document.addEventListener('DOMContentLoaded',init); else init();
})();
