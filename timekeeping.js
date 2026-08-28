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
  const getSb = () => typeof sb !== 'undefined' ? sb : window.sb;
  const todayIso = () => new Date().toISOString().slice(0,10);
  const mondayIso = () => {
    const d = new Date();
    const day = (d.getDay() + 6) % 7;
    d.setDate(d.getDate() - day);
    return d.toISOString().slice(0,10);
  };

  let employees = [];
  let foremen = [];
  let entries = [];
  let jobs = [];
  let crewRowsLoadedForReport = null;
  let crewRowCounter = 0;

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
      .tk-crew-card{border:1px solid #dce5ed;border-radius:14px;padding:14px;margin:14px 0;background:#f8fafc}
      .tk-crew-row{display:grid;grid-template-columns:minmax(180px,1.6fr) minmax(90px,.7fr) minmax(90px,.7fr) auto;gap:8px;align-items:end;margin:8px 0}
      .tk-crew-row label{margin:0;font-size:12px}
      .tk-crew-row button{width:auto;margin:0;padding:11px}
      .tk-help{font-size:13px;color:#6c7a89}
      .tk-inline-actions{display:flex;gap:8px;flex-wrap:wrap;align-items:center}
      .tk-inline-actions button{width:auto}
      @media(max-width:720px){.tk-grid,.tk-summary{grid-template-columns:1fr 1fr}.tk-crew-row{grid-template-columns:1fr 1fr}.tk-crew-row .tk-person{grid-column:1/-1}}
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
        <h3>Manage Foreman Crews</h3>
        <p class="muted">Add field employees who do not need a LineCrew login. Open a Foreman section below and use the Assigned Foreman dropdown to move employees between crews. Assigned members automatically appear on that Foreman's Daily Report.</p>
        <div class="tk-grid">
          <label>Employee #<input id="tkEmployeeNumber" type="text" placeholder="Optional"></label>
          <label>Employee Name<input id="tkEmployeeName" type="text" placeholder="Full name"></label>
          <label>Classification<input id="tkEmployeeClass" type="text" placeholder="Lineman, Operator, Groundman..."></label>
          <label>Default Crew<input id="tkEmployeeCrew" type="text" placeholder="Crew name / number"></label>
          <label>Assigned Foreman<select id="tkEmployeeForeman"><option value="">Unassigned</option></select></label>
        </div>
        <button id="tkAddEmployeeBtn" class="success">Add Employee</button>
        <div id="tkRosterList" style="margin-top:12px"></div>
      </div>
      <div id="timekeepingReportCard" class="card">
        <h3>Time Report</h3>
        <div class="tk-grid">
          <label>From<input id="tkFromDate" type="date"></label>
          <label>Through<input id="tkThroughDate" type="date"></label>
          <label>Employee<select id="tkEmployeeFilter"><option value="">All employees</option></select></label>
          <label>Job<select id="tkJobFilter"><option value="">All jobs</option></select></label>
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
    await Promise.all([loadEmployees(), loadJobs(), loadForemen()]);
    renderRoster();
    fillFilters();
    await loadEntries();
  }

  async function loadEmployees(){
    if(!companyId()) return;
    const { data, error } = await getSb().from('timekeeping_employees')
      .select('id,employee_number,full_name,classification,default_crew_name,active,assigned_foreman_id,linked_profile_id')
      .eq('company_id', companyId())
      .order('active', { ascending:false })
      .order('full_name');
    if(error){ console.error('Timekeeping employee load failed', error); return; }
    employees = data || [];
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
      active: true
    };
    const { error } = await getSb().from('timekeeping_employees').insert(payload);
    if(error) return alert('Could not add employee: ' + error.message);
    ['tkEmployeeNumber','tkEmployeeName','tkEmployeeClass','tkEmployeeCrew','tkEmployeeForeman'].forEach(id => { if(byId(id)) byId(id).value=''; });
    await loadEmployees();
    renderRoster();
    fillFilters();
    refreshCrewEmployeeSelects();
  }

  async function toggleEmployee(id, active){
    const { error } = await getSb().from('timekeeping_employees').update({active,updated_at:new Date().toISOString()}).eq('id',id);
    if(error) return alert('Could not update employee: ' + error.message);
    await loadEmployees();
    renderRoster();
    fillFilters();
    refreshCrewEmployeeSelects();
  }

  async function assignEmployee(id, assignedForemanId){
    if(!canManageRoster()) return;
    const { error } = await getSb().from('timekeeping_employees')
      .update({assigned_foreman_id:assignedForemanId||null,updated_at:new Date().toISOString()})
      .eq('id',id);
    if(error) return alert('Could not assign employee: '+error.message);
    await loadEmployees();
    renderRoster();
    refreshCrewEmployeeSelects();
  }

  function renderRoster(){
    const box = byId('tkRosterList');
    if(!box) return;
    if(!employees.length){box.innerHTML='<p class="muted">No employees have been added yet.</p>';return;}
    const foremanOptions=(selected)=>'<option value="">Unassigned</option>'+foremen.map(f=>`<option value="${esc(f.id)}" ${f.id===selected?'selected':''}>${esc(f.full_name||'Foreman')}</option>`).join('');
    const employeeRows=(group)=>group.map(e=>`<tr><td data-label="Employee"><strong>${esc(e.full_name)}</strong></td><td data-label="#">${esc(e.employee_number || '')}</td><td data-label="Classification">${esc(e.classification || '')}</td><td data-label="Default Crew">${esc(e.default_crew_name || '')}</td><td data-label="Assigned Foreman"><select data-tk-foreman="${esc(e.id)}" ${e.active?'':'disabled'}>${foremanOptions(e.assigned_foreman_id)}</select></td><td data-label="Status">${e.active ? 'Active':'Inactive'}</td><td data-label="Action" class="tk-row-actions"><button class="secondary small" data-tk-toggle="${esc(e.id)}" data-active="${e.active ? '0':'1'}">${e.active ? 'Deactivate':'Activate'}</button></td></tr>`).join('');
    const crewGroups=foremen.map(f=>({name:f.full_name||'Foreman',members:employees.filter(e=>e.assigned_foreman_id===f.id)}));
    crewGroups.push({name:'Unassigned Employees',members:employees.filter(e=>!e.assigned_foreman_id)});
    box.innerHTML=crewGroups.map(group=>`<details class="job-card tk-crew-group"><summary><strong>${esc(group.name)}</strong> — ${group.members.length} crew member${group.members.length===1?'':'s'}</summary>${group.members.length?`<div class="tk-table-wrap"><table class="tk-table"><thead><tr><th>Employee</th><th>#</th><th>Classification</th><th>Default Crew</th><th>Assigned Foreman</th><th>Status</th><th></th></tr></thead><tbody>${employeeRows(group.members)}</tbody></table></div>`:'<p class="muted">No employees assigned.</p>'}</details>`).join('');
    box.querySelectorAll('[data-tk-toggle]').forEach(btn => btn.onclick = () => toggleEmployee(btn.dataset.tkToggle, btn.dataset.active === '1'));
    box.querySelectorAll('[data-tk-foreman]').forEach(select => select.onchange = () => assignEmployee(select.dataset.tkForeman,select.value));
  }

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
    card.innerHTML=`<h3>Crew Time</h3><p class="tk-help">Your assigned crew loads automatically. Use Add Extra Man for another active company employee helping your crew today. Daily Report totals update automatically.</p><div id="dailyCrewTimeRows"></div><div class="tk-inline-actions"><button id="dailyAddCrewMember" type="button" class="secondary small">+ Add Extra Man</button><span id="dailyCrewTimeTotals" class="muted"></span></div>`;
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

  function addCrewRow(data={}){
    const box=byId('dailyCrewTimeRows');if(!box)return;
    const row=document.createElement('div');
    row.className='tk-crew-row';row.dataset.row=String(++crewRowCounter);
    row.innerHTML=`<label class="tk-person">Employee<select class="tk-employee">${employeeOptions(data.employee_id||'')}</select></label><label>Regular<input class="tk-regular" type="number" min="0" max="24" step="0.25" value="${number(data.regular_hours)}"></label><label>OT<input class="tk-ot" type="number" min="0" max="24" step="0.25" value="${number(data.overtime_hours)}"></label><button type="button" class="danger small tk-remove">Remove</button>`;
    row.querySelector('.tk-remove').onclick=()=>{row.remove();syncDailyTotals();};
    row.querySelectorAll('input,select').forEach(el=>el.addEventListener('change',syncDailyTotals));
    box.appendChild(row);syncDailyTotals();
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
      const {data,error}=await getSb().from('timekeeping_entries').select('employee_id,regular_hours,overtime_hours').eq('daily_report_id',reportId).order('created_at');
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
    const {data,error}=await getSb().from('timekeeping_entries').select('employee_id,regular_hours,overtime_hours').eq('daily_report_id',reportId).order('created_at');
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
