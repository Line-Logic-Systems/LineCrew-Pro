/* LineCrew Pro - Timekeeping */
(() => {
  'use strict';

  const byId = (id) => document.getElementById(id);
  const esc = (value) => String(value ?? '').replace(/[&<>"']/g, (ch) => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));
  const number = (value) => Number(value || 0) || 0;
  const role = () => String(typeof currentProfile !== 'undefined' ? currentProfile?.role || '' : '').toLowerCase();
  const companyId = () => typeof currentProfile !== 'undefined' ? currentProfile?.company_id || null : null;
  const isLeader = () => ['gf','admin','owner'].includes(role());
  const canManageRoster = () => isLeader();
  const canViewCompleteRoster = () => ['admin','owner'].includes(role());
  const getSb = () => typeof sb !== 'undefined' ? sb : window.sb;
  const todayIso = () => new Date().toISOString().slice(0,10);
  const mondayIso = () => {
    const d = new Date();
    const day = (d.getDay() + 6) % 7;
    d.setDate(d.getDate() - day);
    return d.toISOString().slice(0,10);
  };

  let employees = [];
  let equipment = [];
  let foremen = [];
  let admins = [];
  let teamProfiles = [];
  let entries = [];
  let jobs = [];
  let crewRowsLoadedForReport = null;
  let crewRowCounter = 0;
  const rosterAssignmentDrafts = new Map();
  let rosterAssignmentsSaving = false;
  let completeRosterPeople = [];
  let completeRosterEquipment = [];
  const completeRosterFilters = {query:'',kind:'all',status:'all',assignment:'all',foreman:'all'};

  function addStyles(){
    if(byId('timekeepingStyles')) return;
    const style = document.createElement('style');
    style.id = 'timekeepingStyles';
    style.textContent = `
      .tk-grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:10px}
      .tk-summary{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:10px;margin:12px 0}
      .tk-summary>div{background:#f5f8fb;border:1px solid #dce5ed;border-radius:12px;padding:12px;text-align:center}
      .tk-summary strong{display:block;font-size:22px;color:#0b2d4d}
      .tk-table-wrap{overflow-x:auto}
      .tk-table{width:100%;border-collapse:collapse;min-width:760px}
      .tk-table th,.tk-table td{padding:9px 8px;border-bottom:1px solid #dce5ed;text-align:left;vertical-align:middle}
      .tk-table th{font-size:12px;text-transform:uppercase;color:#617284}
      .tk-table input,.tk-table select{padding:9px;margin:0;min-width:90px}
      .tk-row-actions button{width:auto;margin:0;padding:8px 10px}
      .tk-roster-savebar{display:flex;gap:10px;align-items:center;margin:12px 0;padding:8px 0;position:sticky;top:8px;z-index:3;background:var(--surface,#fff)}
      .tk-roster-savebar button{width:auto;margin:0}
      .tk-assignment-pending{background:#fff8df}
      .tk-complete-roster{border:1px solid #b9cad8;border-radius:14px;margin:14px 0;background:#f8fafc;overflow:hidden}
      .tk-complete-roster>summary{cursor:pointer;padding:13px 14px;font-weight:800;color:#0b2d4d}
      .tk-complete-roster-body{padding:0 14px 14px}
      .tk-roster-summary{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:8px;margin:10px 0 14px}
      .tk-roster-summary>div{background:#fff;border:1px solid #dce5ed;border-radius:10px;padding:10px;text-align:center}
      .tk-roster-summary strong{display:block;font-size:20px;color:#0b2d4d}
      .tk-complete-section{margin-top:16px}.tk-complete-section h4{margin:0 0 8px}
      .tk-roster-unassigned td{background:#fff8df}.tk-roster-inactive{opacity:.6}
      .tk-complete-tools{display:grid;grid-template-columns:minmax(180px,1.5fr) repeat(4,minmax(130px,.7fr));gap:8px;margin:12px 0}
      .tk-complete-tools input,.tk-complete-tools select{margin:0}
      .tk-complete-actions{display:flex;gap:8px;flex-wrap:wrap;margin:0 0 12px}.tk-complete-actions button{width:auto;margin:0}
      .tk-crew-card{border:1px solid #dce5ed;border-radius:14px;padding:14px;margin:14px 0;background:#f8fafc}
      .tk-crew-row{display:grid;grid-template-columns:minmax(180px,1.6fr) minmax(90px,.7fr) minmax(90px,.7fr) auto;gap:8px;align-items:end;margin:8px 0}
      .tk-crew-row label{margin:0;font-size:12px}
      .tk-crew-row button{width:auto;margin:0;padding:11px}
      .tk-hours-fallback{display:none!important}
      .tk-detail-row{grid-column:1/-1;display:grid;grid-template-columns:110px 110px 100px minmax(150px,1fr) auto auto;gap:10px;padding:8px 0 2px;border-top:1px solid #c2cdd7;align-items:end}
      .tk-detail-row label{font-size:11px;margin:0}.tk-detail-row input,.tk-detail-row select{margin:0;padding:8px}.tk-clock24{font-variant-numeric:tabular-nums;letter-spacing:.4px}
      .tk-detail-check{display:flex;gap:6px;align-items:center;padding-bottom:10px}.tk-detail-check input{width:auto;min-width:0}.tk-hours-worked{font-size:12px;color:#5f7080;grid-column:1/-1}
      .tk-help{font-size:13px;color:#6c7a89}
      .tk-inline-actions{display:flex;gap:8px;flex-wrap:wrap;align-items:center}
      .tk-inline-actions button{width:auto}
      @media(max-width:720px){.tk-grid,.tk-summary,.tk-roster-summary,.tk-complete-tools{grid-template-columns:1fr 1fr}.tk-complete-tools input{grid-column:1/-1}.tk-crew-row{grid-template-columns:1fr 1fr}.tk-crew-row .tk-person{grid-column:1/-1}.tk-detail-row{grid-template-columns:1fr 1fr}.tk-detail-row>label:nth-child(4){grid-column:1/-1}}
    `;
    document.head.appendChild(style);
  }

  function createPage(){
    if(byId('timekeepingPage')) return;
    const main = document.querySelector('main');
    if(!main) return;
    const section = document.createElement('section');
    section.id = 'timekeepingPage';
    section.className = 'hidden';
    section.innerHTML = `
      <div class="card">
        <div class="section-header">
          <div><h2>Timekeeping</h2><p class="muted">Crew time for payroll, billing and production reporting.</p></div>
          <button id="timekeepingBackBtn" class="secondary small">Back to Dashboard</button>
        </div>
      </div>
      <div id="timekeepingRosterCard" class="card hidden">
        <h3>Manage Personnel Assignments</h3>
        <p class="muted">Assign field employees to their Foreman crew and, independently, to an Admin time roster. Foreman crew members automatically appear on Daily Reports; Admin roster members automatically appear in that Admin's My Time workspace.</p>
        <details id="tkCompleteRoster" class="tk-complete-roster hidden">
          <summary id="tkCompleteRosterSummary">Complete Company Roster</summary>
          <div id="tkCompleteRosterBody" class="tk-complete-roster-body"></div>
        </details>
        <div class="tk-grid">
          <label>Employee #<input id="tkEmployeeNumber" type="text" placeholder="Optional"></label>
          <label>Employee Name<input id="tkEmployeeName" type="text" placeholder="Full name"></label>
          <label>Classification<input id="tkEmployeeClass" type="text" placeholder="Lineman, Operator, Groundman..."></label>
          <label>Default Crew<input id="tkEmployeeCrew" type="text" placeholder="Crew name / number"></label>
          <label>Assigned Foreman<select id="tkEmployeeForeman"><option value="">Unassigned</option></select></label>
          <label>Assigned Admin<select id="tkEmployeeAdmin"><option value="">Unassigned</option></select></label>
        </div>
        <button id="tkAddEmployeeBtn" class="success">Add Employee</button>
        <div class="tk-roster-savebar"><button id="tkSaveAssignmentsBtn" type="button" class="success" disabled>Save Crew Assignments</button><span id="tkRosterSaveStatus" class="muted">Choose assignments, then save them together.</span></div>
        <div id="tkRosterList" style="margin-top:12px"></div>
      </div>
      <div id="timekeepingReportCard" class="card">
        <h3>Time Report</h3>
        <div class="tk-grid">
          <label>From<input id="tkFromDate" type="date"></label>
          <label>Through<input id="tkThroughDate" type="date"></label>
          <label>Employee<select id="tkEmployeeFilter"><option value="">All employees</option></select></label>
          <label>Job<select id="tkJobFilter"><option value="">All jobs</option></select></label>
          <label>Charge To<select id="tkChargeFilter"><option value="">All charges</option><option value="job">Jobs only</option><option value="overhead">Overhead only</option></select></label>
          <label id="tkLaborCodeFilterWrap" class="hidden">Overhead Labor Code<select id="tkLaborCodeFilter"><option value="">All overhead codes</option></select></label>
        </div>
        <div class="tk-inline-actions">
          <button id="tkRunReportBtn">Run Report</button>
          <button id="tkExportCsvBtn" class="secondary">Export CSV</button>
        </div>
        <div id="tkSummary" class="tk-summary"></div>
        <div id="tkReportList"></div>
      </div>`;
    main.appendChild(section);

    byId('tkFromDate').value = mondayIso();
    byId('tkThroughDate').value = todayIso();
    byId('timekeepingBackBtn').onclick = () => {
      section.classList.add('hidden');
      if(typeof show === 'function') show('dashboardPage');
      else byId('dashboardPage')?.classList.remove('hidden');
    };
    byId('tkRunReportBtn').onclick = loadEntries;
    byId('tkExportCsvBtn').onclick = exportCsv;
    byId('tkAddEmployeeBtn').onclick = addEmployee;
    byId('tkSaveAssignmentsBtn').onclick = saveRosterAssignments;
  }

  function addTile(){
    const dashboard = byId('dashboardPage');
    if(!dashboard || byId('timekeepingTile')) return;
    const grid = dashboard.querySelector('.grid');
    if(!grid) return;
    const tile = document.createElement('div');
    tile.className = 'metric';
    tile.id = 'timekeepingTile';
    tile.setAttribute('role','link');
    tile.setAttribute('tabindex','0');
    tile.innerHTML = '<strong>Timekeeping</strong><span class="muted">Crew hours, payroll and billing exports</span>';
    const open = async (options={}) => {
      if(typeof show === 'function') show('dashboardPage');
      ['dashboardPage','teamPage','jobsPage','productionPage','safetyPage','priceBooksPage','setupPage','authPage'].forEach(id => byId(id)?.classList.add('hidden'));
      byId('timekeepingPage')?.classList.remove('hidden');
      await refreshTimekeeping();
      if(options?.focusRoster){
        byId('timekeepingRosterCard')?.scrollIntoView({behavior:'smooth',block:'start'});
      }
    };
    window.openLineCrewTimekeeping = open;
    tile.addEventListener('click', open);
    tile.addEventListener('keydown', (event) => {
      if(event.key === 'Enter' || event.key === ' '){event.preventDefault();open();}
    });
    grid.appendChild(tile);
  }

  async function refreshTimekeeping(){
    if(!companyId() || !getSb()) return;
    byId('timekeepingRosterCard')?.classList.toggle('hidden', !canManageRoster());
    await Promise.all([loadEmployees(), loadJobs(), loadForemen(), loadAdmins(), loadTeamProfiles()]);
    renderRoster();
    renderCompleteRoster();
    fillFilters();
    await loadEntries();
  }

  async function loadEmployees(){
    if(!companyId()) return;
    const [employeeResult,equipmentResult] = await Promise.all([
      getSb().from('timekeeping_employees')
        .select('id,employee_number,full_name,classification,default_crew_name,default_equipment,active,assigned_foreman_id,assigned_admin_id,linked_profile_id')
        .eq('company_id', companyId())
        .order('active', { ascending:false })
        .order('full_name'),
      getSb().from('timekeeping_equipment')
        .select('id,unit_number,description,active')
        .eq('company_id', companyId())
        .order('unit_number')
    ]);
    const { data, error } = employeeResult;
    if(error){ console.error('Timekeeping employee load failed', error); return; }
    employees = data || [];
    if(!equipmentResult.error) equipment = equipmentResult.data || [];
  }

  async function loadForemen(){
    if(!companyId() || !canManageRoster()) return;
    const { data, error } = await getSb().from('profiles')
      .select('id,full_name,role,active')
      .eq('company_id', companyId())
      .eq('role','foreman')
      .eq('active',true)
      .order('full_name');
    if(error){ console.error('Foreman load failed', error); return; }
    foremen = data || [];
    const select=byId('tkEmployeeForeman');
    if(select){
      const selected=select.value;
      select.innerHTML='<option value="">Unassigned</option>'+foremen.map(f=>`<option value="${esc(f.id)}">${esc(f.full_name||'Foreman')}</option>`).join('');
      select.value=selected;
    }
  }

  async function loadAdmins(){
    if(!companyId() || !canManageRoster()) return;
    const { data, error } = await getSb().from('profiles')
      .select('id,full_name,role,active')
      .eq('company_id', companyId())
      .eq('role','admin')
      .eq('active',true)
      .order('full_name');
    if(error){ console.error('Admin roster load failed', error); return; }
    admins = data || [];
    const select=byId('tkEmployeeAdmin');
    if(select){
      const selected=select.value;
      select.innerHTML='<option value="">Unassigned</option>'+admins.map(a=>`<option value="${esc(a.id)}">${esc(a.full_name||'Admin')}</option>`).join('');
      select.value=selected;
    }
  }

  async function loadTeamProfiles(){
    if(!companyId()||!canViewCompleteRoster()){teamProfiles=[];return;}
    const {data,error}=await getSb().from('profiles')
      .select('id,full_name,email,role,active')
      .eq('company_id',companyId())
      .order('full_name');
    if(error){console.error('Complete roster Team load failed',error);return;}
    teamProfiles=data||[];
  }

  async function loadJobs(){
    if(!companyId()) return;
    const { data, error } = await getSb().from('jobs')
      .select('id,job_number,job_name,active')
      .eq('company_id', companyId())
      .order('job_number');
    if(!error) jobs = data || [];
  }

  function fillFilters(){
    const emp = byId('tkEmployeeFilter');
    const job = byId('tkJobFilter');
    if(emp){
      const selected = emp.value;
      emp.innerHTML = '<option value="">All employees</option>' + employees.filter(e=>e.active).map(e=>`<option value="${esc(e.id)}">${esc(e.full_name)}</option>`).join('');
      emp.value = selected;
    }
    if(job){
      const selected = job.value;
      job.innerHTML = '<option value="">All jobs</option>' + jobs.map(j=>`<option value="${esc(j.id)}">${esc(j.job_number || '')}${j.job_name ? ' — ' + esc(j.job_name) : ''}</option>`).join('');
      job.value = selected;
    }
  }

  async function addEmployee(){
    if(!canManageRoster()) return alert('Only an Owner, Admin, or General Foreman can manage the employee roster.');
    const fullName = (byId('tkEmployeeName')?.value || '').trim();
    if(!fullName) return alert('Enter the employee name.');
    const payload = {
      company_id: companyId(),
      employee_number: (byId('tkEmployeeNumber')?.value || '').trim() || null,
      full_name: fullName,
      classification: (byId('tkEmployeeClass')?.value || '').trim() || null,
      default_crew_name: (byId('tkEmployeeCrew')?.value || '').trim() || null,
      assigned_foreman_id: byId('tkEmployeeForeman')?.value || null,
      assigned_admin_id: byId('tkEmployeeAdmin')?.value || null,
      active: true
    };
    const { error } = await getSb().from('timekeeping_employees').insert(payload);
    if(error) return alert('Could not add employee: ' + error.message);
    ['tkEmployeeNumber','tkEmployeeName','tkEmployeeClass','tkEmployeeCrew','tkEmployeeForeman','tkEmployeeAdmin'].forEach(id => { if(byId(id)) byId(id).value=''; });
    await loadEmployees();
    renderRoster();
    renderCompleteRoster();
    fillFilters();
    refreshCrewEmployeeSelects();
  }

  async function toggleEmployee(id, active){
    const { error } = await getSb().from('timekeeping_employees').update({active,updated_at:new Date().toISOString()}).eq('id',id);
    if(error) return alert('Could not update employee: ' + error.message);
    await loadEmployees();
    renderRoster();
    renderCompleteRoster();
    fillFilters();
    refreshCrewEmployeeSelects();
  }

  function updateRosterDraft(id,field,value){
    if(!canManageRoster()||rosterAssignmentsSaving)return;
    const employee=employees.find(e=>e.id===id);
    if(!employee)return;
    const existing=rosterAssignmentDrafts.get(id)||{
      assigned_foreman_id:employee.assigned_foreman_id||'',
      assigned_admin_id:employee.assigned_admin_id||''
    };
    existing[field]=value||'';
    const unchanged=existing.assigned_foreman_id===(employee.assigned_foreman_id||'')&&existing.assigned_admin_id===(employee.assigned_admin_id||'');
    if(unchanged)rosterAssignmentDrafts.delete(id);
    else rosterAssignmentDrafts.set(id,existing);
    const row=byId('tkRosterList')?.querySelector(`[data-tk-employee-row="${id}"]`);
    row?.classList.toggle('tk-assignment-pending',!unchanged);
    updateRosterSaveState();
  }

  function updateRosterSaveState(message=''){
    const button=byId('tkSaveAssignmentsBtn');
    const status=byId('tkRosterSaveStatus');
    const count=rosterAssignmentDrafts.size;
    if(button){
      button.disabled=rosterAssignmentsSaving||!count;
      button.textContent=rosterAssignmentsSaving?'Saving Assignments…':count?`Save Crew Assignments (${count})`:'Save Crew Assignments';
    }
    if(status)status.textContent=message||(count?`${count} employee assignment${count===1?'':'s'} ready to save.`:'Choose assignments, then save them together.');
  }

  function openRosterGroups(){
    return new Set(Array.from(byId('tkRosterList')?.querySelectorAll('details[open][data-tk-roster-group]')||[]).map(group=>group.dataset.tkRosterGroup));
  }

  async function saveRosterAssignments(){
    if(!canManageRoster()||rosterAssignmentsSaving||!rosterAssignmentDrafts.size)return;
    const openGroups=openRosterGroups();
    const drafts=Array.from(rosterAssignmentDrafts.entries());
    rosterAssignmentsSaving=true;
    updateRosterSaveState();
    const results=await Promise.all(drafts.map(async([id,draft])=>{
      try{
        const employee=employees.find(item=>item.id===id);
        const changes={updated_at:new Date().toISOString()};
        if((draft.assigned_foreman_id||'')!==(employee?.assigned_foreman_id||''))changes.assigned_foreman_id=draft.assigned_foreman_id||null;
        if((draft.assigned_admin_id||'')!==(employee?.assigned_admin_id||''))changes.assigned_admin_id=draft.assigned_admin_id||null;
        const {error}=await getSb().from('timekeeping_employees').update(changes).eq('id',id);
        return {id,error};
      }catch(error){return {id,error};}
    }));
    const failed=results.filter(result=>result.error);
    results.filter(result=>!result.error).forEach(result=>rosterAssignmentDrafts.delete(result.id));
    await loadEmployees();
    rosterAssignmentsSaving=false;
    renderRoster(openGroups);
    renderCompleteRoster();
    fillFilters();
    refreshCrewEmployeeSelects();
    window.LineCrewLeadershipMyTime?.refresh?.();
    if(failed.length){
      updateRosterSaveState(`${failed.length} assignment${failed.length===1?'':'s'} could not be saved. The unsaved selections remain highlighted.`);
      alert('Could not save every crew assignment: '+failed[0].error.message);
      return;
    }
    updateRosterSaveState(`${drafts.length} employee assignment${drafts.length===1?'':'s'} saved.`);
  }

  function renderRoster(groupsToOpen=new Set()){
    const box = byId('tkRosterList');
    if(!box) return;
    if(!employees.length){box.innerHTML='<p class="muted">No employees have been added yet.</p>';return;}
    const foremanOptions=(selected)=>'<option value="">Unassigned</option>'+foremen.map(f=>`<option value="${esc(f.id)}" ${f.id===selected?'selected':''}>${esc(f.full_name||'Foreman')}</option>`).join('');
    const adminOptions=(selected)=>'<option value="">Unassigned</option>'+admins.map(a=>`<option value="${esc(a.id)}" ${a.id===selected?'selected':''}>${esc(a.full_name||'Admin')}</option>`).join('');
    const employeeRows=(group)=>group.map(e=>{const draft=rosterAssignmentDrafts.get(e.id);const selectedForeman=draft?.assigned_foreman_id??e.assigned_foreman_id;const selectedAdmin=draft?.assigned_admin_id??e.assigned_admin_id;return `<tr data-tk-employee-row="${esc(e.id)}" class="${draft?'tk-assignment-pending':''}"><td data-label="Employee"><strong>${esc(e.full_name)}</strong></td><td data-label="#">${esc(e.employee_number || '')}</td><td data-label="Classification">${esc(e.classification || '')}</td><td data-label="Default Crew">${esc(e.default_crew_name || '')}</td><td data-label="Assigned Foreman"><select data-tk-foreman="${esc(e.id)}" ${e.active?'':'disabled'}>${foremanOptions(selectedForeman)}</select></td><td data-label="Assigned Admin"><select data-tk-admin="${esc(e.id)}" ${e.active?'':'disabled'}>${adminOptions(selectedAdmin)}</select></td><td data-label="Status">${e.active ? 'Active':'Inactive'}</td><td data-label="Action" class="tk-row-actions"><button class="secondary small" data-tk-toggle="${esc(e.id)}" data-active="${e.active ? '0':'1'}">${e.active ? 'Deactivate':'Activate'}</button></td></tr>`;}).join('');
    const crewGroups=foremen.map(f=>({key:f.id,name:f.full_name||'Foreman',members:employees.filter(e=>e.assigned_foreman_id===f.id)}));
    crewGroups.push({key:'unassigned',name:'Unassigned Employees',members:employees.filter(e=>!e.assigned_foreman_id)});
    box.innerHTML=crewGroups.map(group=>`<details class="job-card tk-crew-group" data-tk-roster-group="${esc(group.key)}" ${groupsToOpen.has(group.key)?'open':''}><summary><strong>${esc(group.name)}</strong> — ${group.members.length} crew member${group.members.length===1?'':'s'}</summary>${group.members.length?`<div class="tk-table-wrap"><table class="tk-table"><thead><tr><th>Employee</th><th>#</th><th>Classification</th><th>Default Crew</th><th>Assigned Foreman</th><th>Assigned Admin</th><th>Status</th><th></th></tr></thead><tbody>${employeeRows(group.members)}</tbody></table></div>`:'<p class="muted">No employees assigned.</p>'}</details>`).join('');
    box.querySelectorAll('[data-tk-toggle]').forEach(btn => btn.onclick = () => toggleEmployee(btn.dataset.tkToggle, btn.dataset.active === '1'));
    box.querySelectorAll('[data-tk-foreman]').forEach(select => select.onchange = () => updateRosterDraft(select.dataset.tkForeman,'assigned_foreman_id',select.value));
    box.querySelectorAll('[data-tk-admin]').forEach(select => select.onchange = () => updateRosterDraft(select.dataset.tkAdmin,'assigned_admin_id',select.value));
    updateRosterSaveState();
  }

  function renderCompleteRoster(){
    const panel=byId('tkCompleteRoster'),summary=byId('tkCompleteRosterSummary'),body=byId('tkCompleteRosterBody');
    if(!panel||!summary||!body)return;
    panel.classList.toggle('hidden',!canViewCompleteRoster());
    if(!canViewCompleteRoster())return;
    const foremanMap=new Map(foremen.map(person=>[person.id,person]));
    const adminMap=new Map(admins.map(person=>[person.id,person]));
    const profileById=new Map(teamProfiles.map(profile=>[profile.id,profile]));
    const teamRoleLabel=value=>({gf:'GF',admin:'Admin',owner:'Owner',foreman:'Foreman',superintendent:'Superintendent'}[String(value||'').toLowerCase()]||String(value||'Team Member'));
    const leadershipRoles=new Set(['foreman','gf','superintendent','admin','owner']);
    const leadershipEmployee=employee=>leadershipRoles.has(String(profileById.get(employee.linked_profile_id)?.role||'').toLowerCase());
    const linkedProfileIds=new Set(employees.map(employee=>employee.linked_profile_id).filter(Boolean));
    const profileOnlyPeople=teamProfiles.filter(profile=>!linkedProfileIds.has(profile.id)).map(profile=>{
      const profileRole=String(profile.role||'member').toLowerCase();
      return {
        id:`profile-${profile.id}`,
        full_name:profile.full_name||profile.email||'Team Member',
        employee_number:profile.email||'',
        classification:`Team Login — ${teamRoleLabel(profileRole)}`,
        active:profile.active!==false,
        assigned_foreman_id:null,
        assigned_admin_id:null,
        default_crew_name:'',
        default_equipment:'',
        profile_only:true,
        profile_role:profileRole,
        linked_profile_id:profile.id
      };
    });
    const allPeople=[...employees,...profileOnlyPeople];
    const activePeople=allPeople.filter(person=>person.active!==false);
    const activeEquipment=equipment.filter(unit=>unit.active!==false);
    const employeeForEquipment=unitNumber=>employees.find(employee=>employee.default_equipment===unitNumber)||null;
    summary.textContent=`Complete Company Roster — ${activePeople.length} people / ${activeEquipment.length} equipment`;
    const crewLabel=employee=>{
      const foreman=foremanMap.get(employee.assigned_foreman_id);
      if(foreman)return `${foreman.full_name||'Foreman'}${employee.default_crew_name?' — '+employee.default_crew_name:''}`;
      const linkedRole=String(profileById.get(employee.linked_profile_id)?.role||'').toLowerCase();
      if(leadershipEmployee(employee))return linkedRole==='foreman'?'Foreman — Own Crew':`${teamRoleLabel(linkedRole)} Leadership`;
      return employee.default_crew_name?`Unassigned — ${employee.default_crew_name}`:'Unassigned';
    };
    completeRosterPeople=allPeople.map(employee=>{
      const admin=adminMap.get(employee.assigned_admin_id);
      const isLeadership=employee.profile_only||leadershipEmployee(employee);
      const unassigned=!isLeadership&&employee.active!==false&&!employee.assigned_foreman_id;
      const crew=employee.profile_only?`${employee.classification.replace('Team Login — ','')} Leadership`:crewLabel(employee);
      const linkedRole=String(profileById.get(employee.linked_profile_id)?.role||employee.profile_role||'').toLowerCase();
      const foremanFilter=employee.assigned_foreman_id||(linkedRole==='foreman'?employee.linked_profile_id:isLeadership?'leadership':'unassigned');
      const record={
        id:employee.id,
        name:employee.full_name||'Unnamed Employee',
        number:employee.employee_number||'',
        classification:employee.classification||'',
        crew,
        admin:employee.profile_only?'—':admin?.full_name||'Unassigned',
        equipment:employee.profile_only?'—':employee.default_equipment||'Unassigned',
        status:employee.active===false?'inactive':'active',
        assignment:isLeadership?'leadership':employee.assigned_foreman_id?'assigned':'unassigned',
        foremanFilter,
        profileOnly:!!employee.profile_only,
        unassigned
      };
      record.searchText=[record.name,record.number,record.classification,record.crew,record.admin,record.equipment].join(' ').toLowerCase();
      return record;
    }).sort((left,right)=>Number(right.unassigned)-Number(left.unassigned)||left.name.localeCompare(right.name));
    const personByEmployeeId=new Map(completeRosterPeople.filter(person=>!person.profileOnly).map(person=>[person.id,person]));
    completeRosterEquipment=equipment.map(unit=>{
      const employee=employeeForEquipment(unit.unit_number);
      const person=employee?personByEmployeeId.get(employee.id):null;
      const assigned=!!(employee&&employee.active!==false);
      const record={
        id:unit.id,
        unit:unit.unit_number||'',
        description:unit.description||'',
        employee:employee?(employee.full_name||employee.employee_number||'Employee')+(employee.active===false?' (Inactive)':''):'Unassigned',
        crew:employee?crewLabel(employee):'Unassigned',
        status:unit.active===false?'inactive':'active',
        assignment:assigned?'assigned':'unassigned',
        foremanFilter:person?.foremanFilter||'unassigned',
        unassigned:unit.active!==false&&!assigned
      };
      record.searchText=[record.unit,record.description,record.employee,record.crew].join(' ').toLowerCase();
      return record;
    }).sort((left,right)=>Number(right.unassigned)-Number(left.unassigned)||left.unit.localeCompare(right.unit,undefined,{numeric:true}));
    const foremanOptions=foremen.map(foreman=>`<option value="${esc(foreman.id)}" ${completeRosterFilters.foreman===foreman.id?'selected':''}>${esc(foreman.full_name||'Foreman')} Crew</option>`).join('');
    body.innerHTML=`
      <p class="tk-help">Read-only company overview. Unassigned active people and equipment are highlighted.</p>
      <div class="tk-complete-tools">
        <input id="tkCompleteRosterSearch" type="search" placeholder="Search people, crews, equipment…" value="${esc(completeRosterFilters.query)}">
        <select id="tkCompleteRosterKind"><option value="all" ${completeRosterFilters.kind==='all'?'selected':''}>People & Equipment</option><option value="people" ${completeRosterFilters.kind==='people'?'selected':''}>People only</option><option value="equipment" ${completeRosterFilters.kind==='equipment'?'selected':''}>Equipment only</option></select>
        <select id="tkCompleteRosterStatus"><option value="all" ${completeRosterFilters.status==='all'?'selected':''}>All statuses</option><option value="active" ${completeRosterFilters.status==='active'?'selected':''}>Active only</option><option value="inactive" ${completeRosterFilters.status==='inactive'?'selected':''}>Inactive only</option></select>
        <select id="tkCompleteRosterAssignment"><option value="all" ${completeRosterFilters.assignment==='all'?'selected':''}>All assignments</option><option value="assigned" ${completeRosterFilters.assignment==='assigned'?'selected':''}>Assigned only</option><option value="unassigned" ${completeRosterFilters.assignment==='unassigned'?'selected':''}>Unassigned only</option></select>
        <select id="tkCompleteRosterForeman"><option value="all" ${completeRosterFilters.foreman==='all'?'selected':''}>All Foremen / Crews</option>${foremanOptions}<option value="unassigned" ${completeRosterFilters.foreman==='unassigned'?'selected':''}>Unassigned Crew</option><option value="leadership" ${completeRosterFilters.foreman==='leadership'?'selected':''}>Leadership</option></select>
      </div>
      <div class="tk-complete-actions"><button id="tkExportCompleteRoster" type="button" class="success small">Export Filtered Excel</button><button id="tkClearCompleteRosterFilters" type="button" class="secondary small">Clear Filters</button><span id="tkCompleteRosterResultCount" class="muted"></span></div>
      <div id="tkCompleteRosterFilteredSummary" class="tk-roster-summary"></div>
      <div id="tkCompletePeopleSection" class="tk-complete-section"><h4 id="tkCompletePeopleHeading">People</h4><div class="tk-table-wrap"><table class="tk-table"><thead><tr><th>Employee</th><th># / Email</th><th>Role / Classification</th><th>Foreman / Crew</th><th>Admin Roster</th><th>Equipment</th><th>Status</th></tr></thead><tbody id="tkCompletePeopleRows"></tbody></table></div></div>
      <div id="tkCompleteEquipmentSection" class="tk-complete-section"><h4 id="tkCompleteEquipmentHeading">Equipment</h4><div class="tk-table-wrap"><table class="tk-table"><thead><tr><th>Unit #</th><th>Type / Description</th><th>Assigned Employee</th><th>Foreman / Crew</th><th>Status</th></tr></thead><tbody id="tkCompleteEquipmentRows"></tbody></table></div></div>`;
    const filterBindings={tkCompleteRosterKind:'kind',tkCompleteRosterStatus:'status',tkCompleteRosterAssignment:'assignment',tkCompleteRosterForeman:'foreman'};
    Object.entries(filterBindings).forEach(([id,key])=>byId(id)?.addEventListener('change',event=>{completeRosterFilters[key]=event.target.value;applyCompleteRosterFilters();}));
    byId('tkCompleteRosterSearch')?.addEventListener('input',event=>{completeRosterFilters.query=event.target.value;applyCompleteRosterFilters();});
    byId('tkClearCompleteRosterFilters').onclick=()=>{
      Object.assign(completeRosterFilters,{query:'',kind:'all',status:'all',assignment:'all',foreman:'all'});
      renderCompleteRoster();
    };
    byId('tkExportCompleteRoster').onclick=exportCompleteRoster;
    applyCompleteRosterFilters();
  }

  function filteredCompleteRosterRecords(){
    const query=completeRosterFilters.query.trim().toLowerCase();
    const matches=record=>(!query||record.searchText.includes(query))&&
      (completeRosterFilters.status==='all'||record.status===completeRosterFilters.status)&&
      (completeRosterFilters.assignment==='all'||record.assignment===completeRosterFilters.assignment)&&
      (completeRosterFilters.foreman==='all'||record.foremanFilter===completeRosterFilters.foreman);
    return {
      people:completeRosterFilters.kind==='equipment'?[]:completeRosterPeople.filter(matches),
      equipment:completeRosterFilters.kind==='people'?[]:completeRosterEquipment.filter(matches)
    };
  }

  function applyCompleteRosterFilters(){
    const filtered=filteredCompleteRosterRecords();
    const peopleBody=byId('tkCompletePeopleRows'),equipmentBody=byId('tkCompleteEquipmentRows');
    if(!peopleBody||!equipmentBody)return filtered;
    byId('tkCompletePeopleSection').classList.toggle('hidden',completeRosterFilters.kind==='equipment');
    byId('tkCompleteEquipmentSection').classList.toggle('hidden',completeRosterFilters.kind==='people');
    byId('tkCompletePeopleHeading').textContent=`People — ${filtered.people.length}`;
    byId('tkCompleteEquipmentHeading').textContent=`Equipment — ${filtered.equipment.length}`;
    peopleBody.innerHTML=filtered.people.length?filtered.people.map(person=>`<tr class="${person.unassigned?'tk-roster-unassigned ':''}${person.status==='inactive'?'tk-roster-inactive':''}"><td><strong>${esc(person.name)}</strong>${person.profileOnly?' <span class="muted">(Team login)</span>':''}</td><td>${esc(person.number)}</td><td>${esc(person.classification)}</td><td>${esc(person.crew)}</td><td>${esc(person.admin)}</td><td>${esc(person.equipment)}</td><td>${person.status==='inactive'?'Inactive':'Active'}</td></tr>`).join(''):'<tr><td colspan="7">No people match these filters.</td></tr>';
    equipmentBody.innerHTML=filtered.equipment.length?filtered.equipment.map(unit=>`<tr class="${unit.unassigned?'tk-roster-unassigned ':''}${unit.status==='inactive'?'tk-roster-inactive':''}"><td><strong>${esc(unit.unit)}</strong></td><td>${esc(unit.description)}</td><td>${esc(unit.employee)}</td><td>${esc(unit.crew)}</td><td>${unit.status==='inactive'?'Inactive':'Active'}</td></tr>`).join(''):'<tr><td colspan="5">No equipment matches these filters.</td></tr>';
    const assignedPeople=filtered.people.filter(person=>person.assignment==='assigned').length;
    const unassignedPeople=filtered.people.filter(person=>person.assignment==='unassigned').length;
    const assignedEquipment=filtered.equipment.filter(unit=>unit.assignment==='assigned').length;
    const unassignedEquipment=filtered.equipment.filter(unit=>unit.assignment==='unassigned').length;
    byId('tkCompleteRosterFilteredSummary').innerHTML=`<div><strong>${filtered.people.length}</strong>People Shown</div><div><strong>${assignedPeople}</strong>Assigned Crew Members</div><div><strong>${unassignedPeople}</strong>Unassigned Crew Members</div><div><strong>${filtered.equipment.length}</strong>Equipment Shown</div><div><strong>${assignedEquipment}</strong>Assigned Equipment</div><div><strong>${unassignedEquipment}</strong>Unassigned Equipment</div>`;
    byId('tkCompleteRosterResultCount').textContent=`${filtered.people.length} people and ${filtered.equipment.length} equipment match.`;
    return filtered;
  }

  function safeRosterExportCell(value){
    const text=String(value??'');
    return /^\s*[=+\-@]/.test(text)?`'${text}`:text;
  }

  function exportCompleteRoster(){
    const filtered=filteredCompleteRosterRecords();
    if(!filtered.people.length&&!filtered.equipment.length)return alert('No roster rows match the current filters.');
    const peopleRows=[['Employee','# / Email','Role / Classification','Foreman / Crew','Admin Roster','Equipment','Status'],...filtered.people.map(person=>[person.name,person.number,person.classification,person.crew,person.admin,person.equipment,person.status==='inactive'?'Inactive':'Active'])].map(row=>row.map(safeRosterExportCell));
    const equipmentRows=[['Unit #','Type / Description','Assigned Employee','Foreman / Crew','Status'],...filtered.equipment.map(unit=>[unit.unit,unit.description,unit.employee,unit.crew,unit.status==='inactive'?'Inactive':'Active'])].map(row=>row.map(safeRosterExportCell));
    const filename=`linecrew-complete-roster-${todayIso()}.xlsx`;
    if(typeof XLSX!=='undefined'){
      const workbook=XLSX.utils.book_new();
      if(filtered.people.length){const sheet=XLSX.utils.aoa_to_sheet(peopleRows);sheet['!autofilter']={ref:`A1:G${peopleRows.length}`};sheet['!cols']=[28,22,24,28,24,20,12].map(wch=>({wch}));XLSX.utils.book_append_sheet(workbook,sheet,'People');}
      if(filtered.equipment.length){const sheet=XLSX.utils.aoa_to_sheet(equipmentRows);sheet['!autofilter']={ref:`A1:E${equipmentRows.length}`};sheet['!cols']=[18,32,28,28,12].map(wch=>({wch}));XLSX.utils.book_append_sheet(workbook,sheet,'Equipment');}
      XLSX.writeFile(workbook,filename);
      return;
    }
    const rows=[['Record Type','Name / Unit','Number / Description','Role / Assigned Employee','Foreman / Crew','Admin Roster','Equipment','Status'],...filtered.people.map(person=>['Person',person.name,person.number,person.classification,person.crew,person.admin,person.equipment,person.status]),...filtered.equipment.map(unit=>['Equipment',unit.unit,unit.description,unit.employee,unit.crew,'','',unit.status])];
    const blob=new Blob([rows.map(row=>row.map(csvCell).join(',')).join('\n')],{type:'text/csv;charset=utf-8'}),url=URL.createObjectURL(blob),link=document.createElement('a');
    link.href=url;link.download=filename.replace(/\.xlsx$/,'.csv');document.body.appendChild(link);link.click();link.remove();URL.revokeObjectURL(url);
  }

  window.LineCrewRefreshCompleteRoster=async()=>{await Promise.all([loadEmployees(),loadForemen(),loadAdmins(),loadTeamProfiles()]);renderCompleteRoster();};

  async function loadEntries(){
    if(!companyId() || !byId('tkReportList')) return;
    let query = getSb().from('timekeeping_entries')
      .select('id,employee_id,daily_report_id,job_id,work_date,crew_name,regular_hours,overtime_hours,storm_work,notes,created_by')
      .eq('company_id', companyId())
      .gte('work_date', byId('tkFromDate')?.value || mondayIso())
      .lte('work_date', byId('tkThroughDate')?.value || todayIso())
      .order('work_date', {ascending:false});
    const employeeId = byId('tkEmployeeFilter')?.value;
    const jobId = byId('tkJobFilter')?.value;
    if(employeeId) query = query.eq('employee_id', employeeId);
    if(jobId) query = query.eq('job_id', jobId);
    const { data, error } = await query;
    if(error){byId('tkReportList').innerHTML='<p class="muted">Could not load time report: '+esc(error.message)+'</p>';return;}
    entries = data || [];
    renderEntries();
  }

  function renderEntries(){
    const employeeMap = new Map(employees.map(e=>[e.id,e]));
    const jobMap = new Map(jobs.map(j=>[j.id,j]));
    const reg = entries.reduce((sum,e)=>sum+number(e.regular_hours),0);
    const ot = entries.reduce((sum,e)=>sum+number(e.overtime_hours),0);
    const employeesCount = new Set(entries.map(e=>e.employee_id)).size;
    const summary = byId('tkSummary');
    if(summary) summary.innerHTML = `<div><strong>${employeesCount}</strong>Employees</div><div><strong>${reg.toFixed(2)}</strong>Regular Hours</div><div><strong>${ot.toFixed(2)}</strong>OT Hours</div><div><strong>${(reg+ot).toFixed(2)}</strong>Total Hours</div>`;
    const box = byId('tkReportList');
    if(!entries.length){box.innerHTML='<p class="muted">No time entries match these filters.</p>';return;}
    box.innerHTML = `<div class="tk-table-wrap"><table class="tk-table"><thead><tr><th>Date</th><th>Employee</th><th>Class</th><th>Job</th><th>Crew</th><th>Regular</th><th>OT</th><th>Total</th><th>Storm</th></tr></thead><tbody>${entries.map(e=>{
      const employee=employeeMap.get(e.employee_id)||{};const job=jobMap.get(e.job_id)||{};
      return `<tr><td>${esc(e.work_date)}</td><td>${esc(employee.full_name||'')}</td><td>${esc(employee.classification||'')}</td><td>${esc(job.job_number||'')}</td><td>${esc(e.crew_name||'')}</td><td>${number(e.regular_hours).toFixed(2)}</td><td>${number(e.overtime_hours).toFixed(2)}</td><td>${(number(e.regular_hours)+number(e.overtime_hours)).toFixed(2)}</td><td>${e.storm_work?'Yes':'No'}</td></tr>`;
    }).join('')}</tbody></table></div>`;
  }

  function csvCell(value){
    let s=String(value??'');
    if(typeof value==='string' && (/^[\t\r\n]/.test(s) || /^\s*[=+\-@]/.test(s))) s="'"+s;
    return /[",\n]/.test(s) ? '"'+s.replace(/"/g,'""')+'"' : s;
  }

  function exportCsv(){
    const employeeMap = new Map(employees.map(e=>[e.id,e]));
    const jobMap = new Map(jobs.map(j=>[j.id,j]));
    const rows = [['Employee #','Employee','Classification','Date','Job #','Job Name','Crew','Regular Hours','OT Hours','Total Hours','Storm']];
    entries.forEach(e=>{
      const employee=employeeMap.get(e.employee_id)||{};const job=jobMap.get(e.job_id)||{};
      rows.push([employee.employee_number||'',employee.full_name||'',employee.classification||'',e.work_date||'',job.job_number||'',job.job_name||'',e.crew_name||'',number(e.regular_hours).toFixed(2),number(e.overtime_hours).toFixed(2),(number(e.regular_hours)+number(e.overtime_hours)).toFixed(2),e.storm_work?'Yes':'No']);
    });
    const blob = new Blob([rows.map(row=>row.map(csvCell).join(',')).join('\n')], {type:'text/csv;charset=utf-8'});
    const url = URL.createObjectURL(blob);
    const a=document.createElement('a');a.href=url;a.download=`linecrew-timekeeping-${byId('tkFromDate')?.value||''}-to-${byId('tkThroughDate')?.value||''}.csv`;document.body.appendChild(a);a.click();a.remove();URL.revokeObjectURL(url);
  }

  function injectCrewTime(){
    const form = byId('dailyReportForm');
    if(!form || byId('dailyCrewTimeCard')) return;
    const card = document.createElement('div');
    card.id='dailyCrewTimeCard';
    card.className='tk-crew-card';
    card.innerHTML=`<h3>Crew Time</h3><p class="tk-help" data-tk-launch-help="1">Your Foreman row appears first, followed by the assigned crew. Assigned equipment fills in automatically; change the dropdown only when someone uses a different unit that day. Enter Start and Stop in 24-hour time plus Lunch; LineCrew calculates hours for payroll. Per diem defaults on.</p><div id="dailyCrewTimeRows"></div><div class="tk-inline-actions"><button id="dailyAddCrewMember" type="button" class="secondary small">+ Add Extra Man</button><span id="dailyCrewTimeTotals" class="muted"></span></div>`;
    const notes = byId('dailyNotes');
    if(notes?.parentElement) notes.parentElement.insertBefore(card, notes);
    else form.appendChild(card);
    byId('dailyAddCrewMember').onclick = () => addCrewRow();

    const saveBtn = byId('saveDailyReportBtn');
    if(saveBtn){
      saveBtn.addEventListener('click', () => {
        syncDailyTotals();
      }, true);
    }

    const crewName = byId('dailyCrewName');
    crewName?.addEventListener('change', () => { if(!form.dataset.reportId) loadDefaultCrewRows(); });
  }

  function employeeOptions(selected){
    const viewerId=typeof currentProfile!=='undefined' ? currentProfile?.id||null : null;
    return '<option value="">Select employee</option>'+employees.filter(e=>e.active).map(e=>{
      const extra=role()==='foreman' && e.assigned_foreman_id!==viewerId;
      return `<option value="${esc(e.id)}" ${e.id===selected?'selected':''}>${esc(e.full_name)}${e.classification?' — '+esc(e.classification):''}${extra?' — Extra crew':''}</option>`;
    }).join('');
  }

  function equipmentOptions(selected=''){
    let options=equipment.filter(item=>item.active!==false).map(item=>`<option value="${esc(item.unit_number)}" ${item.unit_number===selected?'selected':''}>${esc(item.unit_number)}${item.description?' — '+esc(item.description):''}</option>`);
    if(selected&&!equipment.some(item=>item.unit_number===selected))options.unshift(`<option value="${esc(selected)}" selected>${esc(selected)}</option>`);
    return '<option value="">Select truck / equipment</option>'+options.join('');
  }

  function normalizeClock(input){
    let value=String(input.value||'').replace(/[^0-9:]/g,'').slice(0,5);
    if(/^\d{3,4}$/.test(value)){value=value.padStart(4,'0');value=value.slice(0,2)+':'+value.slice(2);}
    if(/^\d{1,2}:\d{1,2}$/.test(value)){
      const [hours,minutes]=value.split(':').map(Number);
      if(hours>=0&&hours<=23&&minutes>=0&&minutes<=59)value=String(hours).padStart(2,'0')+':'+String(minutes).padStart(2,'0');
    }
    input.value=value;
  }

  function clockMinutes(value){
    if(!value||!/^([01]\d|2[0-3]):[0-5]\d$/.test(value))return null;
    const [hours,minutes]=value.split(':').map(Number);
    return hours*60+minutes;
  }

  function syncCrewRowFromClock(row){
    const start=clockMinutes(row.querySelector('.tk-start')?.value);
    const stop=clockMinutes(row.querySelector('.tk-stop')?.value);
    const output=row.querySelector('.tk-hours-worked');
    if(start===null||stop===null){if(output)output.textContent='Worked: —';syncDailyTotals();return;}
    let minutes=stop-start;
    if(minutes<0)minutes+=1440;
    minutes-=Math.max(0,number(row.querySelector('.tk-lunch')?.value));
    const total=Math.max(0,minutes/60);
    const regular=row.querySelector('.tk-regular');
    const overtime=row.querySelector('.tk-ot');
    if(regular)regular.value=total.toFixed(2);
    if(overtime)overtime.value='0.00';
    if(output)output.textContent=`Worked: ${total.toFixed(2)} h · Weekly OT is calculated after save`;
    syncDailyTotals();
  }

  function addCrewRow(data={}){
    const box=byId('dailyCrewTimeRows');if(!box)return;
    const row=document.createElement('div');
    row.className='tk-crew-row';row.dataset.row=String(++crewRowCounter);row.dataset.tkLaunchDetails='1';
    const employee=employees.find(item=>item.id===(data.employee_id||''));
    const selectedEquipment=data.equipment_used||employee?.default_equipment||'';
    const perDiem=data.per_diem!==false;
    row.innerHTML=`<label class="tk-person">Employee<select class="tk-employee">${employeeOptions(data.employee_id||'')}</select></label><label class="tk-hours-fallback">Regular<input class="tk-regular" type="number" min="0" max="24" step="0.25" value="${number(data.regular_hours)}"></label><label class="tk-hours-fallback">OT<input class="tk-ot" type="number" min="0" max="24" step="0.25" value="${number(data.overtime_hours)}"></label><button type="button" class="danger small tk-remove">Remove</button><div class="tk-detail-row"><label>Start (24 hr)<input class="tk-start tk-clock24" type="text" inputmode="numeric" maxlength="5" value="${esc(String(data.start_time||'').slice(0,5))}" aria-label="Start time in 24-hour format"></label><label>Stop (24 hr)<input class="tk-stop tk-clock24" type="text" inputmode="numeric" maxlength="5" value="${esc(String(data.stop_time||'').slice(0,5))}" aria-label="Stop time in 24-hour format"></label><label>Lunch (min)<input class="tk-lunch" type="number" min="0" max="720" step="5" value="${Math.max(0,Math.min(720,Math.round(number(data.lunch_minutes))))}"></label><label>Truck / Equipment<select class="tk-equipment">${equipmentOptions(selectedEquipment)}</select></label><label class="tk-detail-check"><input class="tk-equipment-not-used" type="checkbox" ${data.equipment_not_used?'checked':''}> Not used today</label><label class="tk-detail-check"><input class="tk-per-diem" type="checkbox" ${perDiem?'checked':''}> Per diem</label><div class="tk-hours-worked">Worked: —</div></div>`;
    row.querySelector('.tk-remove').onclick=()=>{row.remove();syncDailyTotals();};
    row.querySelectorAll('input,select').forEach(el=>el.addEventListener('change',syncDailyTotals));
    row.querySelectorAll('.tk-start,.tk-stop').forEach(input=>{
      input.addEventListener('blur',()=>{normalizeClock(input);syncCrewRowFromClock(row);});
      input.addEventListener('input',()=>syncCrewRowFromClock(row));
    });
    row.querySelector('.tk-lunch')?.addEventListener('input',()=>syncCrewRowFromClock(row));
    row.querySelector('.tk-employee')?.addEventListener('change',()=>{
      const selected=employees.find(item=>item.id===row.querySelector('.tk-employee')?.value);
      const select=row.querySelector('.tk-equipment');
      if(select){select.innerHTML=equipmentOptions(selected?.default_equipment||'');select.value=selected?.default_equipment||'';}
    });
    const equipmentNotUsed=row.querySelector('.tk-equipment-not-used');
    const syncEquipmentState=()=>{const select=row.querySelector('.tk-equipment');if(select)select.disabled=!!equipmentNotUsed?.checked;};
    equipmentNotUsed?.addEventListener('change',syncEquipmentState);
    syncEquipmentState();
    box.appendChild(row);syncDailyTotals();
    if(row.querySelector('.tk-start')?.value&&row.querySelector('.tk-stop')?.value)syncCrewRowFromClock(row);
  }

  function refreshCrewEmployeeSelects(){
    document.querySelectorAll('#dailyCrewTimeRows .tk-employee').forEach(select=>{
      const selected=select.value;
      const html=employeeOptions(selected);
      if(select.dataset.lcEmployeeOptions===html)return;
      select.innerHTML=html;
      select.value=selected;
      select.dataset.lcEmployeeOptions=html;
    });
  }

  function collectCrewRows(){
    const seen=new Set();const rows=[];
    document.querySelectorAll('#dailyCrewTimeRows .tk-crew-row').forEach(row=>{
      const employee_id=row.querySelector('.tk-employee')?.value||'';
      if(!employee_id || seen.has(employee_id)) return;
      seen.add(employee_id);
      const regular_hours=number(row.querySelector('.tk-regular')?.value);
      const overtime_hours=number(row.querySelector('.tk-ot')?.value);
      if(regular_hours<0||overtime_hours<0||regular_hours+overtime_hours>24)return;
      const perDiemInput=row.querySelector('.tk-per-diem');
      const equipmentNotUsed=!!row.querySelector('.tk-equipment-not-used')?.checked;
      rows.push({
        employee_id,
        regular_hours,
        overtime_hours,
        start_time:row.querySelector('.tk-start')?.value||null,
        stop_time:row.querySelector('.tk-stop')?.value||null,
        lunch_minutes:Math.max(0,Math.min(720,Math.round(number(row.querySelector('.tk-lunch')?.value)))),
        per_diem:perDiemInput?!!perDiemInput.checked:true,
        equipment_used:equipmentNotUsed?null:(row.querySelector('.tk-equipment')?.value||null),
        equipment_not_used:equipmentNotUsed
      });
    });
    return rows;
  }

  function syncDailyTotals(){
    const rows=collectCrewRows();
    if(!rows.length){if(byId('dailyCrewTimeTotals'))byId('dailyCrewTimeTotals').textContent='';return;}
    const reg=rows.reduce((s,r)=>s+r.regular_hours,0);const ot=rows.reduce((s,r)=>s+r.overtime_hours,0);
    if(byId('dailyRegularHours')) byId('dailyRegularHours').value=reg;
    if(byId('dailyOvertimeHours')) byId('dailyOvertimeHours').value=ot;
    if(byId('dailyCrewTimeTotals')) byId('dailyCrewTimeTotals').textContent=`Crew total: ${reg.toFixed(2)} regular / ${ot.toFixed(2)} OT`;
  }

  async function loadDefaultCrewRows(){
    if(!employees.length) await loadEmployees();
    const box=byId('dailyCrewTimeRows');if(!box)return;
    const crew=(byId('dailyCrewName')?.value||'').trim().toLowerCase();
    const matches=employees.filter(e=>e.active && crew && String(e.default_crew_name||'').trim().toLowerCase()===crew);
    if(matches.length){box.innerHTML='';matches.forEach(e=>addCrewRow({employee_id:e.id}));}
  }

  function preferredCrewName(){
    if(role()!=='foreman')return '';
    const viewerId=typeof currentProfile!=='undefined' ? currentProfile?.id||null : null;
    if(!viewerId)return '';
    const own=employees.find(e=>e.active&&e.linked_profile_id===viewerId);
    const ownCrew=String(own?.default_crew_name||'').trim();
    if(ownCrew)return ownCrew;
    const counts=new Map();
    employees.filter(e=>e.active&&e.assigned_foreman_id===viewerId).forEach(e=>{
      const name=String(e.default_crew_name||'').trim();
      if(name)counts.set(name,(counts.get(name)||0)+1);
    });
    const ranked=[...counts.entries()].sort((a,b)=>b[1]-a[1]||a[0].localeCompare(b[0]));
    if(ranked.length===1)return ranked[0][0];
    if(ranked[0]?.[1]>ranked[1]?.[1])return ranked[0][0];
    return '';
  }

  function fillDefaultCrewName(){
    const form=byId('dailyReportForm');
    const input=byId('dailyCrewName');
    if(!form||!input||form.dataset.reportId||input.value.trim())return;
    const crewName=preferredCrewName();
    if(crewName)input.value=crewName;
  }

  async function loadCrewRowsForReport(){
  const form=byId('dailyReportForm');if(!form||form.classList.contains('hidden'))return;
  const reportId=form.dataset.reportId||null;
  const loadKey=reportId||'new';
  if(crewRowsLoadedForReport===loadKey)return;
  crewRowsLoadedForReport=loadKey;
  if(!employees.length) await loadEmployees();
  fillDefaultCrewName();
  refreshCrewEmployeeSelects();
  const box=byId('dailyCrewTimeRows');if(!box)return;
  box.innerHTML='';
  if(role()==='foreman'){
    const viewerId=typeof currentProfile!=='undefined' ? currentProfile?.id||null : null;
    const own=employees.find(e=>e.active&&e.linked_profile_id===viewerId)||null;
    if(reportId){
      const {data,error}=await getSb().from('timekeeping_entries').select('employee_id,regular_hours,overtime_hours,start_time,stop_time,lunch_minutes,per_diem,equipment_used,equipment_not_used').eq('daily_report_id',reportId).order('created_at');
      if(!error){
        const saved=data||[];
        const ownSaved=own?saved.find(x=>x.employee_id===own.id):null;
        if(own)addCrewRow(ownSaved||{employee_id:own.id});
        saved.filter(x=>!own||x.employee_id!==own.id).forEach(addCrewRow);
        if(saved.length||own)return;
      }
    }
    if(own)addCrewRow({employee_id:own.id});
    employees.filter(e=>e.active&&e.assigned_foreman_id===viewerId&&(!own||e.id!==own.id)).forEach(e=>addCrewRow({employee_id:e.id}));
    return;
  }
  if(reportId){
    const {data,error}=await getSb().from('timekeeping_entries').select('employee_id,regular_hours,overtime_hours,start_time,stop_time,lunch_minutes,per_diem,equipment_used,equipment_not_used').eq('daily_report_id',reportId).order('created_at');
    if(!error && data?.length){data.forEach(addCrewRow);return;}
  }
  await loadDefaultCrewRows();
}

  async function persistCrewTime(snapshot, reportId){
    if(!reportId)throw new Error('The Daily Report must be saved before its crew time can be recorded.');
    const jobId=byId('dailyJobId')?.value||null;const workDate=byId('dailyWorkDate')?.value;if(!workDate)return;
    const crewName=(byId('dailyCrewName')?.value||'').trim()||null;
    const stormWork=typeof currentStormModeAssigned!=='undefined' ? !!currentStormModeAssigned : false;
    const {data:{user}}=await getSb().auth.getUser();if(!user)throw new Error('Your session expired. Sign in again before saving crew time.');
    const rows=snapshot.map(r=>({company_id:companyId(),employee_id:r.employee_id,daily_report_id:reportId,job_id:jobId,work_date:workDate,crew_name:crewName,regular_hours:r.regular_hours,overtime_hours:r.overtime_hours,storm_work:stormWork,start_time:r.start_time||null,stop_time:r.stop_time||null,lunch_minutes:r.lunch_minutes||0,per_diem:r.per_diem===true,equipment_used:r.equipment_not_used?null:(r.equipment_used||null),equipment_not_used:r.equipment_not_used===true,created_by:user.id,updated_by:user.id,updated_at:new Date().toISOString()}));
    if(rows.length){
      const {error}=await getSb().from('timekeeping_entries').upsert(rows,{onConflict:'company_id,employee_id,work_date,job_id'});
      if(error)throw error;
    }
    let staleQuery=getSb().from('timekeeping_entries').delete().eq('daily_report_id',reportId);
    if(snapshot.length)staleQuery=staleQuery.not('employee_id','in','('+snapshot.map(row=>row.employee_id).join(',')+')');
    const {error:deleteError}=await staleQuery;
    if(deleteError)throw deleteError;
    for(const row of snapshot){
      const {error:otError}=await getSb().rpc('recalculate_timekeeping_employee_week',{p_report_id:reportId,p_employee_id:row.employee_id});
      if(otError)throw otError;
    }
    if(snapshot.length){
      const {data:recalculated,error:reloadError}=await getSb().from('timekeeping_entries').select('employee_id,regular_hours,overtime_hours').eq('daily_report_id',reportId);
      if(reloadError)throw reloadError;
      const byEmployee=new Map((recalculated||[]).map(entry=>[entry.employee_id,entry]));
      document.querySelectorAll('#dailyCrewTimeRows .tk-crew-row').forEach(row=>{
        const employeeId=row.querySelector('.tk-employee')?.value||'';
        const saved=byEmployee.get(employeeId);
        if(!saved)return;
        const regular=row.querySelector('.tk-regular'),ot=row.querySelector('.tk-ot');
        if(regular)regular.value=number(saved.regular_hours).toFixed(2);
        if(ot)ot.value=number(saved.overtime_hours).toFixed(2);
      });
      syncDailyTotals();
    }
    crewRowsLoadedForReport=reportId;
  }

  window.LineCrewCoreSavesTimekeepingDetails=true;
  window.saveDailyReportCrewTime=async(reportId)=>{
    syncDailyTotals();
    await persistCrewTime(collectCrewRows(),reportId);
  };

  function addRunRates(){
    const box=byId('productionReportingMetrics');if(!box)return;
    const spans=[...box.querySelectorAll(':scope > span')];
    if(!spans.length)return;
    const find=(label)=>spans.find(s=>s.textContent.includes(label));
    const parseMoney=(span)=>number((span?.querySelector('strong')?.textContent||'').replace(/[^0-9.-]/g,''));
    const parseHours=(span)=>number(span?.querySelector('strong')?.textContent);
    const actual=parseMoney(find('Actual Unit Value'));
    const field=parseMoney(find('Field Unit Value'));
    const reg=parseHours(find('Regular Hours'));
    const ot=parseHours(find('OT Hours'));
    const denominator=reg+(ot*1.5);
    const desired=[['Actual MH Run Rate',denominator?actual/denominator:0],['Field MH Run Rate',denominator?field/denominator:0]];
    desired.forEach(([label,value])=>{
      let span=spans.find(s=>s.textContent.includes(label));
      const isField=label==='Field MH Run Rate';
      const formatted=new Intl.NumberFormat('en-US',{style:'currency',currency:'USD'}).format(value);
      const valueHtml=isField && typeof window.manHourRateNumberMarkup==='function'
        ? window.manHourRateNumberMarkup(value)
        : '<strong>'+formatted+'</strong>';
      const html=valueHtml+'<br>'+label;
      if(!span){span=document.createElement('span');box.appendChild(span);}
      if(span.innerHTML!==html)span.innerHTML=html;
    });
  }

  function watchApp(){
    const observer=new MutationObserver(()=>{
      addTile();
      injectCrewTime();
      addRunRates();
      if(byId('dailyReportForm') && !byId('dailyReportForm').classList.contains('hidden')) loadCrewRowsForReport();
      else crewRowsLoadedForReport=null;
    });
    observer.observe(document.body,{subtree:true,childList:true,attributes:true,attributeFilter:['class']});
  }

  function init(){
    addStyles();createPage();addTile();injectCrewTime();watchApp();
    setTimeout(()=>{ if(companyId()) loadEmployees().then(()=>{refreshCrewEmployeeSelects();loadCrewRowsForReport();}); addRunRates(); },800);
  }

  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',init);else init();
})();
