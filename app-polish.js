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
      .lc-dashboard-topbar{display:flex;justify-content:flex-end;margin:0 0 12px}
      .lc-dashboard-topbar button{width:auto;margin:0;padding:10px 14px}
      #teamList{display:grid;gap:5px}
      #teamList .lc-team-member-row{padding:7px 10px!important;margin:0!important;border-radius:9px!important;box-shadow:none!important}
      #teamList .lc-team-member-row strong{font-size:12px;line-height:1.15}
      #teamList .lc-team-member-row .role{font-size:10px;line-height:1.15;margin:2px 0 5px!important}
      #teamList .lc-team-member-row select{width:auto;min-width:125px;padding:6px 8px;font-size:11px;border-radius:7px;margin:0 4px 0 0}
      #teamList .lc-team-member-row button{width:auto;margin:0 4px 0 0;padding:6px 8px;font-size:10px;border-radius:7px}
      #teamList .lc-team-member-row > div{margin-top:4px!important;margin-bottom:4px!important}
      .lc-team-tools{display:grid;grid-template-columns:minmax(0,1fr) 190px auto;gap:8px;align-items:center;margin:8px 0 10px}
      .lc-team-tools input,.lc-team-tools select{margin:0;padding:9px 10px;font-size:12px;border-radius:9px}
      .lc-team-count{font-size:11px;color:#607386;white-space:nowrap;text-align:right}
      .lc-team-empty{padding:12px;border:1px dashed #cbd7e2;border-radius:9px;color:#607386;font-size:12px;background:#f8fbfe}
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
        #teamList .lc-team-member-row select{min-width:115px}
        .lc-team-tools{grid-template-columns:1fr 1fr}.lc-team-count{grid-column:1 / -1;text-align:left}
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

  if(!window.__lcNativeAlert){window.__lcNativeAlert=window.alert.bind(window);window.alert=(msg)=>toast(msg,/failed|could not|error|unable/i.test(String(msg))?'error':/returned|warning|correct/i.test(String(msg))?'warning':'info',4200);}

  function loadingButton(btn, busyText){
    if(!btn || btn.dataset.lcBusy==='1') return ()=>{};
    const original=btn.textContent;btn.dataset.lcBusy='1';btn.disabled=true;btn.textContent=busyText||'Working…';
    return ()=>{btn.dataset.lcBusy='0';btn.disabled=false;btn.textContent=original;};
  }
  window.LineCrewUI.loadingButton=loadingButton;

  function improveEmptyStates(){
    const box=byId('tkReportList');
    if(box && /No time entries match these filters\./.test(box.textContent||'')){
      box.innerHTML='<div class="tk-crew-card"><strong>No time recorded for this view.</strong><p class="tk-help">Create or save a Daily Report with crew time, or change the date, employee, or job filters.</p></div>';
    }
  }

  function teamMemberRole(card){
    const text=String(card.textContent||'').toLowerCase();
    if(text.includes('role: general foreman')) return 'gf';
    if(text.includes('role: superintendent')) return 'superintendent';
    if(text.includes('role: admin')) return 'admin';
    if(text.includes('role: owner')) return 'owner';
    if(text.includes('role: foreman')) return 'foreman';
    return '';
  }

  function applyTeamFilters(){
    const list=byId('teamList');
    if(!list) return;
    const search=String(byId('lcTeamSearch')?.value||'').trim().toLowerCase();
    const roleFilter=String(byId('lcTeamRoleFilter')?.value||'all');
    let total=0,visible=0;
    Array.from(list.children).forEach(card=>{
      if(!card.classList.contains('lc-team-member-row')) return;
      total++;
      const haystack=String(card.textContent||'').toLowerCase();
      const role=teamMemberRole(card);
      const matchesSearch=!search || haystack.includes(search);
      const matchesRole=roleFilter==='all' || role===roleFilter;
      const show=matchesSearch && matchesRole;
      card.style.display=show?'':'none';
      if(show) visible++;
    });
    const count=byId('lcTeamCount');
    if(count) count.textContent=`Showing ${visible} of ${total}`;
    const empty=byId('lcTeamEmpty');
    if(empty) empty.hidden=visible!==0 || total===0;
  }

  function ensureTeamTools(){
    const list=byId('teamList');
    if(!list) return;
    if(!byId('lcTeamTools')){
      const tools=document.createElement('div');
      tools.id='lcTeamTools';
      tools.className='lc-team-tools';
      tools.innerHTML='<input id="lcTeamSearch" type="search" placeholder="Search team by name or role" aria-label="Search team">'+
        '<select id="lcTeamRoleFilter" aria-label="Filter team by role"><option value="all">All roles</option><option value="foreman">Foremen</option><option value="gf">General Foremen</option><option value="superintendent">Superintendents</option><option value="admin">Admins</option><option value="owner">Owners</option></select>'+
        '<span id="lcTeamCount" class="lc-team-count"></span>';
      list.parentNode.insertBefore(tools,list);
      const empty=document.createElement('div');empty.id='lcTeamEmpty';empty.className='lc-team-empty';empty.hidden=true;empty.textContent='No team members match this search.';list.parentNode.insertBefore(empty,list.nextSibling);
      byId('lcTeamSearch').addEventListener('input',applyTeamFilters);
      byId('lcTeamRoleFilter').addEventListener('change',applyTeamFilters);
    }
  }

  function compactTeamRoster(){
    const list=byId('teamList');
    if(!list) return;
    Array.from(list.children).forEach(card=>{
      if(!/Role:\s*/i.test(card.textContent||'')) return;
      card.classList.add('lc-team-member-row');
    });
    ensureTeamTools();
    applyTeamFilters();
  }

  function ensureTopSignOut(){
    const dashboard=byId('dashboardPage');
    if(!dashboard || byId('lcDashboardTopSignOut')) return;
    const bar=document.createElement('div');
    bar.className='lc-dashboard-topbar';
    const btn=document.createElement('button');
    btn.id='lcDashboardTopSignOut';
    btn.className='secondary small';
    btn.textContent='Sign Out';
    btn.onclick=()=>{
      if(typeof window.signOut==='function') return window.signOut();
      byId('signOutBtn')?.click();
    };
    bar.appendChild(btn);
    dashboard.insertBefore(bar,dashboard.firstChild);
  }

  function hardenProductionLoader(){
    if(window.__lcProductionLoaderHardened || typeof window.loadProductionReports!=='function') return;
    window.__lcProductionLoaderHardened=true;
    const original=window.loadProductionReports;
    let running=null;
    let rerun=false;
    let lastArgs=[];
    window.loadProductionReports=async function(...args){
      lastArgs=args;
      if(running){rerun=true;return running;}
      do{
        rerun=false;
        running=Promise.resolve(original.apply(this,lastArgs));
        try{await running;}finally{running=null;}
      }while(rerun);
    };
  }

  function makeDashboardTilesAccessible(){
    const dashboard=byId('dashboardPage');
    if(!dashboard) return;
    dashboard.querySelectorAll('.metric').forEach(tile=>{
      if(typeof tile.onclick!=='function' || tile.dataset.lcKeyboardReady==='1') return;
      tile.dataset.lcKeyboardReady='1';
      tile.setAttribute('role','link');
      tile.tabIndex=0;
      const title=tile.querySelector('strong')?.textContent?.trim();
      if(title && !tile.getAttribute('aria-label')) tile.setAttribute('aria-label',title);
      tile.addEventListener('keydown',event=>{
        if(event.key!=='Enter' && event.key!==' ') return;
        event.preventDefault();
        tile.click();
      });
    });
  }

  let dirty=false;let dirtyScope=null;
  const tracked=['dailyReportForm','safetyJsaForm'];
  document.addEventListener('input',e=>{const form=e.target?.closest?.('form');if(form && tracked.includes(form.id)){dirty=true;dirtyScope=form.id;form.dataset.lcDirty='1';}},true);
  document.addEventListener('change',e=>{const form=e.target?.closest?.('form');if(form && tracked.includes(form.id)){dirty=true;dirtyScope=form.id;form.dataset.lcDirty='1';}},true);
  document.addEventListener('click',e=>{
    const id=e.target?.id||'';
    if(['saveDailyReportBtn','saveSafetyJsaBtn','saveDailyUnitBatchBtn'].includes(id)){setTimeout(()=>{dirty=false;dirtyScope=null;tracked.forEach(x=>{const f=byId(x);if(f)delete f.dataset.lcDirty;});},1700);}
  },true);
  window.addEventListener('beforeunload',e=>{if(!dirty)return;e.preventDefault();e.returnValue='';});

  function harden(){
    ensureTopSignOut();
    hardenProductionLoader();
    makeDashboardTilesAccessible();
    compactTeamRoster();
  }

  function init(){
    addStyles();
    improveEmptyStates();
    harden();
    const obs=new MutationObserver(()=>{improveEmptyStates();harden();});
    obs.observe(document.body,{subtree:true,childList:true,characterData:true});
    [250,750,1500,3000].forEach(delay=>setTimeout(harden,delay));
  }
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',init);else init();
})();
