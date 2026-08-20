/* LineCrew Pro - shared UI polish */
(() => {
  'use strict';
  const byId = id => document.getElementById(id);

  function addStyles(){
    if(byId('lcPolishStyles')) return;
    const s=document.createElement('style');s.id='lcPolishStyles';s.textContent=`
      #lcToastHost{position:fixed;right:16px;top:16px;z-index:10000;display:grid;gap:10px;max-width:min(390px,calc(100vw - 32px))}
      .lc-toast{background:#fff;border:1px solid #dce5ed;border-left:5px solid #1677d2;border-radius:12px;padding:12px 14px;box-shadow:0 10px 30px rgba(12,37,62,.16);color:#102235;font-weight:700;animation:lcToastIn .18s ease-out}
      .lc-toast.success{border-left-color:#198754}.lc-toast.error{border-left-color:#b83232}.lc-toast.warning{border-left-color:#d97706}
      @keyframes lcToastIn{from{opacity:0;transform:translateY(-8px)}to{opacity:1;transform:none}}
      button[disabled]{opacity:.62;cursor:not-allowed}
      .metric{transition:transform .15s ease,box-shadow .15s ease,border-color .15s ease}
      .metric[role="link"]{cursor:pointer}.metric[role="link"]:hover{transform:translateY(-1px);box-shadow:0 5px 18px rgba(12,37,62,.10)}
      .lc-unsaved-badge{display:inline-flex;align-items:center;gap:6px;font-size:12px;font-weight:800;color:#8a4b08;background:#fff4db;border:1px solid #f2c97d;border-radius:999px;padding:5px 9px;margin-left:8px}
      @media(max-width:720px){
        #timekeepingPage .tk-grid{grid-template-columns:1fr!important}
        #timekeepingPage .tk-summary{grid-template-columns:1fr 1fr!important}
        #timekeepingPage .tk-table{min-width:0!important}
        #timekeepingPage .tk-table thead{display:none}
        #timekeepingPage .tk-table,#timekeepingPage .tk-table tbody,#timekeepingPage .tk-table tr,#timekeepingPage .tk-table td{display:block;width:100%}
        #timekeepingPage .tk-table tr{background:#fff;border:1px solid #dce5ed;border-radius:12px;margin:10px 0;padding:8px 10px;box-shadow:0 1px 5px rgba(20,45,70,.04)}
        #timekeepingPage .tk-table td{border:0!important;padding:5px 2px!important}
        #timekeepingPage .tk-table td:empty{display:none}
        #timekeepingPage .tk-inline-actions button{flex:1;min-width:140px}
        .section-header{gap:10px;align-items:flex-start!important;flex-wrap:wrap}
      }
    `;document.head.appendChild(s);
  }

  function toast(message,type='info',timeout=3200){
    let host=byId('lcToastHost');if(!host){host=document.createElement('div');host.id='lcToastHost';document.body.appendChild(host);}
    const el=document.createElement('div');el.className='lc-toast '+type;el.setAttribute('role','status');el.textContent=String(message||'');host.appendChild(el);
    setTimeout(()=>{el.style.opacity='0';el.style.transform='translateY(-5px)';setTimeout(()=>el.remove(),180)},timeout);
    return el;
  }
  window.LineCrewUI={...(window.LineCrewUI||{}),toast};

  // Convert legacy alert calls in newer modules into non-blocking app messages.
  if(!window.__lcNativeAlert){window.__lcNativeAlert=window.alert.bind(window);window.alert=(msg)=>toast(msg,/failed|could not|error/i.test(String(msg))?'error':'info',4200);}

  function loadingButton(btn, busyText){
    if(!btn || btn.dataset.lcBusy==='1') return ()=>{};
    const original=btn.textContent;btn.dataset.lcBusy='1';btn.disabled=true;btn.textContent=busyText||'Working…';
    return ()=>{btn.dataset.lcBusy='0';btn.disabled=false;btn.textContent=original;};
  }
  window.LineCrewUI.loadingButton=loadingButton;

  // Helpful empty-state copy for Timekeeping.
  function improveEmptyStates(){
    const box=byId('tkReportList');
    if(box && /No time entries match these filters\./.test(box.textContent||'')){
      box.innerHTML='<div class="tk-crew-card"><strong>No time recorded for this view.</strong><p class="tk-help">Create or save a Daily Report with crew time, or change the date, employee, or job filters.</p></div>';
    }
  }

  // Unsaved-change guard for the two highest-risk field forms.
  let dirty=false;let dirtyScope=null;
  const tracked=['dailyReportForm','safetyJsaForm'];
  document.addEventListener('input',e=>{const form=e.target?.closest?.('form');if(form && tracked.includes(form.id)){dirty=true;dirtyScope=form.id;form.dataset.lcDirty='1';}},true);
  document.addEventListener('change',e=>{const form=e.target?.closest?.('form');if(form && tracked.includes(form.id)){dirty=true;dirtyScope=form.id;form.dataset.lcDirty='1';}},true);
  document.addEventListener('click',e=>{
    const id=e.target?.id||'';
    if(['saveDailyReportBtn','saveSafetyJsaBtn'].includes(id)){setTimeout(()=>{dirty=false;dirtyScope=null;tracked.forEach(x=>{const f=byId(x);if(f)delete f.dataset.lcDirty;});},1700);}
  },true);
  window.addEventListener('beforeunload',e=>{if(!dirty)return;e.preventDefault();e.returnValue='';});

  function init(){addStyles();improveEmptyStates();const obs=new MutationObserver(improveEmptyStates);obs.observe(document.body,{subtree:true,childList:true,characterData:true});}
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',init);else init();
})();