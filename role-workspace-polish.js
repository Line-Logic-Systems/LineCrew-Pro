/* LineCrew Pro - role-specific workspace polish */
(() => {
  'use strict';
  const byId=id=>document.getElementById(id);
  const role=()=>String(window.currentProfile?.role || (typeof currentProfile!=='undefined' ? currentProfile?.role : '') || '').toLowerCase();
  const plans={
    foreman:{
      title:'Foreman Workspace',
      text:'Start the day with Safety/JSA, then use Jobs, Production and Timekeeping for your crew.',
      order:['safetyTile','jobsTile','productionTile','timekeepingTile','trainingTile'],
      hidden:['teamTile','priceBooksTile']
    },
    gf:{
      title:'General Foreman Workspace',
      text:'Review crews, jobs, production, safety and timekeeping from one place.',
      order:['productionTile','jobsTile','safetyTile','timekeepingTile','teamTile','trainingTile'],
      hidden:['priceBooksTile']
    },
    superintendent:{
      title:'Superintendent Workspace',
      text:'Manage field operations, crews, jobs, production, safety and company tools available to your permissions.',
      order:['productionTile','jobsTile','teamTile','safetyTile','timekeepingTile','priceBooksTile','trainingTile'],
      hidden:[]
    },
    admin:{
      title:'Admin Workspace',
      text:'Manage company setup, people, pricing, jobs, production, safety and timekeeping.',
      order:['teamTile','priceBooksTile','jobsTile','productionTile','safetyTile','timekeepingTile','trainingTile'],
      hidden:[]
    },
    owner:{
      title:'Owner Workspace',
      text:'Company-wide access for people, pricing, jobs, production, safety and timekeeping.',
      order:['teamTile','priceBooksTile','jobsTile','productionTile','safetyTile','timekeepingTile','trainingTile'],
      hidden:[]
    }
  };
  let observer=null;
  let scheduled=false;

  function observe(){
    observer?.observe(document.body,{
      subtree:true,
      childList:true,
      attributes:true,
      attributeFilter:['class']
    });
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
    return ['admin','owner'].includes(role());
  }

  // Keep the core app role gate aligned with the workspace gate.
  window.userCanUseAssistant=assistantAllowed;

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

    if(dashboard && !dashboard.classList.contains('hidden') && allowed){
      launcher.setAttribute('data-leadership-assistant-ready','true');
    }else{
      launcher.removeAttribute('data-leadership-assistant-ready');
    }
  }

  function apply(){
    const dashboard=byId('dashboardPage');
    const grid=dashboard?.querySelector('.grid');
    const r=role();
    const plan=plans[r];
    syncAssistantVisibility();
    if(!dashboard||!grid||!plan) return;

    observer?.disconnect();
    try{
      addStyles();
      let banner=byId('lcRoleWorkspace');
      if(!banner){
        banner=document.createElement('div');
        banner.id='lcRoleWorkspace';
        banner.className='lc-role-workspace';
        grid.parentNode.insertBefore(banner,grid);
      }
      const bannerMarkup=`<strong>${plan.title}</strong><span>${plan.text}</span>`;
      if(banner.innerHTML!==bannerMarkup) banner.innerHTML=bannerMarkup;

      ['jobsTile','productionTile','safetyTile','priceBooksTile','teamTile','timekeepingTile','trainingTile'].forEach(id=>{
        byId(id)?.classList.toggle('hidden',plan.hidden.includes(id));
      });

      const desiredTiles=plan.order
        .map(id=>byId(id))
        .filter(el=>el&&!el.classList.contains('hidden'));
      const desiredIds=desiredTiles.map(el=>el.id);
      const currentIds=Array.from(grid.children)
        .filter(el=>desiredIds.includes(el.id))
        .map(el=>el.id);
      const tilesNeedReordering=
        desiredIds.length!==currentIds.length ||
        desiredIds.some((id,index)=>id!==currentIds[index]);

      if(tilesNeedReordering){
        desiredTiles.forEach(el=>grid.appendChild(el));
      }

      if(r==='foreman'){
        setDescription('jobsTile','Open assigned jobs and work points');
        setDescription('productionTile','Create and review your Daily Reports');
        setDescription('safetyTile','Complete today’s JSA and safety records');
        setDescription('timekeepingTile','Enter and review your crew hours');
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
        setDescription('jobsTile','Create and manage jobs and work points');
        setDescription('productionTile','Daily production reporting and review');
        setDescription('safetyTile','JSA and safety reporting');
        setDescription('timekeepingTile','Crew hours, payroll and billing exports');
      }

      if(typeof window.userHasCapability==='function' && r==='superintendent'){
        const pb=byId('priceBooksTile');
        if(pb) pb.classList.toggle('hidden',!window.userHasCapability('price_books'));
      }

      syncAssistantVisibility();
      dashboard.dataset.roleWorkspace=r;
    }finally{
      observe();
    }
  }

  function schedule(){
    if(scheduled) return;
    scheduled=true;
    setTimeout(()=>{scheduled=false;apply();},0);
  }

  function init(){
    observer=new MutationObserver(schedule);
    observe();
    schedule();
    [120,500,1200,2500].forEach(delay=>setTimeout(()=>{syncAssistantVisibility();schedule();},delay));
    document.addEventListener('visibilitychange',()=>{if(!document.hidden){syncAssistantVisibility();schedule();}});
    window.addEventListener('focus',()=>{syncAssistantVisibility();schedule();});
    setInterval(syncAssistantVisibility,3000);
  }
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',init);else init();
})();
