/* LineCrew Pro - leadership self time for GF, Superintendent, Admin, and Owner */
(() => {
  'use strict';

  const byId = (id) => document.getElementById(id);
  const esc = (value) => String(value ?? '').replace(/[&<>"']/g, (character) => ({
    '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'
  }[character]));
  const num = (value) => Number(value || 0) || 0;
  const profile = () => typeof currentProfile !== 'undefined' ? currentProfile : window.currentProfile;
  const role = () => String(profile()?.role || '').toLowerCase();
  const canEnterMyTime = () => ['gf','superintendent','admin','owner'].includes(role());
  const getSb = () => {
    try { return typeof sb !== 'undefined' ? sb : (window.sb || window.supabaseClient || null); }
    catch (_) { return window.sb || window.supabaseClient || null; }
  };
  const todayIso = () => {
    const now = new Date();
    now.setMinutes(now.getMinutes() - now.getTimezoneOffset());
    return now.toISOString().slice(0,10);
  };
  const timeText = (value) => value ? String(value).slice(0,5) : '';
  const overheadCodes = ['Company Overhead','Administration','Travel','Training','Other'];

  let employee = null;
  let jobs = [];
  let entries = [];
  let editId = null;
  let loadInFlight = null;

  function toast(message, type = 'info') {
    if (window.LineCrewUI?.toast) window.LineCrewUI.toast(message, type);
    else if (type === 'error') alert(message);
  }

  function addStyles() {
    if (byId('leadershipMyTimeStyles')) return;
    const style = document.createElement('style');
    style.id = 'leadershipMyTimeStyles';
    style.textContent = `
      .my-time-card{border-left:4px solid #1677d2}
      .my-time-grid{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:10px;align-items:end}
      .my-time-grid label{margin:0}
      .my-time-wide{grid-column:span 2}
      .my-time-checks{display:flex;align-items:center;gap:18px;flex-wrap:wrap;margin:12px 0}
      .my-time-checks label{display:flex;align-items:center;gap:7px;margin:0}
      .my-time-checks input{width:auto;margin:0}
      .my-time-actions{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
      .my-time-actions button{width:auto;margin:0}
      .my-time-hours{display:inline-flex;align-items:baseline;gap:5px;padding:9px 12px;border:1px solid #cbd9e5;background:#eef5fb;border-radius:10px;color:#0b2d4d}
      .my-time-hours strong{font-size:20px}
      .my-time-history{margin-top:16px;border-top:1px solid #dce5ed;padding-top:12px}
      .my-time-row{display:grid;grid-template-columns:minmax(92px,.8fr) minmax(130px,1.2fr) repeat(3,minmax(70px,.65fr)) auto;gap:8px;align-items:center;padding:9px 8px;border-bottom:1px solid #e2e9ef;font-size:12px}
      .my-time-row.my-time-header{font-size:10px;text-transform:uppercase;color:#617284;font-weight:700;background:#f7fafc;border-radius:8px 8px 0 0}
      .my-time-row button{width:auto;margin:0;padding:6px 9px;font-size:11px}
      .my-time-charge{font-weight:700;color:#0b2d4d}
      .my-time-status{min-height:18px;margin:8px 0;color:#617284;font-size:12px}
      @media(max-width:800px){
        .my-time-grid{grid-template-columns:repeat(2,minmax(0,1fr))}
        .my-time-row{grid-template-columns:minmax(90px,.8fr) minmax(130px,1.2fr) 70px auto}
        .my-time-row>:nth-child(4),.my-time-row>:nth-child(5){display:none}
      }
      @media(max-width:520px){
        .my-time-grid{grid-template-columns:1fr}
        .my-time-wide{grid-column:auto}
        .my-time-row{grid-template-columns:1fr auto;gap:4px}
        .my-time-row>:nth-child(3),.my-time-row>:nth-child(4),.my-time-row>:nth-child(5){display:none}
        .my-time-row.my-time-header{display:none}
      }
    `;
    document.head.appendChild(style);
  }

  function installCard() {
    const page = byId('timekeepingPage');
    if (!page) return false;
    let card = byId('leadershipMyTimeCard');
    if (!card) {
      card = document.createElement('div');
      card.id = 'leadershipMyTimeCard';
      card.className = 'card my-time-card hidden';
      card.innerHTML = `
        <div class="section-header">
          <div>
            <h3>My Time</h3>
            <p class="muted">Enter your own day for payroll. Charge the time to an active job or an overhead labor code.</p>
          </div>
          <button id="myTimeNewBtn" type="button" class="secondary small">New Entry</button>
        </div>
        <div class="my-time-grid">
          <label>Work Date<input id="myTimeDate" type="date"></label>
          <label>Start<input id="myTimeStart" type="time" step="60"></label>
          <label>Stop<input id="myTimeStop" type="time" step="60"></label>
          <label>Lunch (minutes)<input id="myTimeLunch" type="number" min="0" max="720" step="1" value="0"></label>
          <label>Charge To<select id="myTimeChargeType"><option value="job">Active Job</option><option value="overhead">Overhead</option></select></label>
          <label id="myTimeJobWrap" class="my-time-wide">Job<select id="myTimeJob"><option value="">Choose a job</option></select></label>
          <label id="myTimeLaborWrap" class="my-time-wide hidden">Overhead Labor Code<select id="myTimeLabor">${overheadCodes.map((code) => `<option value="${esc(code)}">${esc(code)}</option>`).join('')}</select></label>
          <label>Equipment<input id="myTimeEquipment" type="text" placeholder="Optional unit / vehicle"></label>
          <label class="my-time-wide">Notes<input id="myTimeNotes" type="text" placeholder="Optional payroll note"></label>
        </div>
        <div class="my-time-checks">
          <label><input id="myTimePerDiem" type="checkbox"> Per diem</label>
          <label><input id="myTimeEquipmentNotUsed" type="checkbox"> Equipment not used</label>
        </div>
        <div class="my-time-actions">
          <button id="myTimeSaveBtn" type="button" class="success">Save My Time</button>
          <button id="myTimeCancelBtn" type="button" class="secondary hidden">Cancel Edit</button>
          <span class="my-time-hours"><strong id="myTimeWorked">—</strong> worked hours</span>
        </div>
        <div id="myTimeStatus" class="my-time-status">Regular and overtime are calculated automatically using the company workweek.</div>
        <div class="my-time-history">
          <div class="section-header"><div><strong>Recent My Time</strong><p class="muted">Your saved entries flow into the same Time Report, pay-period controls, payroll, and exports as crew time.</p></div></div>
          <div id="myTimeHistoryList"><p class="muted">No My Time entries loaded.</p></div>
        </div>`;

      const reportCard = byId('timekeepingReportCard');
      if (reportCard) page.insertBefore(card, reportCard);
      else page.appendChild(card);
      bindEvents();
      resetForm();
    }
    card.classList.toggle('hidden', !canEnterMyTime());
    return true;
  }

  function bindEvents() {
    byId('myTimeChargeType').onchange = toggleChargeFields;
    ['myTimeStart','myTimeStop','myTimeLunch'].forEach((id) => byId(id)?.addEventListener('input', calculateWorked));
    byId('myTimeEquipmentNotUsed').onchange = () => {
      const input = byId('myTimeEquipment');
      if (!input) return;
      input.disabled = byId('myTimeEquipmentNotUsed').checked;
      if (input.disabled) input.value = '';
    };
    byId('myTimeSaveBtn').onclick = save;
    byId('myTimeCancelBtn').onclick = resetForm;
    byId('myTimeNewBtn').onclick = () => {
      resetForm();
      byId('myTimeDate')?.focus();
    };
  }

  function resetForm() {
    editId = null;
    if (byId('myTimeDate')) byId('myTimeDate').value = todayIso();
    ['myTimeStart','myTimeStop','myTimeEquipment','myTimeNotes'].forEach((id) => { if (byId(id)) byId(id).value = ''; });
    if (byId('myTimeLunch')) byId('myTimeLunch').value = '0';
    if (byId('myTimeChargeType')) byId('myTimeChargeType').value = 'job';
    if (byId('myTimeJob')) byId('myTimeJob').value = '';
    if (byId('myTimeLabor')) byId('myTimeLabor').value = 'Company Overhead';
    if (byId('myTimePerDiem')) byId('myTimePerDiem').checked = false;
    if (byId('myTimeEquipmentNotUsed')) byId('myTimeEquipmentNotUsed').checked = false;
    if (byId('myTimeEquipment')) byId('myTimeEquipment').disabled = false;
    if (byId('myTimeSaveBtn')) byId('myTimeSaveBtn').textContent = 'Save My Time';
    byId('myTimeCancelBtn')?.classList.add('hidden');
    toggleChargeFields();
    calculateWorked();
  }

  function toggleChargeFields() {
    const overhead = byId('myTimeChargeType')?.value === 'overhead';
    byId('myTimeJobWrap')?.classList.toggle('hidden', overhead);
    byId('myTimeLaborWrap')?.classList.toggle('hidden', !overhead);
  }

  function calculateWorked() {
    const start = byId('myTimeStart')?.value || '';
    const stop = byId('myTimeStop')?.value || '';
    const lunch = Math.round(num(byId('myTimeLunch')?.value));
    const output = byId('myTimeWorked');
    if (!start || !stop || lunch < 0 || lunch > 720) {
      if (output) output.textContent = '—';
      return null;
    }
    const toMinutes = (value) => {
      const [hours, minutes] = value.split(':').map(Number);
      return (hours * 60) + minutes;
    };
    let elapsed = toMinutes(stop) - toMinutes(start);
    if (elapsed <= 0) elapsed += 1440;
    const worked = (elapsed - lunch) / 60;
    if (worked <= 0 || worked > 24) {
      if (output) output.textContent = '—';
      return null;
    }
    if (output) output.textContent = worked.toFixed(2);
    return worked;
  }

  async function loadReferences() {
    const client = getSb();
    const current = profile();
    if (!client || !current?.company_id || !canEnterMyTime()) return;
    const [employeeResult, jobsResult] = await Promise.all([
      client.from('timekeeping_employees')
        .select('id,full_name,classification,linked_profile_id,active')
        .eq('company_id', current.company_id)
        .eq('linked_profile_id', current.id)
        .eq('active', true)
        .maybeSingle(),
      client.from('jobs')
        .select('id,job_number,job_name,active')
        .eq('company_id', current.company_id)
        .eq('active', true)
        .order('job_number')
    ]);
    if (employeeResult.error) throw employeeResult.error;
    employee = employeeResult.data || null;
    jobs = jobsResult.error ? [] : (jobsResult.data || []);
    const select = byId('myTimeJob');
    if (select) {
      const selected = select.value;
      select.innerHTML = '<option value="">Choose a job</option>' + jobs.map((job) =>
        `<option value="${esc(job.id)}">${esc(job.job_number || 'Job')}${job.job_name ? ' — ' + esc(job.job_name) : ''}</option>`
      ).join('');
      if ([...select.options].some((option) => option.value === selected)) select.value = selected;
    }
    if (!jobs.length && !editId && byId('myTimeChargeType')) {
      byId('myTimeChargeType').value = 'overhead';
      toggleChargeFields();
    }
  }

  async function loadEntries() {
    const client = getSb();
    if (!client || !employee?.id) {
      entries = [];
      renderHistory();
      return;
    }
    const since = new Date();
    since.setDate(since.getDate() - 90);
    const sinceIso = since.toISOString().slice(0,10);
    const {data, error} = await client.from('timekeeping_entries')
      .select('id,job_id,work_date,regular_hours,overtime_hours,start_time,stop_time,lunch_minutes,per_diem,equipment_used,equipment_not_used,notes,labor_code,entry_kind')
      .eq('employee_id', employee.id)
      .eq('entry_kind', 'leadership_self')
      .gte('work_date', sinceIso)
      .order('work_date', {ascending:false})
      .order('created_at', {ascending:false})
      .limit(20);
    if (error) throw error;
    entries = data || [];
    renderHistory();
  }

  function renderHistory() {
    const box = byId('myTimeHistoryList');
    if (!box) return;
    if (!employee) {
      box.innerHTML = '<p class="muted">Your payroll employee record is being prepared. Refresh after your profile is updated.</p>';
      return;
    }
    if (!entries.length) {
      box.innerHTML = '<p class="muted">No My Time entries in the last 90 days.</p>';
      return;
    }
    const jobMap = new Map(jobs.map((job) => [job.id, job]));
    box.innerHTML = '<div class="my-time-row my-time-header"><span>Date</span><span>Charge</span><span>Start–Stop</span><span>Regular</span><span>OT</span><span></span></div>' + entries.map((entry) => {
      const job = jobMap.get(entry.job_id) || {};
      const charge = entry.job_id ? (job.job_number || 'Job') : (entry.labor_code || 'Overhead');
      return `<div class="my-time-row">
        <span>${esc(entry.work_date)}</span>
        <span class="my-time-charge">${esc(charge)}</span>
        <span>${esc(timeText(entry.start_time))}–${esc(timeText(entry.stop_time))}</span>
        <span>${num(entry.regular_hours).toFixed(2)}</span>
        <span>${num(entry.overtime_hours).toFixed(2)}</span>
        <button type="button" class="secondary" data-my-time-edit="${esc(entry.id)}">Edit</button>
      </div>`;
    }).join('');
    box.querySelectorAll('[data-my-time-edit]').forEach((button) => {
      button.onclick = () => editEntry(button.dataset.myTimeEdit);
    });
  }

  function editEntry(id) {
    const entry = entries.find((item) => item.id === id);
    if (!entry) return;
    editId = entry.id;
    byId('myTimeDate').value = entry.work_date || todayIso();
    byId('myTimeStart').value = timeText(entry.start_time);
    byId('myTimeStop').value = timeText(entry.stop_time);
    byId('myTimeLunch').value = String(num(entry.lunch_minutes));
    byId('myTimePerDiem').checked = !!entry.per_diem;
    byId('myTimeEquipmentNotUsed').checked = !!entry.equipment_not_used;
    byId('myTimeEquipment').value = entry.equipment_used || '';
    byId('myTimeEquipment').disabled = !!entry.equipment_not_used;
    byId('myTimeNotes').value = entry.notes || '';
    if (entry.job_id) {
      byId('myTimeChargeType').value = 'job';
      byId('myTimeJob').value = entry.job_id;
    } else {
      byId('myTimeChargeType').value = 'overhead';
      byId('myTimeLabor').value = overheadCodes.includes(entry.labor_code) ? entry.labor_code : 'Other';
    }
    byId('myTimeSaveBtn').textContent = 'Update My Time';
    byId('myTimeCancelBtn').classList.remove('hidden');
    toggleChargeFields();
    calculateWorked();
    byId('leadershipMyTimeCard')?.scrollIntoView({behavior:'smooth', block:'start'});
  }

  async function save() {
    if (!canEnterMyTime()) return toast('This role cannot submit My Time.', 'error');
    if (!employee?.id) return toast('Your payroll employee record is not ready yet. Refresh the page or ask an Admin to update your profile.', 'error');
    const worked = calculateWorked();
    if (worked === null) return toast('Enter a valid Start, Stop, and Lunch. Overnight shifts are supported.', 'warning');
    const chargeType = byId('myTimeChargeType')?.value || 'job';
    const jobId = chargeType === 'job' ? (byId('myTimeJob')?.value || null) : null;
    const laborCode = chargeType === 'overhead' ? (byId('myTimeLabor')?.value || null) : null;
    if (chargeType === 'job' && !jobId) return toast('Choose the active job this time belongs to.', 'warning');
    const lunch = Math.round(num(byId('myTimeLunch')?.value));
    const button = byId('myTimeSaveBtn');
    const done = window.LineCrewUI?.loadingButton?.(button, editId ? 'Updating…' : 'Saving…') || (() => {});
    const status = byId('myTimeStatus');
    if (status) status.textContent = 'Saving and recalculating your company workweek…';
    try {
      const {error} = await getSb().rpc('upsert_my_leadership_time', {
        p_entry_id: editId,
        p_work_date: byId('myTimeDate')?.value || null,
        p_start_time: byId('myTimeStart')?.value || null,
        p_stop_time: byId('myTimeStop')?.value || null,
        p_lunch_minutes: lunch,
        p_job_id: jobId,
        p_labor_code: laborCode,
        p_per_diem: !!byId('myTimePerDiem')?.checked,
        p_equipment_used: (byId('myTimeEquipment')?.value || '').trim() || null,
        p_equipment_not_used: !!byId('myTimeEquipmentNotUsed')?.checked,
        p_notes: (byId('myTimeNotes')?.value || '').trim() || null
      });
      if (error) throw error;
      toast(editId ? 'Your time was updated and weekly overtime was recalculated.' : 'Your time was saved for payroll.', 'success');
      if (status) status.textContent = 'Saved. Regular and overtime now reflect the company workweek.';
      resetForm();
      await loadEntries();
      await window.LineCrewTimekeepingReport?.run?.();
    } catch (error) {
      if (status) status.textContent = 'Your entry was not saved.';
      toast('Could not save My Time: ' + error.message, 'error');
    } finally {
      done();
      if (button) button.textContent = editId ? 'Update My Time' : 'Save My Time';
    }
  }

  async function refresh() {
    if (!installCard() || !canEnterMyTime()) return;
    if (loadInFlight) return loadInFlight;
    loadInFlight = (async () => {
      try {
        await loadReferences();
        await loadEntries();
      } catch (error) {
        toast('Could not load My Time: ' + error.message, 'error');
      }
    })();
    try { await loadInFlight; }
    finally { loadInFlight = null; }
  }

  let pageVisible = false;
  function watch() {
    const observer = new MutationObserver(() => {
      installCard();
      const page = byId('timekeepingPage');
      const visible = !!page && !page.classList.contains('hidden') && canEnterMyTime();
      if (visible && !pageVisible) setTimeout(refresh, 60);
      pageVisible = visible;
    });
    observer.observe(document.body, {subtree:true, childList:true, attributes:true, attributeFilter:['class']});
  }

  function init() {
    addStyles();
    installCard();
    watch();
    setTimeout(refresh, 900);
  }

  window.LineCrewLeadershipMyTime = {refresh, resetForm};
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
