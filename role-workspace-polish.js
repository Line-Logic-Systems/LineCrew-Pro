/* LineCrew Pro - role-specific workspace polish */
(() => {
  'use strict';
  const byId=id=>document.getElementById(id);
  const role=()=>String(window.currentProfile?.role || (typeof currentProfile!=='undefined' ? currentProfile?.role : '') || '').toLowerCase();
  const plans={
    foreman:{title:'Foreman Workspace',text:'Start the day with Safety/JSA, then use Jobs, Production, Remaining Units and Crew Time.',order:['safetyTile','jobsTile','productionTile','remainingUnitsTile','timekeepingTile','trainingTile'],hidden:['teamTile','priceBooksTile']},
    gf:{title:'General Foreman Workspace',text:'Review crews, jobs, production, safety and timekeeping from one place.',order:['productionTile','jobsTile','safetyTile','timekeepingTile','teamTile','trainingTile'],hidden:['priceBooksTile','remainingUnitsTile']},
    superintendent:{title:'Superintendent Workspace',text:'Manage field operations, crews, jobs, production, safety and company tools available to your permissions.',order:['productionTile','jobsTile','teamTile','safetyTile','timekeepingTile','priceBooksTile','trainingTile'],hidden:['remainingUnitsTile']},
    admin:{title:'Admin Workspace',text:'Manage company setup, people, pricing, job setup, production oversight, safety and timekeeping.',order:['teamTile','priceBooksTile','jobsTile','productionTile','safetyTile','timekeepingTile','trainingTile'],hidden:['remainingUnitsTile']},
    owner:{title:'Owner Workspace',text:'Company-wide access for people, pricing, job setup, production oversight, safety and timekeeping.',order:['teamTile','priceBooksTile','jobsTile','productionTile','safetyTile','timekeepingTile','trainingTile'],hidden:['remainingUnitsTile']}
  };
  let observer=null;
  let scheduled=false;

  function observe(){
    observer?.observe(document.body,{subtree:true,childList:true,attributes:true,attributeFilter:['class']});
  }

  function addStyles(){
    if(byId('lcRoleWorkspaceStyles')) return;
    const s=document.createElement('style');
    s.id='lcRoleWorkspaceStyles';
    s.textContent=`
      .lc-role-workspace{border:1px solid #dce5ed;background:linear-gradient(135deg,#f8fbfe,#eef5fb);border-radius:16px;padding:14px 16px;margin:0 0 14px}
      .lc-role-workspace strong{display:block;color:#0b2d4d;font-size:18px;margin-bottom:4px}
      .lc-role-workspace span{color:#5f7182;font-size:13px;line-height:1.45}
      #dashboardPage .grid .metric{min-height:92px}
      #dashboardPage .grid .metric strong{font-size:20px}
      #dashboardPage .grid .metric .muted{display:block;margin-top:5px;line-height:1.35}
      @media(max-width:720px){#dashboardPage .grid{grid-template-columns:1fr!important}.lc-role-workspace{padding:13px}}
    `;
    document.head.appendChild(s);
  }

  function setDescription(id,text){
    const tile=byId(id);const muted=tile?.querySelector('.muted');if(muted) muted.textContent=text;
  }

  function assistantAllowed(){
    return typeof window.userCanUseAssistant==='function'
      ? window.userCanUseAssistant()
      : ['admin','owner'].includes(role());
  }

  function syncAssistantVisibility(){
    const launcher=byId('assistantLauncher');
    const panel=byId('assistantPanel');
    const dashboard=byId('dashboardPage');
    if(!launcher) return;
    const allowed=assistantAllowed();
    const signedIn=!!(window.currentProfile || (typeof currentProfile!=='undefined' && currentProfile));
    launcher.classList.toggle('hidden',!(signedIn && allowed));
    if(!(signedIn && allowed)){
      panel?.classList.add('hidden');
      launcher.setAttribute('aria-expanded','false');
    }
    if(dashboard && !dashboard.classList.contains('hidden') && allowed) launcher.setAttribute('data-leadership-assistant-ready','true');
    else launcher.removeAttribute('data-leadership-assistant-ready');
  }

  function syncForemanCrewTimeOnly(){
    const hideLegacyHours=role()==='foreman';
    ['dailyRegularHours','dailyOvertimeHours'].forEach(id=>{
      const input=byId(id);
      if(!input) return;
      const label=document.querySelector(`label[for="${id}"]`);
      label?.classList.toggle('hidden',hideLegacyHours);
      input.classList.toggle('hidden',hideLegacyHours);
      input.readOnly=hideLegacyHours;
      input.setAttribute('data-calculated-from-crew-time','true');
    });
    const crewCard=byId('dailyCrewTimeCard');
    if(crewCard && hideLegacyHours){
      crewCard.setAttribute('data-time-source','primary');
      const help=crewCard.querySelector('.tk-help');
      if(help&&!help.dataset.tkLaunchHelp){
        help.dataset.tkLaunchHelp='1';
        help.textContent='Your Foreman row appears first, followed by the assigned crew. Assigned equipment fills in automatically; change the dropdown only when someone uses a different unit that day. Enter Start and Stop in 24-hour time plus Lunch; LineCrew calculates hours for payroll. Per diem defaults on.';
      }
    }
  }

  function bindDailyReportHourUi(){
    const createBtn=byId('createDailyReportBtn');
    if(createBtn && !createBtn.dataset.crewTimeUiBound){
      createBtn.dataset.crewTimeUiBound='true';
      createBtn.addEventListener('click',()=>setTimeout(syncForemanCrewTimeOnly,0));
    }
  }

  function apply(){
    const dashboard=byId('dashboardPage');
    const grid=dashboard?.querySelector('.grid');
    const r=role();
    const plan=plans[r];
    syncAssistantVisibility();
    bindDailyReportHourUi();
    if(!dashboard||!grid||!plan) return;
    observer?.disconnect();
    try{
      addStyles();
      let banner=byId('lcRoleWorkspace');
      if(!banner){banner=document.createElement('div');banner.id='lcRoleWorkspace';banner.className='lc-role-workspace';grid.parentNode.insertBefore(banner,grid);}
      const bannerMarkup=`<strong>${plan.title}</strong><span>${plan.text}</span>`;
      if(banner.innerHTML!==bannerMarkup) banner.innerHTML=bannerMarkup;
      ['jobsTile','productionTile','safetyTile','priceBooksTile','teamTile','remainingUnitsTile','timekeepingTile','trainingTile'].forEach(id=>byId(id)?.classList.toggle('hidden',plan.hidden.includes(id)));
      const desiredTiles=plan.order.map(id=>byId(id)).filter(el=>el&&!el.classList.contains('hidden'));
      const desiredIds=desiredTiles.map(el=>el.id);
      const currentIds=Array.from(grid.children).filter(el=>desiredIds.includes(el.id)).map(el=>el.id);
      const tilesNeedReordering=desiredIds.length!==currentIds.length || desiredIds.some((id,index)=>id!==currentIds[index]);
      const preservePersonalOrder=['admin','owner'].includes(r) &&
        (grid.dataset.userDashboardCustomOrder==='true' || grid.classList.contains('dashboard-arrange-active'));
      if(tilesNeedReordering&&!preservePersonalOrder) desiredTiles.forEach(el=>grid.appendChild(el));
      if(r==='foreman'){
        setDescription('jobsTile','Open assigned jobs and work points');
        setDescription('productionTile','Create and review your Daily Reports');
        setDescription('safetyTile','Complete today’s JSA and safety records');
        setDescription('remainingUnitsTile','What is left by job and work point');
        setDescription('timekeepingTile','Review your crew hours and per diem');
        setDescription('trainingTile','How-to videos for Foreman tasks');
      }else if(r==='gf'){
        setDescription('productionTile','Review and approve crew Daily Reports');
        setDescription('jobsTile','Manage jobs, work points and crew progress');
        setDescription('safetyTile','Review field safety and JSA records');
        setDescription('timekeepingTile','Review crew hours and reporting');
        setDescription('teamTile','View company crews and Foremen');
      }else{
        setDescription('teamTile','People, roles and company access');
        setDescription('priceBooksTile','Contracts, pricing and unit catalogs');
        setDescription('jobsTile','Job setup, imports, assignments and progress');
        setDescription('productionTile','Production oversight, review and reporting');
        setDescription('safetyTile','JSA and safety reporting');
        setDescription('timekeepingTile','Crew hours, payroll and billing exports');
      }
      if(typeof window.userHasCapability==='function' && r==='superintendent'){
        const pb=byId('priceBooksTile');if(pb) pb.classList.toggle('hidden',!window.userHasCapability('price_books'));
      }
      syncAssistantVisibility();
      bindDailyReportHourUi();
      dashboard.dataset.roleWorkspace=r;
    }finally{observe();}
  }

  function schedule(){if(scheduled)return;scheduled=true;setTimeout(()=>{scheduled=false;apply();},0);}

  function init(){
    observer=new MutationObserver(schedule);
    observe();
    schedule();
    [120,500,1200,2500].forEach(delay=>setTimeout(()=>{syncAssistantVisibility();bindDailyReportHourUi();schedule();},delay));
    document.addEventListener('visibilitychange',()=>{if(!document.hidden){syncAssistantVisibility();bindDailyReportHourUi();schedule();}});
    window.addEventListener('focus',()=>{syncAssistantVisibility();bindDailyReportHourUi();schedule();});
    setInterval(()=>{syncAssistantVisibility();bindDailyReportHourUi();},3000);
  }
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',init);else init();
})();

