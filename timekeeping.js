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
      .tk-roster-legend{display:flex;gap:14px;align-items:center;flex-wrap:wrap;margin:8px 0 12px;font-size:12px;color:#4f6273}.tk-roster-legend span{display:inline-flex;align-items:center;gap:6px}.tk-roster-swatch{width:18px;height:14px;border:1px solid #cbd9e5;border-radius:4px;background:#fff}.tk-roster-swatch.unassigned{background:#fff8df}
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
      .tk-manager-section{border:1px solid #cbd9e5;border-radius:12px;background:#fff;overflow:hidden;margin-top:12px}
      .tk-manager-section>summary{cursor:pointer;display:flex;align-items:center;justify-content:space-between;gap:12px;padding:13px 14px;font-weight:800;background:#f5f8fb;color:#0b2d4d}
      .tk-manager-section>summary span{font-size:12px;font-weight:400;color:#617284}.tk-manager-section-body{padding:12px 14px 14px}
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
          <div><h2>Timekeeping / Roster</h2><p class="muted">Crew time, personnel, equipment, payroll and production reporting.</p></div>
          <button id="timekeepingBackBtn" class="secondary small">Back to Dashboard</button>
        </div>
      </div>
      <div id="timekeepingRosterCard" class="card hidden">
        <h3>Roster & Equipment Setup</h3>
        <p class="muted">Open only the section you need. Personnel changes save together; equipment assignments save automatically.</p>
        <details id="tkCompleteRoster" class="tk-complete-roster hidden">
          <summary id="tkCompleteRosterSummary">Complete Company Roster</summary>
          <div id="tkCompleteRosterBody" class="tk-complete-roster-body"></div>
        </details>
        <details id="tkPersonnelAssignments" class="tk-manager-section">
          <summary><strong>Personnel & Crew Assignments</strong><span>Add employees and organize Foreman/Admin rosters</span></summary>
          <div id="tkPersonnelAssignmentsBody" class="tk-manager-section-body">
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
        </details>
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
    tile.innerHTML = '<strong>Timekeeping / Roster</strong><span class="muted">Crew hours, personnel, equipment and payroll</span>';
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
    const { error } = await getSb().from('timekeeping_employ