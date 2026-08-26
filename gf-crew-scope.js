/* LineCrew Pro - General Foreman crew scope + compact JSA history controls */
(() => {
  'use strict';

  const byId = id => document.getElementById(id);
  const esc = value => String(value ?? '').replace(/[&<>"']/g, ch => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));
  const getSb = () => typeof sb !== 'undefined' ? sb : window.sb;
  const profile = () => typeof currentProfile !== 'undefined' ? currentProfile : null;
  const role = () => String(profile()?.role || '').toLowerCase();
  const userId = () => profile()?.id || null;

  let assignmentRows = [];
  let generalForemen = [];
  let loadedForCompany = null;
  let loadPromise = null;
  let observerTimer = null;

  function showAll(){
    return sessionStorage.getItem('linecrew-gf-show-all-crews') === '1';
  }

  function foremanIds(){
    const id = userId();
    return assignmentRows
      .filter(row => row.gf_id === id)
      .map(row => row.foreman_id)
      .filter(Boolean);
  }

  function shouldScope(){
    return role() === 'gf' && !showAll() && foremanIds().length > 0;
  }

  async function ensureLoaded(force=false){
    const companyId = profile()?.company_id || null;
    if(!companyId || !getSb()) return [];
    if(!force && loadedForCompany === companyId && assignmentRows.length >= 0) return assignmentRows;
    if(loadPromise && !force) return loadPromise;
    loadPromise = (async () => {
      const [assignmentsResult, gfResult] = await Promise.all([
        getSb().rpc('get_gf_crew_assignment_roster'),
        getSb().rpc('get_company_general_foremen')
      ]);
      if(assignmentsResult.error){
        console.warn('Unable to load GF crew assignments:', assignmentsResult.error.message);
        assignmentRows = [];
      }else{
        assignmentRows = assignmentsResult.data || [];
      }
      if(gfResult.error){
        console.warn('Unable to load General Foremen:', gfResult.error.message);
        generalForemen = [];
      }else{
        generalForemen = gfResult.data || [];
      }
      loadedForCompany = companyId;
      return assignmentRows;
    })();
    try{return await loadPromise;}finally{loadPromise=null;}
  }

  async function setShowAll(value){
    if(value) sessionStorage.setItem('linecrew-gf-show-all-crews','1');
    else sessionStorage.removeItem('linecrew-gf-show-all-crews');
    updateScopeBars();
    if(role() !== 'gf') return;
    if(!byId('productionPage')?.classList.contains('hidden') && typeof loadProductionReports === 'function'){
      await loadProductionReports();
    }
    if(!byId('safetyPage')?.classList.contains('hidden') && typeof loadSafetyJsas === 'function'){
      await loadSafetyJsas();
    }
  }

  window.linecrewGfCrewScope = {
    ensureLoaded,
    foremanIds,
    shouldScope,
    showAll,
    setShowAll
  };

  function addStyles(){
    if(byId('gfCrewScopeStyles')) return;
    const style=document.createElement('style');
    style.id='gfCrewScopeStyles';
    style.textContent=`
      .gf-scope-bar{display:flex;align-items:center;justify-content:space-between;gap:10px;padding:7px 10px;margin:8px 0 10px;border:1px solid #dce5ed;border-radius:9px;background:#f8fbfe;font-size:12px}
      .gf-scope-bar strong{font-size:12px}
      .gf-scope-bar button{width:auto;margin:0;padding:6px 9px;font-size:11px}
      .gf-assignment-card{margin-top:12px}
      .gf-assignment-card summary{cursor:pointer;font-weight:800}
      .gf-assignment-help{font-size:12px;color:#657789;margin:8px 0}
      .gf-assignment-search{margin:8px 0;padding:9px 10px;font-size:13px}
      .gf-assignment-list{max-height:360px;overflow:auto;border:1px solid #dce5ed;border-radius:10px;background:#fff}
      .gf-assignment-row{display:grid;grid-template-columns:minmax(150px,1fr) minmax(180px,1fr) auto;gap:8px;align-items:center;padding:7px 9px;border-bottom:1px solid #edf2f6;font-size:12px}
      .gf-assignment-row:last-child{border-bottom:0}
      .gf-assignment-row select{margin:0;padding:7px 8px;font-size:12px}
      .gf-assignment-status{min-width:48px;color:#607386;font-size:11px;text-align:right}
      .jsa-quick-history{display:flex;align-items:center;flex-wrap:wrap;gap:6px;padding:7px 0 9px;margin:0 0 8px}
      .jsa-quick-history button,.jsa-quick-history select{width:auto;margin:0;padding:6px 8px;font-size:11px}
      .jsa-history-note{font-size:11px;color:#657789;margin-right:auto}
      @media(max-width:650px){.gf-assignment-row{grid-template-columns:1fr}.gf-assignment-status{text-align:left}.gf-scope-bar{align-items:flex-start;flex-direction:column}}
    `;
    document.head.appendChild(style);
  }

  function scopeText(){
    const mine=foremanIds().length;
    if(!mine) return 'No crews assigned yet — showing all company crews';
    if(showAll()) return `Coverage mode — showing all company crews (${mine} normally assigned to you)`;
    return `My assigned crews only — ${mine} Foreman crew${mine===1?'':'s'}`;
  }

  function installScopeBar(pageId,barId){
    if(role()!=='gf'){
      byId(barId)?.remove();
      return;
    }
    const page=byId(pageId);
    if(!page || byId(barId)) return;
    const bar=document.createElement('div');
    bar.id=barId;
    bar.className='gf-scope-bar';
    const toolbar=page.querySelector('.toolbar');
    if(toolbar?.nextSibling) toolbar.parentNode.insertBefore(bar,toolbar.nextSibling);
    else page.prepend(bar);
    bar.addEventListener('click',async event=>{
      const button=event.target.closest('button');
      if(!button) return;
      await setShowAll(!showAll());
    });
  }

  function updateScopeBars(){
    ['gfProductionScopeBar','gfSafetyScopeBar'].forEach(id=>{
      const bar=byId(id);
      if(!bar) return;
      const mine=foremanIds().length;
      bar.innerHTML=`<div><strong>GF Crew View:</strong> ${esc(scopeText())}</div>`+
        (mine ? `<button type="button" class="secondary small">${showAll()?'Show My Crews':'Show All Crews'}</button>` : '');
    });
  }

  function gfOptions(selected){
    return '<option value="">Unassigned</option>' + generalForemen.map(gf =>
      `<option value="${esc(gf.id)}" ${gf.id===selected?'selected':''}>${esc(gf.full_name || 'General Foreman')}</option>`
    ).join('');
  }

  function renderAssignmentRows(query=''){
    const list=byId('gfAssignmentList');
    if(!list) return;
    const needle=String(query||'').trim().toLowerCase();
    const rows=assignmentRows.filter(row => !needle || [row.foreman_name,row.gf_name].some(v=>String(v||'').toLowerCase().includes(needle)));
    list.innerHTML=rows.length ? rows.map(row=>
      `<div class="gf-assignment-row" data-foreman-id="${esc(row.foreman_id)}">`+
      `<strong>${esc(row.foreman_name || 'Foreman')} Crew</strong>`+
      `<select aria-label="General Foreman for ${esc(row.foreman_name || 'Foreman')}">${gfOptions(row.gf_id || '')}</select>`+
      `<span class="gf-assignment-status"></span></div>`
    ).join('') : '<div class="gf-assignment-row"><span>No Foreman crews match this search.</span></div>';
  }

  async function saveAssignment(rowEl,select){
    const foremanId=rowEl.dataset.foremanId;
    const status=rowEl.querySelector('.gf-assignment-status');
    const gfId=select.value || null;
    select.disabled=true;
    status.textContent='Saving…';
    const {error}=await getSb().rpc('set_gf_crew_assignment',{p_foreman_id:foremanId,p_gf_id:gfId});
    select.disabled=false;
    if(error){
      status.textContent='Error';
      alert('Unable to save GF crew assignment: '+error.message);
      return;
    }
    status.textContent='Saved';
    await ensureLoaded(true);
    updateScopeBars();
    setTimeout(()=>{if(status) status.textContent='';},1400);
  }

  async function installAdminAssignments(){
    if(!['admin','owner'].includes(role())){
      byId('gfAssignmentCard')?.remove();
      return;
    }
    const teamPage=byId('teamPage');
    if(!teamPage || byId('gfAssignmentCard')) return;
    await ensureLoaded();
    const card=document.createElement('details');
    card.id='gfAssignmentCard';
    card.className='card gf-assignment-card';
    card.innerHTML=`<summary>General Foreman Crew Assignments</summary>`+
      `<div class="gf-assignment-help">Assign each Foreman crew to its normal General Foreman. That GF will see those crews first for Daily Report approvals and JSAs, with a temporary Show All Crews coverage option when needed.</div>`+
      `<input id="gfAssignmentSearch" class="gf-assignment-search" type="search" placeholder="Search Foreman or General Foreman">`+
      `<div id="gfAssignmentList" class="gf-assignment-list"></div>`;
    const toolbar=teamPage.querySelector('.toolbar');
    if(toolbar?.nextSibling) toolbar.parentNode.insertBefore(card,toolbar.nextSibling);
    else teamPage.prepend(card);
    renderAssignmentRows();
    byId('gfAssignmentSearch').addEventListener('input',e=>renderAssignmentRows(e.target.value));
    byId('gfAssignmentList').addEventListener('change',e=>{
      const select=e.target.closest('select');
      const row=select?.closest('.gf-assignment-row');
      if(select&&row) saveAssignment(row,select);
    });
  }

  function localIsoDate(date=new Date()){
    const copy=new Date(date.getTime()-date.getTimezoneOffset()*60000);
    return copy.toISOString().slice(0,10);
  }

  function setJsaRange(from,through){
    const fromInput=byId('safetyJsaFromDate');
    const throughInput=byId('safetyJsaThroughDate');
    if(!fromInput||!throughInput) return;
    fromInput.value=from||'';
    throughInput.value=through||'';
    if(typeof renderSafetyJsas==='function') renderSafetyJsas();
  }

  function startOfWeek(date){
    const d=new Date(date);
    const day=d.getDay();
    const diff=(day+6)%7;
    d.setDate(d.getDate()-diff);
    return d;
  }

  function installJsaHistoryControls(){
    if(!['gf','admin','owner','superintendent'].includes(role())) return;
    const filters=byId('safetyJsaFiltersCard');
    if(!filters || byId('jsaQuickHistory')) return;
    const bar=document.createElement('div');
    bar.id='jsaQuickHistory';
    bar.className='jsa-quick-history';
    const year=new Date().getFullYear();
    const years=[];
    for(let y=year;y>=year-10;y--) years.push(`<option value="${y}">${y}</option>`);
    bar.innerHTML=`<span class="jsa-history-note">Completed JSAs:</span>`+
      `<button type="button" data-jsa-range="today">Today</button>`+
      `<button type="button" class="secondary" data-jsa-range="yesterday">Yesterday</button>`+
      `<button type="button" class="secondary" data-jsa-range="week">This Week</button>`+
      `<select id="jsaHistoryYear"><option value="">Year…</option>${years.join('')}</select>`+
      `<button type="button" class="secondary" data-jsa-range="all">All History</button>`;
    filters.parentNode.insertBefore(bar,filters.nextSibling);
    bar.addEventListener('click',event=>{
      const button=event.target.closest('[data-jsa-range]');
      if(!button) return;
      const mode=button.dataset.jsaRange;
      const now=new Date();
      if(mode==='today') setJsaRange(localIsoDate(now),localIsoDate(now));
      if(mode==='yesterday'){
        const d=new Date(now);d.setDate(d.getDate()-1);setJsaRange(localIsoDate(d),localIsoDate(d));
      }
      if(mode==='week') setJsaRange(localIsoDate(startOfWeek(now)),localIsoDate(now));
      if(mode==='all') setJsaRange('','');
    });
    byId('jsaHistoryYear').addEventListener('change',event=>{
      const y=Number(event.target.value||0);
      if(y) setJsaRange(`${y}-01-01`,`${y}-12-31`);
    });

    const from=byId('safetyJsaFromDate');
    const through=byId('safetyJsaThroughDate');
    if(from && through && !from.value && !through.value && !sessionStorage.getItem('linecrew-jsa-date-initialized')){
      const today=localIsoDate();
      from.value=today;
      through.value=today;
      sessionStorage.setItem('linecrew-jsa-date-initialized','1');
      if(typeof renderSafetyJsas==='function') renderSafetyJsas();
    }
  }

  let jsaHistoryPage=1;
  const JSA_HISTORY_PAGE_SIZE=25;

  function paginateJsaHistory(){
    const list=byId('safetyJsaList');
    if(!list) return;
    const rows=Array.from(list.children).filter(node=>node.matches?.('details'));
    byId('jsaHistoryPager')?.remove();
    const pages=Math.max(1,Math.ceil(rows.length/JSA_HISTORY_PAGE_SIZE));
    if(jsaHistoryPage>pages) jsaHistoryPage=pages;
    rows.forEach((row,index)=>{
      row.style.display=(index>=(jsaHistoryPage-1)*JSA_HISTORY_PAGE_SIZE && index<jsaHistoryPage*JSA_HISTORY_PAGE_SIZE)?'':'none';
    });
    if(rows.length<=JSA_HISTORY_PAGE_SIZE) return;
    const pager=document.createElement('div');
    pager.id='jsaHistoryPager';
    pager.className='gf-scope-bar';
    pager.innerHTML=`<span>Showing ${Math.min((jsaHistoryPage-1)*JSA_HISTORY_PAGE_SIZE+1,rows.length)}–${Math.min(jsaHistoryPage*JSA_HISTORY_PAGE_SIZE,rows.length)} of ${rows.length} JSAs</span><div><button type="button" class="secondary small" data-jsa-page="prev" ${jsaHistoryPage<=1?'disabled':''}>Previous</button> <button type="button" class="secondary small" data-jsa-page="next" ${jsaHistoryPage>=pages?'disabled':''}>Next</button></div>`;
    list.parentNode.insertBefore(pager,list.nextSibling);
    pager.addEventListener('click',event=>{
      const action=event.target.closest('[data-jsa-page]')?.dataset.jsaPage;
      if(action==='prev'&&jsaHistoryPage>1) jsaHistoryPage--;
      if(action==='next'&&jsaHistoryPage<pages) jsaHistoryPage++;
      paginateJsaHistory();
    });
  }

  function installJsaPaginationReset(){
    ['safetyJsaSearch','safetyJsaFromDate','safetyJsaThroughDate'].forEach(id=>{
      const el=byId(id);
      if(!el || el.dataset.gfPageReset==='1') return;
      el.dataset.gfPageReset='1';
      el.addEventListener(id==='safetyJsaSearch'?'input':'change',()=>{jsaHistoryPage=1;setTimeout(paginateJsaHistory,0);});
    });
  }

  async function refreshUi(){
    addStyles();
    if(!profile()?.company_id) return;
    await ensureLoaded();
    installScopeBar('productionPage','gfProductionScopeBar');
    installScopeBar('safetyPage','gfSafetyScopeBar');
    updateScopeBars();
    installAdminAssignments();
    installJsaHistoryControls();
    installJsaPaginationReset();
    paginateJsaHistory();
  }

  function scheduleRefresh(){
    clearTimeout(observerTimer);
    observerTimer=setTimeout(refreshUi,80);
  }

  function init(){
    addStyles();
    scheduleRefresh();
    const observer=new MutationObserver(scheduleRefresh);
    observer.observe(document.body,{subtree:true,childList:true,attributes:true,attributeFilter:['class']});
    window.addEventListener('pageshow',scheduleRefresh);
  }

  if(document.readyState==='loading') document.addEventListener('DOMContentLoaded',init);
  else init();
})();
