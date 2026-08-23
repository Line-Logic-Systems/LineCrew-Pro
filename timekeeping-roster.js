/* LineCrew Pro - Timekeeping roster import and Foreman crew assignment */
(() => {
  'use strict';

  const byId = (id) => document.getElementById(id);
  const esc = (value) => String(value ?? '').replace(/[&<>"']/g, (ch) => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));
  const getSb = () => typeof sb !== 'undefined' ? sb : window.sb;
  const profile = () => typeof currentProfile !== 'undefined' ? currentProfile : null;
  const role = () => String(profile()?.role || '').toLowerCase();
  const companyId = () => profile()?.company_id || null;
  const userId = () => profile()?.id || null;

  let roster = [];
  let assigned = [];
  let uploadRows = [];
  let lastAutoLoadKey = null;
  let refreshTimer = null;

  const normalized = (value) => String(value ?? '').trim().toLowerCase().replace(/[^a-z0-9]+/g, ' ').trim();

  function addStyles(){
    if(byId('tkRosterEnhancementStyles')) return;
    const style = document.createElement('style');
    style.id = 'tkRosterEnhancementStyles';
    style.textContent = `
      .tk-import-box{border:1px dashed #9eb6ca;border-radius:14px;padding:14px;margin:14px 0;background:#f8fbfe}
      .tk-import-box input{margin-top:6px}
      .tk-import-preview{margin-top:10px;font-size:13px;color:#5e6f80}
      .tk-my-crew-list{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:8px;margin:12px 0}
      .tk-my-crew-person{display:flex;align-items:center;gap:9px;border:1px solid #dce5ed;border-radius:11px;padding:10px;background:#fff}
      .tk-my-crew-person input{width:auto;margin:0}
      .tk-assigned-other{opacity:.55}
      @media(max-width:720px){.tk-my-crew-list{grid-template-columns:1fr}}
    `;
    document.head.appendChild(style);
  }

  async function loadRoster(){
    if(!companyId() || !getSb()) return [];
    const {data,error} = await getSb().from('timekeeping_employees')
      .select('id,employee_number,full_name,classification,default_crew_name,active,assigned_foreman_id')
      .eq('company_id', companyId())
      .order('active',{ascending:false})
      .order('full_name');
    if(error){ console.error('Roster enhancement load failed', error); return roster; }
    roster = data || [];
    assigned = roster.filter(e => e.active && e.assigned_foreman_id === userId());
    return roster;
  }

  function refreshBaseTimekeeping(){
    const tile = byId('timekeepingTile');
    if(tile && !byId('timekeepingPage')?.classList.contains('hidden')) tile.click();
  }

  function detectColumn(headers, choices){
    const map = new Map(headers.map(h => [normalized(h), h]));
    for(const choice of choices){
      const exact = map.get(normalized(choice));
      if(exact) return exact;
    }
    for(const header of headers){
      const n = normalized(header);
      if(choices.some(c => n.includes(normalized(c)))) return header;
    }
    return null;
  }

  async function parseRosterFile(file){
    if(!file) return;
    if(typeof XLSX === 'undefined') return alert('Spreadsheet support is still loading. Please try again.');
    try{
      const buffer = await file.arrayBuffer();
      const workbook = XLSX.read(buffer,{type:'array'});
      const sheet = workbook.Sheets[workbook.SheetNames[0]];
      const rows = XLSX.utils.sheet_to_json(sheet,{defval:''});
      if(!rows.length) throw new Error('No roster rows were found.');
      const headers = Object.keys(rows[0]);
      const cols = {
        employee_number: detectColumn(headers,['employee #','employee number','emp #','emp number','employee id','emp id']),
        full_name: detectColumn(headers,['employee name','full name','name']),
        classification: detectColumn(headers,['classification','class','title','position','job title']),
        default_crew_name: detectColumn(headers,['default crew','crew name','crew','crew #','crew number'])
      };
      if(!cols.full_name) throw new Error('Could not find an Employee Name, Full Name, or Name column.');
      uploadRows = rows.map(row => ({
        employee_number: cols.employee_number ? String(row[cols.employee_number] ?? '').trim() : '',
        full_name: String(row[cols.full_name] ?? '').trim(),
        classification: cols.classification ? String(row[cols.classification] ?? '').trim() : '',
        default_crew_name: cols.default_crew_name ? String(row[cols.default_crew_name] ?? '').trim() : ''
      })).filter(row => row.full_name);
      byId('tkRosterImportPreview').innerHTML = uploadRows.length
        ? `<strong>${uploadRows.length}</strong> employees ready to import. Detected: ${cols.employee_number ? esc(cols.employee_number) : 'no employee #'}, ${esc(cols.full_name)}${cols.classification ? ', '+esc(cols.classification) : ''}${cols.default_crew_name ? ', '+esc(cols.default_crew_name) : ''}.`
        : 'No valid employee rows found.';
      byId('tkImportRosterBtn').disabled = !uploadRows.length;
    }catch(error){
      uploadRows = [];
      byId('tkImportRosterBtn').disabled = true;
      byId('tkRosterImportPreview').textContent = error.message || 'Could not read roster file.';
    }
  }

  async function importRoster(){
    if(!['admin','owner'].includes(role())) return alert('Only an Owner or Admin can upload the company roster.');
    if(!uploadRows.length) return alert('Choose a roster file first.');
    const button = byId('tkImportRosterBtn');
    button.disabled = true;
    button.textContent = 'Importing...';
    const {data,error} = await getSb().rpc('admin_import_timekeeping_roster',{p_rows:uploadRows});
    button.textContent = 'Import Roster';
    button.disabled = false;
    if(error) return alert('Roster import failed: ' + error.message);
    const result = data || {};
    alert(`Roster imported. ${Number(result.inserted||0)} added and ${Number(result.updated||0)} updated.`);
    uploadRows = [];
    if(byId('tkRosterFile')) byId('tkRosterFile').value='';
    if(byId('tkRosterImportPreview')) byId('tkRosterImportPreview').textContent='';
    await loadRoster();
    refreshBaseTimekeeping();
  }

  function installAdminImport(){
    const card = byId('timekeepingRosterCard');
    if(!card || !['admin','owner'].includes(role()) || byId('tkRosterImportBox')) return;
    const box = document.createElement('div');
    box.id='tkRosterImportBox';
    box.className='tk-import-box';
    box.innerHTML=`<strong>Upload Employee Roster</strong><p class="tk-help">Upload Excel or CSV. The file needs an employee name column; Employee #, Classification and Crew are optional.</p><input id="tkRosterFile" type="file" accept=".xlsx,.xls,.csv,text/csv,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"><div id="tkRosterImportPreview" class="tk-import-preview"></div><button id="tkImportRosterBtn" type="button" class="secondary" disabled>Import Roster</button>`;
    const addButton = byId('tkAddEmployeeBtn');
    card.insertBefore(box, addButton || card.children[2] || null);
    byId('tkRosterFile').addEventListener('change', e => parseRosterFile(e.target.files?.[0]));
    byId('tkImportRosterBtn').onclick = importRoster;
  }

  async function installMyCrew(){
    // Crew membership is assigned by company leadership, never self-selected.
    return;
  }

  function assignedOptions(selected=''){
    const active = roster.filter(e=>e.active);
    return '<option value="">Select employee</option>'+active.map(e=>{
      const extra=e.assigned_foreman_id!==userId();
      return `<option value="${esc(e.id)}" ${e.id===selected?'selected':''}>${esc(e.full_name)}${e.classification?' — '+esc(e.classification):''}${extra?' — Extra crew':''}</option>`;
    }).join('');
  }

  function restrictDailySelectors(){
    if(role()!=='foreman')return;
    document.querySelectorAll('#dailyCrewTimeRows .tk-employee').forEach(select=>{
      const selected=select.value;
      const html=assignedOptions(selected);
      if(select.dataset.lcEmployeeOptions===html)return;
      select.innerHTML=html;
      select.value=selected;
      select.dataset.lcEmployeeOptions=html;
    });
  }

  async function autoLoadAssignedCrew(){
    if(role()!=='foreman' || !companyId())return;
    const form=byId('dailyReportForm');
    const rowsBox=byId('dailyCrewTimeRows');
    const addButton=byId('dailyAddCrewMember');
    if(!form || form.classList.contains('hidden') || !rowsBox || !addButton)return;
    const key=form.dataset.reportId||`new:${byId('dailyJobId')?.value||''}:${byId('dailyWorkDate')?.value||''}`;
    if(lastAutoLoadKey===key){restrictDailySelectors();return;}
    await loadRoster();
    if(!assigned.length){lastAutoLoadKey=key;restrictDailySelectors();return;}
    await new Promise(resolve=>setTimeout(resolve,220));
    if(rowsBox.querySelector('.tk-crew-row')){lastAutoLoadKey=key;restrictDailySelectors();return;}
    assigned.forEach(employee=>{
      addButton.click();
      const selects=[...rowsBox.querySelectorAll('.tk-employee')];
      const select=selects[selects.length-1];
      if(select){select.innerHTML=assignedOptions(employee.id);select.value=employee.id;select.dispatchEvent(new Event('change',{bubbles:true}));}
    });
    lastAutoLoadKey=key;
    restrictDailySelectors();
  }

  function scheduleRefresh(){
    clearTimeout(refreshTimer);
    refreshTimer=setTimeout(()=>{
      installAdminImport();
      installMyCrew();
      autoLoadAssignedCrew();
      restrictDailySelectors();
    },80);
  }

  function init(){
    addStyles();
    scheduleRefresh();
    const observer=new MutationObserver(scheduleRefresh);
    observer.observe(document.body,{subtree:true,childList:true,attributes:true,attributeFilter:['class']});
  }

  if(document.readyState==='loading')document.addEventListener('DOMContentLoaded',init);else init();
})();
