/* LineCrew Pro - dark contrast + draft crew time reload */
(() => {
  'use strict';
  const byId=id=>document.getElementById(id);

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

  function forceDraftCrewTimeReload(){
    const form=byId('dailyReportForm');
    if(!form || form.classList.contains('hidden') || !form.dataset.reportId) return;
    if(form.dataset.lcDraftReloading==='1') return;
    form.dataset.lcDraftReloading='1';
    const reportId=form.dataset.reportId;
    /* Both Timekeeping modules reset their internal loaded-report key when the
       form becomes hidden. Toggle across animation frames so reopening the same
       draft always reloads its saved crew rows/details instead of reusing stale
       state from the previous visit. */
    form.classList.add('hidden');
    requestAnimationFrame(()=>{
      requestAnimationFrame(()=>{
        if(form.dataset.reportId===reportId){
          form.classList.remove('hidden');
          setTimeout(()=>{
            delete form.dataset.lcDraftReloading;
            form.scrollIntoView({behavior:'smooth',block:'start'});
          },120);
        }else{
          delete form.dataset.lcDraftReloading;
        }
      });
    });
  }

  function bindDraftEditButtons(){
    document.querySelectorAll('#productionPage button').forEach(btn=>{
      if(btn.dataset.lcDraftCrewReloadBound==='1') return;
      if(String(btn.textContent||'').trim()!=='Edit Report') return;
      btn.dataset.lcDraftCrewReloadBound='1';
      btn.addEventListener('click',()=>setTimeout(forceDraftCrewTimeReload,40));
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
