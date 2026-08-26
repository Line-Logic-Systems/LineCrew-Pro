from pathlib import Path
p=Path('gf-crew-scope.js')
s=p.read_text()
s=s.replace("  let loadedForCompany = null;\n", "  let loadedForScope = null;\n  let adminAssignmentInstallPromise = null;\n", 1)
old="""    const companyId = profile()?.company_id || null;
    if(!companyId || !getSb()) return [];
    if(!force && loadedForCompany === companyId && assignmentRows.length >= 0) return assignmentRows;"""
new="""    const companyId = profile()?.company_id || null;
    const scopeKey = `${companyId || ''}:${userId() || ''}:${role() || ''}`;
    if(!companyId || !getSb()) return [];
    if(!force && loadedForScope === scopeKey && assignmentRows.length >= 0) return assignmentRows;"""
if old not in s: raise SystemExit('cache start anchor not found')
s=s.replace(old,new,1)
old="      loadedForCompany = companyId;\n"
new="      loadedForScope = scopeKey;\n"
if old not in s: raise SystemExit('cache assignment anchor not found')
s=s.replace(old,new,1)
old="""  async function installAdminAssignments(){
    if(!['admin','owner'].includes(role())){
      byId('gfAssignmentCard')?.remove();
      return;
    }
    const teamPage=byId('teamPage');
    if(!teamPage || byId('gfAssignmentCard')) return;
    await ensureLoaded();
    const card=document.createElement('details');"""
new="""  async function installAdminAssignments(){
    if(!['admin','owner'].includes(role())){
      document.querySelectorAll('#gfAssignmentCard').forEach(el=>el.remove());
      return;
    }
    const teamPage=byId('teamPage');
    if(!teamPage) return;
    const existingCards=teamPage.querySelectorAll('#gfAssignmentCard');
    if(existingCards.length){
      existingCards.forEach((el,index)=>{ if(index>0) el.remove(); });
      return;
    }
    if(adminAssignmentInstallPromise) return adminAssignmentInstallPromise;
    adminAssignmentInstallPromise=(async()=>{
      await ensureLoaded(true);
      if(teamPage.querySelector('#gfAssignmentCard')) return;
      const card=document.createElement('details');"""
if old not in s: raise SystemExit('install start anchor not found')
s=s.replace(old,new,1)
old="""    byId('gfAssignmentList').addEventListener('change',e=>{
      const select=e.target.closest('select');
      const row=select?.closest('.gf-assignment-row');
      if(select&&row) saveAssignment(row,select);
    });
  }
"""
new="""    byId('gfAssignmentList').addEventListener('change',e=>{
      const select=e.target.closest('select');
      const row=select?.closest('.gf-assignment-row');
      if(select&&row) saveAssignment(row,select);
    });
    })();
    try{ await adminAssignmentInstallPromise; }
    finally{ adminAssignmentInstallPromise=null; }
  }
"""
if old not in s: raise SystemExit('install end anchor not found')
s=s.replace(old,new,1)
p.write_text(s)
