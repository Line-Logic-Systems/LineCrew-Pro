from pathlib import Path

p = Path('index.html')
s = p.read_text()

old = """const result=await sb.from('daily_reports')
.select(reportSelect,{count:fetched===0?'exact':undefined})
.eq('company_id',currentProfile.company_id)
.order('work_date',{ascending:false})
.order('created_at',{ascending:false})
.range(fetched,through);"""
new = """let reportQuery=sb.from('daily_reports')
.select(reportSelect,{count:fetched===0?'exact':undefined})
.eq('company_id',currentProfile.company_id);
if(gfReviewWorkspace && window.linecrewGfCrewScope?.ensureLoaded){
await window.linecrewGfCrewScope.ensureLoaded();
if(window.linecrewGfCrewScope.shouldScope()){
const assignedForemen=window.linecrewGfCrewScope.foremanIds();
if(assignedForemen.length) reportQuery=reportQuery.in('foreman_id',assignedForemen);
}
}
const result=await reportQuery
.order('work_date',{ascending:false})
.order('created_at',{ascending:false})
.range(fetched,through);"""
if old not in s:
    raise SystemExit('production query anchor not found')
s = s.replace(old, new, 1)

old = "const { data, error } = await sb.rpc('get_company_jsas');"
new = """if(window.linecrewGfCrewScope?.ensureLoaded) await window.linecrewGfCrewScope.ensureLoaded();
const gfShowAll=currentUserRole()==='gf' && Boolean(window.linecrewGfCrewScope?.showAll?.());
const { data, error } = await sb.rpc('get_company_jsas_scoped',{p_show_all:gfShowAll});"""
if old not in s:
    raise SystemExit('JSA RPC anchor not found')
s = s.replace(old, new, 1)
p.write_text(s)

p = Path('expanded-jsa.js')
s = p.read_text()
anchor = "  load('role-workspace-polish.js?v=20260823a');\n"
line = "  load('gf-crew-scope.js?v=20260826a');\n"
if line not in s:
    if anchor not in s:
        raise SystemExit('expanded loader anchor not found')
    s = s.replace(anchor, anchor + line, 1)
p.write_text(s)

p = Path('gf-crew-scope.js')
s = p.read_text()
anchor = """  async function refreshUi(){
    addStyles();"""
pagination = r'''  let jsaHistoryPage=1;
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

'''
if pagination not in s:
    if anchor not in s:
        raise SystemExit('scope refresh anchor not found')
    s = s.replace(anchor, pagination + anchor, 1)
s = s.replace("    installJsaHistoryControls();\n  }", "    installJsaHistoryControls();\n    installJsaPaginationReset();\n    paginateJsaHistory();\n  }", 1)
p.write_text(s)