(() => {
  if(document.querySelector('script[data-lc-gf-theme-enhancements]')) return;
  const script=document.createElement('script');
  script.src='/gf-review-theme-enhancements.js';
  script.defer=true;
  script.dataset.lcGfThemeEnhancements='1';
  document.head.appendChild(script);
})();

(() => {
  if(document.querySelector('script[data-lc-dark-draft-fix]')) return;
  const script=document.createElement('script');
  script.src='/dark-contrast-draft-edit-fix.js';
  script.defer=true;
  script.dataset.lcDarkDraftFix='1';
  document.head.appendChild(script);
})();

/* Mobile pull-to-refresh for safe, read-oriented app screens. */
(() => {
  'use strict';

  const byId=id=>document.getElementById(id);
  const mobilePointer=()=>window.matchMedia('(pointer: coarse)').matches && window.innerWidth<=900;
  const visible=id=>{const el=byId(id);return !!el&&!el.classList.contains('hidden');};
  const call=async(name,...args)=>{
    const fn=window[name];
    if(typeof fn==='function') return fn(...args);
  };
  const wait=ms=>new Promise(resolve=>setTimeout(resolve,ms));
  const editors={
    productionPage:['dailyReportForm','dailyUnitEditor'],
    safetyPage:['companyJsaUploadForm','safetyJsaForm'],
    jobsPage:['createJobCard','jobPackageFormCard','jobPackageImportForm'],
    completedJobsPage:['completedJobDetail'],
    priceBooksPage:['customerForm','contractForm','priceBookForm','editPriceBookDetailsForm','duplicatePriceBookForm','priceBookItemForm']
  };
  let startY=0;
  let startX=0;
  let distance=0;
  let gesture=null;
  let refreshing=false;
  let hideTimer=null;
  let teamRoleDirty=false;

  function role(){
    try{return String(currentProfile?.role||'').toLowerCase();}
    catch(_){return String(window.currentProfile?.role||'').toLowerCase();}
  }

  function activePage(){
    return ['dashboardPage','productionPage','safetyPage','jobsPage','completedJobsPage','remainingUnitsPage','timekeepingPage','priceBooksPage','teamPage']
      .find(visible)||null;
  }

  function pageIsBlocked(page){
    if(!navigator.onLine) return 'Reconnect to refresh.';
    if((editors[page]||[]).some(visible)){
      return 'Finish or cancel your current work before refreshing.';
    }
    if(page==='timekeepingPage'&&byId('tkSaveAssignmentsBtn')?.disabled===false){
      return 'Save the pending crew assignments before refreshing.';
    }
    if(page==='teamPage'&&teamRoleDirty){
      return 'Save the pending role change before refreshing.';
    }
    return '';
  }

  function addUi(){
    if(byId('lcPullRefreshIndicator')) return;
    const style=document.createElement('style');
    style.id='lcPullRefreshStyles';
    style.textContent=`
      #lcPullRefreshIndicator{position:fixed;z-index:10020;left:50%;top:calc(env(safe-area-inset-top,0px) + 8px);transform:translate(-50%,-72px);display:flex;align-items:center;gap:8px;max-width:calc(100vw - 28px);padding:9px 13px;border-radius:999px;background:#0b2d4d;color:#fff;box-shadow:0 6px 20px rgba(4,24,42,.28);font-size:12px;font-weight:800;opacity:0;pointer-events:none;transition:transform .16s ease,opacity .16s ease}
      #lcPullRefreshIndicator.visible{opacity:1}
      #lcPullRefreshIndicator.blocked{background:#8a4b08}
      #lcPullRefreshIndicator.success{background:#18764a}
      #lcPullRefreshIndicator .lc-pull-spinner{width:14px;height:14px;border:2px solid rgba(255,255,255,.4);border-top-color:#fff;border-radius:50%}
      #lcPullRefreshIndicator.refreshing .lc-pull-spinner{animation:lcPullSpin .7s linear infinite}
      @keyframes lcPullSpin{to{transform:rotate(360deg)}}
      @media(pointer:fine),(min-width:901px){#lcPullRefreshIndicator{display:none!important}}
    `;
    const indicator=document.createElement('div');
    indicator.id='lcPullRefreshIndicator';
    indicator.setAttribute('role','status');
    indicator.setAttribute('aria-live','polite');
    indicator.innerHTML='<span class="lc-pull-spinner" aria-hidden="true"></span><span class="lc-pull-label">Pull to refresh</span>';
    document.head.appendChild(style);
    document.body.appendChild(indicator);
  }

  function showIndicator(message,pull=72,state=''){
    addUi();
    const indicator=byId('lcPullRefreshIndicator');
    clearTimeout(hideTimer);
    indicator.className=`visible ${state}`.trim();
    indicator.querySelector('.lc-pull-label').textContent=message;
    const offset=Math.max(-62,Math.min(12,-62+pull*.72));
    indicator.style.transform=`translate(-50%,${offset}px)`;
  }

  function hideIndicator(delay=0){
    clearTimeout(hideTimer);
    hideTimer=setTimeout(()=>{
      const indicator=byId('lcPullRefreshIndicator');
      if(!indicator) return;
      indicator.className='';
      indicator.style.transform='translate(-50%,-72px)';
    },delay);
  }

  async function refreshPage(page){
    if(page==='dashboardPage'){
      const tasks=[call('loadCompanyOnboarding'),call('loadPushNotificationStatus'),call('loadGfNotificationPreference')];
      if(role()==='gf'&&typeof window.linecrewRefreshGfProductionBadge==='function'){
        tasks.push(window.linecrewRefreshGfProductionBadge());
      }else{
        tasks.push(call('loadDashboardReviewAlert'));
      }
      await Promise.allSettled(tasks);
      return;
    }
    if(page==='productionPage') return call('loadProductionReports');
    if(page==='safetyPage'){
      await Promise.allSettled([call('loadSafetyJsas'),call('loadUploadedCompanyJsas')]);
      return;
    }
    if(page==='jobsPage') return call('loadJobs');
    if(page==='teamPage') return call('loadTeamMembers');
    if(page==='completedJobsPage') return call('loadCompletedJobs');
    if(page==='priceBooksPage'){
      await Promise.allSettled([call('loadCustomers'),call('loadContracts'),call('loadPriceBooks')]);
      return;
    }
    if(page==='remainingUnitsPage'){
      byId('remainingUnitsRefresh')?.click();
      await wait(700);
      return;
    }
    if(page==='timekeepingPage'){
      if(window.LineCrewTimekeepingReport?.run) await window.LineCrewTimekeepingReport.run();
      else{byId('tkRunReportBtn')?.click();await wait(700);}
    }
  }

  async function completeRefresh(page){
    if(refreshing) return;
    refreshing=true;
    showIndicator('Refreshing…',100,'refreshing');
    try{
      await refreshPage(page);
      window.dispatchEvent(new CustomEvent('linecrew:mobile-data-refreshed',{detail:{page}}));
      showIndicator('Updated',100,'success');
      hideIndicator(850);
    }catch(error){
      console.warn('Mobile pull-to-refresh failed:',error?.message||error);
      showIndicator('Could not refresh. Try again.',100,'blocked');
      hideIndicator(1500);
    }finally{
      refreshing=false;
    }
  }

  function ignoreTarget(target){
    return !!target?.closest?.('input,textarea,select,button,a,canvas,[contenteditable="true"],[role="button"]');
  }

  function onStart(event){
    if(refreshing||!mobilePointer()||event.touches.length!==1||window.scrollY>1||ignoreTarget(event.target)) return;
    const page=activePage();
    if(!page) return;
    startY=event.touches[0].clientY;
    startX=event.touches[0].clientX;
    distance=0;
    gesture={page,blocked:pageIsBlocked(page)};
  }

  function onMove(event){
    if(!gesture||event.touches.length!==1) return;
    const dy=event.touches[0].clientY-startY;
    const dx=Math.abs(event.touches[0].clientX-startX);
    if(dy<=0||dx>Math.max(28,dy*.75)){gesture=null;hideIndicator();return;}
    if(window.scrollY>1){gesture=null;hideIndicator();return;}
    distance=Math.min(112,dy*.58);
    if(dy>8) event.preventDefault();
    if(gesture.blocked){
      showIndicator(gesture.blocked,distance,'blocked');
    }else{
      showIndicator(distance>=72?'Release to refresh':'Pull to refresh',distance);
    }
  }

  function onEnd(){
    if(!gesture) return;
    const current=gesture;
    gesture=null;
    if(current.blocked){hideIndicator(900);return;}
    if(distance>=72) void completeRefresh(current.page);
    else hideIndicator();
  }

  function init(){
    addUi();
    document.addEventListener('change',event=>{
      if(event.target?.matches?.('#teamPage .team-role-select')) teamRoleDirty=true;
    });
    const teamList=byId('teamList');
    if(teamList){
      new MutationObserver(()=>{teamRoleDirty=false;}).observe(teamList,{childList:true});
    }
    document.addEventListener('touchstart',onStart,{passive:true});
    document.addEventListener('touchmove',onMove,{passive:false});
    document.addEventListener('touchend',onEnd,{passive:true});
    document.addEventListener('touchcancel',()=>{gesture=null;hideIndicator();},{passive:true});
  }

  if(document.readyState==='loading') document.addEventListener('DOMContentLoaded',init);
  else init();
})();
