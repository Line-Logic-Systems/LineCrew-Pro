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

  function apply(){
    const dashboard=byId('dashboardPage');
    const grid=dashboard?.querySelector('.grid');
    const r=role();
    const plan=plans[r];
    if(!dashboard||!grid||!plan) return;

    addStyles();
    let banner=byId('lcRoleWorkspace');
    if(!banner){
      banner=document.createElement('div');
      banner.id='lcRoleWorkspace';
      banner.className='lc-role-workspace';
      grid.parentNode.insertBefore(banner,grid);
    }
    banner.innerHTML=`<strong>${plan.title}</strong><span>${plan.text}</span>`;

    ['jobsTile','productionTile','safetyTile','priceBooksTile','teamTile','timekeepingTile','trainingTile'].forEach(id=>{
      const el=byId(id);if(el) el.classList.remove('hidden');
    });
    plan.hidden.forEach(id=>byId(id)?.classList.add('hidden'));

    plan.order.forEach(id=>{const el=byId(id);if(el&&!el.classList.contains('hidden')) grid.appendChild(el);});

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

    const launcher=byId('assistantLauncher');
    if(launcher) launcher.classList.toggle('hidden',r!=='admin');
    dashboard.dataset.roleWorkspace=r;
  }

  function schedule(){setTimeout(apply,0);setTimeout(apply,120);setTimeout(apply,500);}
  function init(){schedule();new MutationObserver(schedule).observe(document.body,{subtree:true,childList:true,attributes:true,attributeFilter:['class']});}
  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',init);else init();
})();
