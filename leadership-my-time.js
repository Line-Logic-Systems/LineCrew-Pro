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
  const canAddOtherPeople = () => ['gf','admin'].includes(role());
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

  function militaryTime(value) {
    let digits = String(value || '').trim().replace(/[^0-9:]/g, '');
    if (/^\d{1,2}$/.test(digits)) {
      const hours = Number(digits);
      if (hours >= 0 && hours <= 23) return String(hours).padStart(2,'0') + ':00';
    }
    if (/^\d{3,4}$/.test(digits)) {
      digits = digits.padStart(4,'0');
      digits = digits.slice(0,2) + ':' + digits.slice(2);
    }
    const match = digits.match(/^(\d{1,2}):(\d{1,2})$/);
    if (!match) return '';
    const hours = Number(match[1]);
    const minutes = Number(match[2]);
    if (hours < 0 || hours > 23 || minutes < 0 || minutes > 59) return '';
    return String(hours).padStart(2,'0') + ':' + String(minutes).padStart(2,'0');
  }

  function normalizeMilitaryInput(input) {
    if (!input) return '';
    const normalized = militaryTime(input.value);
    if (normalized) input.value = normalized;
    return normalized;
  }

  let employee = null;
  let employees = [];
  let selectedEmployeeIds = [];
  let activeEmployeeId = null;
  const personDrafts = new Map();
  const temporaryEmployeeIds = new Set();
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
      .my-time-people{margin:12px 0;padding:12px;border:1px solid #cbd9e5;background:#f7fafc;border-radius:12px}
      .my-time-people-picker{display:grid;grid-template-columns:minmax(220px,1fr) auto;gap:8px;align-items:end;margin-top:8px}
      .my-time-people-picker button{width:auto;margin:0}
      .my-time-person-list{display:flex;gap:8px;flex-wrap:wrap;margin-top:10px}
      .my-time-person{display:inline-flex;align-items:center;gap:7px;padding:0;border:1px solid #b9cddd;background:#fff;border-radius:999px;font-size:12px;font-weight:700;color:#0b2d4d;overflow:hidden}
      .my-time-person.active{border-color:#1677d2;background:#eaf4ff;box-shadow:0 0 0 2px rgba(22,119,210,.12)}
      .my-time-person-select{border:0;background:transparent;color:inherit;font:inherit;padding:8px 4px 8px 10px;margin:0;width:auto}
      .my-time-person-badge{font-size:9px;text-transform:uppercase;color:#416785;background:#e8f0f6;border-radius:999px;padding:3px 6px;margin-left:-2px}
      .my-time-person button{border:0;background:transparent;color:#a72828;font-size:16px;line-height:1;padding:0;margin:0;width:auto}
      .my-time-person .my-time-remove-person{padding:8px 9px 8px 3px}
      .my-time-admin-roster{display:grid;gap:12px;margin-top:12px}
      .my-time-admin-row{border:1px solid #b9cddd;background:#fff;border-radius:12px;padding:12px;box-shadow:0 2px 8px rgba(11,45,77,.05)}
      .my-time-admin-row.editing{border-color:#1677d2;box-shadow:0 0 0 2px rgba(22,119,210,.12)}
      .my-time-admin-person{display:flex;align-items:center;justify-content:space-between;gap:10px;margin-bottom:9px;padding-bottom:8px;border-bottom:1px solid #dce5ed}
      .my-time-admin-person-name{display:flex;align-items:baseline;gap:7px;flex-wrap:wrap;color:#0b2d4d}
      .my-time-admin-person-name small{color:#617284;font-weight:400}
      .my-time-admin-person button{width:auto;margin:0;padding:5px 8px}
      .my-time-admin-clock{display:grid;grid-template-columns:repeat(3,minmax(80px,.65fr)) minmax(110px,.7fr);gap:8px;align-items:end}
      .my-time-admin-detail{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:8px;align-items:end;margin-top:8px}
      .my-time-admin-row label{margin:0;font-size:11px}
      .my-time-admin-row input,.my-time-admin-row select{margin:0}
      .my-time-admin-wide{grid-column:span 2}
      .my-time-admin-checks{display:flex;align-items:center;gap:16px;flex-wrap:wrap;margin-top:9px}
      .my-time-admin-checks label{display:flex;align-items:center;gap:6px}
      .my-time-admin-checks input{width:auto}
      .my-time-admin-actions{display:flex;align-items:center;gap:9px;flex-wrap:wrap;margin-top:9px}
      .my-time-admin-actions button{width:auto;margin:0}
      .my-time-admin-worked{display:flex;flex-direction:column;justify-content:center;min-height:42px;padding:7px 10px;border:1px solid #cbd9e5;background:#eef5fb;border-radius:8px;color:#0b2d4d;font-size:10px;text-transform:uppercase}
      .my-time-admin-worked strong{font-size:18px;line-height:1.1}
      .my-time-admin-status{font-size:11px;color:#617284}
      .my-time-active-person{margin:12px 0 8px;padding:10px 12px;border-left:3px solid #1677d2;background:#eef6fd;border-radius:8px;color:#0b2d4d}
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
        .my-time-admin-detail{grid-template-columns:repeat(2,minmax(0,1fr))}
        .my-time-row{grid-template-columns:minmax(90px,.8fr) minmax(130px,1.2fr) 70px auto}
        .my-time-row>:nth-child(4),.my-time-row>:nth-child(5){display:none}
      }
      @media(max-width:520px){
        .my-time-grid{grid-template-columns:1fr}
        .my-time-people-picker{grid-template-columns:1fr}
        .my-time-wide{grid-column:auto}
        .my-time-admin-clock,.my-time-admin-detail{grid-template-columns:1fr 1fr}
        .my-time-admin-wide{grid-column:1/-1}
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
            <p class="muted">Enter payroll time one person at a time. Admin roster members appear automatically.</p>
          </div>
          <button id="myTimeNewBtn" type="button" class="secondary small">New Entry</button>
        </div>
        <div id="myTimePeopleWrap" class="my-time-people hidden">
          <strong id="myTimePeopleTitle">People</strong>
          <p id="myTimePeopleHelp" class="muted">Choose a name to enter that person's individual hours.</p>
          <div class="my-time-people-picker">
            <label>Add Employee<select id="myTimePersonSelect"><option value="">Choose an active employee</option></select></label>
            <button id="myTimeAddPersonBtn" type="button" class="secondary">+ Add Temporary Person</button>
          </div>
          <div id="myTimePersonList" class="my-time-person-list"></div>
          <div id="myTimeAdminRosterRows" class="my-time-admin-roster hidden"></div>
        </div>
        <div id="myTimeSingleEntry">
          <div id="myTimeActivePerson" class="my-time-active-person"></div>
          <div class="my-time-grid">
            <label>Work Date<input id="myTimeDate" type="date"></label>
            <label>Start (24 hr)<input id="myTimeStart" class="my-time-clock24" type="text" inputmode="numeric" maxlength="5" placeholder="0600"></label>
            <label>Stop (24 hr)<input id="myTimeStop" class="my-time-clock24" type="text" inputmode="numeric" maxlength="5" placeholder="1630"></label>
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
            <button id="myTimeSaveBtn" type="button" class="success">Save Time</button>
            <button id="myTimeCancelBtn" type="button" class="secondary hidden">Cancel Edit</button>
            <span class="my-time-hours"><strong id="myTimeWorked">—</strong> worked hours</span>
          </div>
          <div id="myTimeStatus" class="my-time-status">Regular and overtime are calculated automatically using the company workweek.</div>
        </div>
        <div class="my-time-history">
          <div class="section-header"><div><strong>Recent My Time</strong><p class="muted">Entries you submit flow into the same Time Report, pay-period controls, payroll, and exports as crew time.</p></div></div>
          <div id="myTimeHistoryList"><p class="muted">No My Time entries loaded.</p></div>
        </div>`;

      const reportCard = byId('timekeepingReportCard');
      if (reportCard) page.insertBefore(card, reportCard);
      else page.appendChild(card);
      bindEvents();
      resetForm();
    }
    card.classList.toggle('hidden', !canEnterMyTime());
    byId('myTimePeopleWrap')?.classList.toggle('hidden', !canAddOtherPeople());
    byId('myTimeSingleEntry')?.classList.toggle('hidden', role() === 'admin');
    byId('myTimePersonList')?.classList.toggle('hidden', role() === 'admin');
    byId('myTimeAdminRosterRows')?.classList.toggle('hidden', role() !== 'admin');
    const peopleTitle = role() === 'admin' ? 'My Admin Time Roster' : 'People on this entry';
    const peopleHelp = role() === 'admin'
      ? 'Assigned Personnel appear automatically as individual time rows, just like a Foreman crew on a Daily Report.'
      : 'Choose a name to enter individual hours, or add a temporary person for today.';
    const titleElement = byId('myTimePeopleTitle');
    const helpElement = byId('myTimePeopleHelp');
    if (titleElement && titleElement.textContent !== peopleTitle) titleElement.textContent = peopleTitle;
    if (helpElement && helpElement.textContent !== peopleHelp) helpElement.textContent = peopleHelp;
    return true;
  }

  function bindEvents() {
    byId('myTimeChargeType').onchange = toggleChargeFields;
    ['myTimeStart','myTimeStop'].forEach((id) => {
      const input = byId(id);
      input?.addEventListener('input', calculateWorked);
      input?.addEventListener('blur', () => { normalizeMilitaryInput(input); calculateWorked(); });
    });
    byId('myTimeLunch')?.addEventListener('input', calculateWorked);
    byId('myTimeEquipmentNotUsed').onchange = () => {
      const input = byId('myTimeEquipment');
      if (!input) return;
      input.disabled = byId('myTimeEquipmentNotUsed').checked;
      if (input.disabled) input.value = '';
    };
    byId('myTimeSaveBtn').onclick = save;
    byId('myTimeAddPersonBtn').onclick = addSelectedPerson;
    byId('myTimeCancelBtn').onclick = resetForm;
    byId('myTimeNewBtn').onclick = () => {
      resetForm();
      byId('myTimeDate')?.focus();
    };
  }

  function emptyDraft() {
    return {
      workDate: todayIso(), start: '', stop: '', lunch: '0', chargeType: 'job',
      jobId: '', laborCode: 'Company Overhead', equipment: '', notes: '',
      perDiem: false, equipmentNotUsed: false
    };
  }

  function assignedRosterIds() {
    const ids = [];
    if (employee?.id) ids.push(employee.id);
    if (role() === 'admin' && profile()?.id) {
      employees
        .filter((item) => item.active !== false && item.assigned_admin_id === profile().id)
        .forEach((item) => ids.push(item.id));
    }
    return [...new Set(ids)];
  }

  function captureCurrentDraft() {
    if (!activeEmployeeId || !byId('myTimeDate')) return;
    personDrafts.set(activeEmployeeId, {
      workDate: byId('myTimeDate')?.value || todayIso(),
      start: byId('myTimeStart')?.value || '',
      stop: byId('myTimeStop')?.value || '',
      lunch: byId('myTimeLunch')?.value || '0',
      chargeType: byId('myTimeChargeType')?.value || 'job',
      jobId: byId('myTimeJob')?.value || '',
      laborCode: byId('myTimeLabor')?.value || 'Company Overhead',
      equipment: byId('myTimeEquipment')?.value || '',
      notes: byId('myTimeNotes')?.value || '',
      perDiem: !!byId('myTimePerDiem')?.checked,
      equipmentNotUsed: !!byId('myTimeEquipmentNotUsed')?.checked
    });
  }

  function showDraft(id) {
    const draft = personDrafts.get(id) || emptyDraft();
    personDrafts.set(id, draft);
    byId('myTimeDate').value = draft.workDate || todayIso();
    byId('myTimeStart').value = draft.start || '';
    byId('myTimeStop').value = draft.stop || '';
    byId('myTimeLunch').value = String(draft.lunch ?? '0');
    byId('myTimeChargeType').value = draft.chargeType || 'job';
    byId('myTimeJob').value = draft.jobId || '';
    byId('myTimeLabor').value = overheadCodes.includes(draft.laborCode) ? draft.laborCode : 'Other';
    byId('myTimePerDiem').checked = !!draft.perDiem;
    byId('myTimeEquipmentNotUsed').checked = !!draft.equipmentNotUsed;
    byId('myTimeEquipment').value = draft.equipment || '';
    byId('myTimeEquipment').disabled = !!draft.equipmentNotUsed;
    byId('myTimeNotes').value = draft.notes || '';
    toggleChargeFields();
    calculateWorked();
    updateActivePersonLabel();
  }

  function selectPerson(id) {
    if (!id || !selectedEmployeeIds.includes(id) || id === activeEmployeeId) return;
    captureCurrentDraft();
    activeEmployeeId = id;
    showDraft(id);
    renderPeople();
  }

  function updateActivePersonLabel() {
    const label = byId('myTimeActivePerson');
    if (!activeEmployeeId) {
      if (label) label.classList.add('hidden');
      return;
    }
    const name = employeeName(activeEmployeeId);
    if (label) label.classList.remove('hidden');
    if (label) label.innerHTML = `<strong>Entering time for ${esc(name)}</strong><br><span class="muted">These fields and hours belong only to this person.</span>`;
    const saveButton = byId('myTimeSaveBtn');
    if (saveButton) saveButton.textContent = `${editId ? 'Update' : 'Save'} ${name} Time`;
  }

  function resetForm() {
    editId = null;
    personDrafts.clear();
    temporaryEmployeeIds.clear();
    selectedEmployeeIds = assignedRosterIds();
    activeEmployeeId = employee?.id || selectedEmployeeIds[0] || null;
    byId('myTimeCancelBtn')?.classList.add('hidden');
    byId('myTimePeopleWrap')?.classList.toggle('hidden', !canAddOtherPeople());
    if (byId('myTimeAddPersonBtn')) byId('myTimeAddPersonBtn').disabled = false;
    if (byId('myTimePersonSelect')) byId('myTimePersonSelect').disabled = false;
    renderPeople();
    renderPersonOptions();
    if (activeEmployeeId) showDraft(activeEmployeeId);
    else updateActivePersonLabel();
    toggleChargeFields();
    calculateWorked();
  }

  function employeeName(id) {
    const item = employees.find((candidate) => candidate.id === id);
    return item?.full_name || (id === employee?.id ? employee.full_name : 'Employee');
  }

  function adminRowDraft(row) {
    const employeeId = row?.dataset.myTimeRow || '';
    if (!employeeId) return null;
    const clock = (selector) => row.querySelector(selector)?.value || '';
    return {
      workDate: clock('.my-time-admin-date') || todayIso(),
      start: clock('.my-time-admin-start'),
      stop: clock('.my-time-admin-stop'),
      lunch: clock('.my-time-admin-lunch') || '0',
      chargeType: clock('.my-time-admin-charge') || 'job',
      jobId: clock('.my-time-admin-job'),
      laborCode: clock('.my-time-admin-labor') || 'Company Overhead',
      equipment: clock('.my-time-admin-equipment'),
      notes: clock('.my-time-admin-notes'),
      perDiem: !!row.querySelector('.my-time-admin-per-diem')?.checked,
      equipmentNotUsed: !!row.querySelector('.my-time-admin-equipment-not-used')?.checked
    };
  }

  function captureAdminRows() {
    byId('myTimeAdminRosterRows')?.querySelectorAll('[data-my-time-row]').forEach((row) => {
      const draft = adminRowDraft(row);
      if (draft) personDrafts.set(row.dataset.myTimeRow, draft);
    });
  }

  function adminWorked(row) {
    const start = militaryTime(row?.querySelector('.my-time-admin-start')?.value || '');
    const stop = militaryTime(row?.querySelector('.my-time-admin-stop')?.value || '');
    const lunch = Math.round(num(row?.querySelector('.my-time-admin-lunch')?.value));
    const output = row?.querySelector('.my-time-admin-worked strong');
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

  function toggleAdminCharge(row) {
    const overhead = row?.querySelector('.my-time-admin-charge')?.value === 'overhead';
    row?.querySelector('.my-time-admin-job-wrap')?.classList.toggle('hidden', overhead);
    row?.querySelector('.my-time-admin-labor-wrap')?.classList.toggle('hidden', !overhead);
  }

  function adminJobOptions(selected = '') {
    return '<option value="">Choose a job</option>' + jobs.map((job) =>
      `<option value="${esc(job.id)}" ${job.id === selected ? 'selected' : ''}>${esc(job.job_number || 'Job')}${job.job_name ? ' — ' + esc(job.job_name) : ''}</option>`
    ).join('');
  }

  function renderAdminRows() {
    const box = byId('myTimeAdminRosterRows');
    if (!box || role() !== 'admin') return;
    if (!selectedEmployeeIds.length) {
      box.innerHTML = '<p class="muted">No Personnel are assigned to this Admin. Assign them in Manage Personnel Assignments, or add a temporary person above.</p>';
      return;
    }
    box.innerHTML = selectedEmployeeIds.map((id) => {
      const item = employees.find((candidate) => candidate.id === id) || (id === employee?.id ? employee : null) || {};
      const draft = personDrafts.get(id) || emptyDraft();
      personDrafts.set(id, draft);
      const self = id === employee?.id;
      const assigned = item.assigned_admin_id === profile()?.id;
      const persistent = self || assigned;
      const editing = editId && entries.find((entry) => entry.id === editId)?.employee_id === id;
      const chargeType = jobs.length ? (draft.chargeType || 'job') : 'overhead';
      const laborCode = overheadCodes.includes(draft.laborCode) ? draft.laborCode : 'Other';
      return `<div class="my-time-admin-row${editing ? ' editing' : ''}" data-my-time-row="${esc(id)}">
        <div class="my-time-admin-person"><span class="my-time-admin-person-name"><strong>${esc(item.full_name || 'Employee')}${self ? ' (You)' : ''}</strong>${item.classification ? `<small>${esc(item.classification)}</small>` : ''}${assigned ? '<small>Assigned</small>' : ''}</span>${persistent || editing ? '' : `<button type="button" class="secondary my-time-admin-remove" title="Remove ${esc(item.full_name || 'employee')}">Remove</button>`}</div>
        <div class="my-time-admin-clock">
          <label>Work Date<input class="my-time-admin-date" type="date" value="${esc(draft.workDate || todayIso())}"></label>
          <label>Start (24 hr)<input class="my-time-admin-start" type="text" inputmode="numeric" maxlength="5" placeholder="0600" value="${esc(draft.start || '')}"></label>
          <label>Stop (24 hr)<input class="my-time-admin-stop" type="text" inputmode="numeric" maxlength="5" placeholder="1630" value="${esc(draft.stop || '')}"></label>
          <label>Lunch (min)<input class="my-time-admin-lunch" type="number" min="0" max="720" step="1" value="${esc(draft.lunch ?? '0')}"></label>
        </div>
        <div class="my-time-admin-detail">
          <label>Charge To<select class="my-time-admin-charge"><option value="job" ${chargeType === 'job' ? 'selected' : ''}>Active Job</option><option value="overhead" ${chargeType === 'overhead' ? 'selected' : ''}>Overhead</option></select></label>
          <label class="my-time-admin-wide my-time-admin-job-wrap${chargeType === 'overhead' ? ' hidden' : ''}">Job<select class="my-time-admin-job">${adminJobOptions(draft.jobId || '')}</select></label>
          <label class="my-time-admin-wide my-time-admin-labor-wrap${chargeType === 'overhead' ? '' : ' hidden'}">Overhead Labor Code<select class="my-time-admin-labor">${overheadCodes.map((code) => `<option value="${esc(code)}" ${code === laborCode ? 'selected' : ''}>${esc(code)}</option>`).join('')}</select></label>
          <label>Equipment<input class="my-time-admin-equipment" type="text" placeholder="Optional unit / vehicle" value="${esc(draft.equipment || '')}" ${draft.equipmentNotUsed ? 'disabled' : ''}></label>
          <label class="my-time-admin-wide">Notes<input class="my-time-admin-notes" type="text" placeholder="Optional payroll note" value="${esc(draft.notes || '')}"></label>
        </div>
        <div class="my-time-admin-checks"><label><input class="my-time-admin-per-diem" type="checkbox" ${draft.perDiem ? 'checked' : ''}> Per diem</label><label><input class="my-time-admin-equipment-not-used" type="checkbox" ${draft.equipmentNotUsed ? 'checked' : ''}> Equipment not used</label></div>
        <div class="my-time-admin-actions"><button type="button" class="success my-time-admin-save">${editing ? 'Update' : 'Save'} ${esc(item.full_name || 'Employee')} Time</button>${editing ? '<button type="button" class="secondary my-time-admin-cancel">Cancel Edit</button>' : ''}<span class="my-time-admin-worked"><strong>—</strong>Worked hours</span><span class="my-time-admin-status">Regular and overtime calculate automatically.</span></div>
      </div>`;
    }).join('');

    box.querySelectorAll('[data-my-time-row]').forEach((row) => {
      row.querySelectorAll('.my-time-admin-start,.my-time-admin-stop').forEach((input) => {
        input.addEventListener('input', () => adminWorked(row));
        input.addEventListener('blur', () => { normalizeMilitaryInput(input); adminWorked(row); });
      });
      row.querySelector('.my-time-admin-lunch')?.addEventListener('input', () => adminWorked(row));
      row.querySelector('.my-time-admin-charge')?.addEventListener('change', () => toggleAdminCharge(row));
      row.querySelector('.my-time-admin-equipment-not-used')?.addEventListener('change', (event) => {
        const equipmentInput = row.querySelector('.my-time-admin-equipment');
        if (!equipmentInput) return;
        equipmentInput.disabled = event.target.checked;
        if (equipmentInput.disabled) equipmentInput.value = '';
      });
      row.querySelector('.my-time-admin-save')?.addEventListener('click', () => saveAdminRow(row));
      row.querySelector('.my-time-admin-cancel')?.addEventListener('click', resetForm);
      row.querySelector('.my-time-admin-remove')?.addEventListener('click', () => removeAdminPerson(row.dataset.myTimeRow));
      adminWorked(row);
    });
  }

  function removeAdminPerson(id) {
    if (!id) return;
    captureAdminRows();
    selectedEmployeeIds = selectedEmployeeIds.filter((employeeId) => employeeId !== id);
    personDrafts.delete(id);
    temporaryEmployeeIds.delete(id);
    renderAdminRows();
    renderPersonOptions();
  }

  function renderPeople() {
    const box = byId('myTimePersonList');
    if (!box) return;
    box.innerHTML = selectedEmployeeIds.map((id) => {
      const item = employees.find((candidate) => candidate.id === id) || (id === employee?.id ? employee : null) || {};
      const self = id === employee?.id;
      const assigned = role() === 'admin' && item.assigned_admin_id === profile()?.id;
      const persistent = self || assigned;
      return `<span class="my-time-person${id === activeEmployeeId ? ' active' : ''}"><button type="button" class="my-time-person-select" data-my-time-person="${esc(id)}">${esc(item.full_name || 'Employee')}${item.classification ? ` — ${esc(item.classification)}` : ''}${self ? ' (You)' : ''}</button>${assigned ? '<span class="my-time-person-badge">Assigned</span>' : ''}${persistent || editId ? '' : `<button type="button" class="my-time-remove-person" title="Remove ${esc(item.full_name || 'employee')}" data-my-time-remove-person="${esc(id)}">×</button>`}</span>`;
    }).join('');
    box.querySelectorAll('[data-my-time-person]').forEach((button) => {
      button.onclick = () => selectPerson(button.dataset.myTimePerson);
    });
    box.querySelectorAll('[data-my-time-remove-person]').forEach((button) => {
      button.onclick = () => {
        const removedId = button.dataset.myTimeRemovePerson;
        if (removedId === activeEmployeeId) captureCurrentDraft();
        selectedEmployeeIds = selectedEmployeeIds.filter((id) => id !== removedId);
        personDrafts.delete(removedId);
        temporaryEmployeeIds.delete(removedId);
        if (removedId === activeEmployeeId) {
          activeEmployeeId = employee?.id && selectedEmployeeIds.includes(employee.id) ? employee.id : selectedEmployeeIds[0] || null;
          if (activeEmployeeId) showDraft(activeEmployeeId);
        }
        renderPeople();
        renderPersonOptions();
      };
    });
    renderAdminRows();
  }

  function renderPersonOptions() {
    const select = byId('myTimePersonSelect');
    if (!select) return;
    const available = employees.filter((item) => item.active !== false && !selectedEmployeeIds.includes(item.id));
    select.innerHTML = '<option value="">Choose an active employee</option>' + available.map((item) =>
      `<option value="${esc(item.id)}">${esc(item.full_name || 'Employee')}${item.classification ? ' — ' + esc(item.classification) : ''}</option>`
    ).join('');
  }

  function addSelectedPerson() {
    if (!canAddOtherPeople() || editId) return;
    const id = byId('myTimePersonSelect')?.value || '';
    if (!id) return toast('Choose an employee to add.', 'warning');
    if (role() === 'admin') captureAdminRows();
    else captureCurrentDraft();
    if (!selectedEmployeeIds.includes(id)) selectedEmployeeIds.push(id);
    temporaryEmployeeIds.add(id);
    activeEmployeeId = id;
    if (!personDrafts.has(id)) personDrafts.set(id, emptyDraft());
    if (role() !== 'admin') showDraft(id);
    renderPeople();
    renderPersonOptions();
  }

  function toggleChargeFields() {
    const overhead = byId('myTimeChargeType')?.value === 'overhead';
    byId('myTimeJobWrap')?.classList.toggle('hidden', overhead);
    byId('myTimeLaborWrap')?.classList.toggle('hidden', !overhead);
  }

  function calculateWorked() {
    const start = militaryTime(byId('myTimeStart')?.value || '');
    const stop = militaryTime(byId('myTimeStop')?.value || '');
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
    if (role() === 'admin') captureAdminRows();
    const [employeeResult, jobsResult, employeesResult] = await Promise.all([
      client.from('timekeeping_employees')
        .select('id,full_name,classification,linked_profile_id,assigned_admin_id,active')
        .eq('company_id', current.company_id)
        .eq('linked_profile_id', current.id)
        .eq('active', true)
        .maybeSingle(),
      client.from('jobs')
        .select('id,job_number,job_name,active')
        .eq('company_id', current.company_id)
        .eq('active', true)
        .order('job_number'),
      canAddOtherPeople() ? client.from('timekeeping_employees')
        .select('id,full_name,classification,linked_profile_id,assigned_admin_id,active')
        .eq('company_id', current.company_id)
        .order('full_name') : Promise.resolve({data:[], error:null})
    ]);
    if (employeeResult.error) throw employeeResult.error;
    employee = employeeResult.data || null;
    if (employeesResult.error) throw employeesResult.error;
    employees = employeesResult.data || [];
    if (employee && !employees.some((item) => item.id === employee.id)) employees.unshift(employee);
    if (!editId) {
      selectedEmployeeIds = [...new Set([...assignedRosterIds(), ...temporaryEmployeeIds])];
      if (!activeEmployeeId || !selectedEmployeeIds.includes(activeEmployeeId)) {
        activeEmployeeId = employee?.id || selectedEmployeeIds[0] || null;
      }
      if (activeEmployeeId) showDraft(activeEmployeeId);
    }
    renderPeople();
    renderPersonOptions();
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
    renderAdminRows();
  }

  async function loadEntries() {
    const client = getSb();
    if (!client || (!employee?.id && !canAddOtherPeople())) {
      entries = [];
      renderHistory();
      return;
    }
    const since = new Date();
    since.setDate(since.getDate() - 90);
    const sinceIso = since.toISOString().slice(0,10);
    let query = client.from('timekeeping_entries')
      .select('id,employee_id,created_by,job_id,work_date,regular_hours,overtime_hours,start_time,stop_time,lunch_minutes,per_diem,equipment_used,equipment_not_used,notes,labor_code,entry_kind')
      .eq('entry_kind', 'leadership_self');
    if (canAddOtherPeople()) {
      const clauses = [`created_by.eq.${profile().id}`];
      if (employee?.id) clauses.unshift(`employee_id.eq.${employee.id}`);
      query = query.or(clauses.join(','));
    } else query = query.eq('employee_id', employee.id);
    const {data, error} = await query
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
    if (!employee && !canAddOtherPeople()) {
      box.innerHTML = '<p class="muted">Your payroll employee record is being prepared. Refresh after your profile is updated.</p>';
      return;
    }
    if (!entries.length) {
      box.innerHTML = '<p class="muted">No My Time entries in the last 90 days.</p>';
      return;
    }
    const jobMap = new Map(jobs.map((job) => [job.id, job]));
    box.innerHTML = '<div class="my-time-row my-time-header"><span>Date / Person</span><span>Charge</span><span>Start–Stop</span><span>Regular</span><span>OT</span><span></span></div>' + entries.map((entry) => {
      const job = jobMap.get(entry.job_id) || {};
      const charge = entry.job_id ? (job.job_number || 'Job') : (entry.labor_code || 'Overhead');
      return `<div class="my-time-row">
        <span>${esc(entry.work_date)}<br><small>${esc(employeeName(entry.employee_id))}</small></span>
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
    if (role() === 'admin') {
      captureAdminRows();
      editId = entry.id;
      if (!selectedEmployeeIds.includes(entry.employee_id)) selectedEmployeeIds.push(entry.employee_id);
      activeEmployeeId = entry.employee_id;
      personDrafts.set(entry.employee_id, {
        workDate: entry.work_date || todayIso(),
        start: timeText(entry.start_time),
        stop: timeText(entry.stop_time),
        lunch: String(num(entry.lunch_minutes)),
        chargeType: entry.job_id ? 'job' : 'overhead',
        jobId: entry.job_id || '',
        laborCode: overheadCodes.includes(entry.labor_code) ? entry.labor_code : 'Other',
        equipment: entry.equipment_used || '',
        notes: entry.notes || '',
        perDiem: !!entry.per_diem,
        equipmentNotUsed: !!entry.equipment_not_used
      });
      renderPeople();
      renderPersonOptions();
      byId('myTimeAdminRosterRows')?.querySelector(`[data-my-time-row="${CSS.escape(entry.employee_id)}"]`)?.scrollIntoView({behavior:'smooth', block:'center'});
      return;
    }
    editId = entry.id;
    selectedEmployeeIds = [entry.employee_id];
    activeEmployeeId = entry.employee_id;
    temporaryEmployeeIds.clear();
    personDrafts.clear();
    personDrafts.set(entry.employee_id, {
      workDate: entry.work_date || todayIso(),
      start: timeText(entry.start_time),
      stop: timeText(entry.stop_time),
      lunch: String(num(entry.lunch_minutes)),
      chargeType: entry.job_id ? 'job' : 'overhead',
      jobId: entry.job_id || '',
      laborCode: overheadCodes.includes(entry.labor_code) ? entry.labor_code : 'Other',
      equipment: entry.equipment_used || '',
      notes: entry.notes || '',
      perDiem: !!entry.per_diem,
      equipmentNotUsed: !!entry.equipment_not_used
    });
    showDraft(entry.employee_id);
    byId('myTimeCancelBtn').classList.remove('hidden');
    if (byId('myTimeAddPersonBtn')) byId('myTimeAddPersonBtn').disabled = true;
    if (byId('myTimePersonSelect')) byId('myTimePersonSelect').disabled = true;
    renderPeople();
    renderPersonOptions();
    byId('leadershipMyTimeCard')?.scrollIntoView({behavior:'smooth', block:'start'});
  }

  async function saveAdminRow(row) {
    const targetEmployeeId = row?.dataset.myTimeRow || '';
    if (role() !== 'admin' || !targetEmployeeId || !selectedEmployeeIds.includes(targetEmployeeId)) return;
    const startInput = row.querySelector('.my-time-admin-start');
    const stopInput = row.querySelector('.my-time-admin-stop');
    const startTime = normalizeMilitaryInput(startInput);
    const stopTime = normalizeMilitaryInput(stopInput);
    const worked = adminWorked(row);
    if (worked === null) return toast(`Enter a valid Start, Stop, and Lunch for ${employeeName(targetEmployeeId)}. Overnight shifts are supported.`, 'warning');
    const draft = adminRowDraft(row);
    const jobId = draft.chargeType === 'job' ? (draft.jobId || null) : null;
    const laborCode = draft.chargeType === 'overhead' ? (draft.laborCode || null) : null;
    if (draft.chargeType === 'job' && !jobId) return toast(`Choose the active job for ${employeeName(targetEmployeeId)}.`, 'warning');
    const editingEntry = editId ? entries.find((entry) => entry.id === editId && entry.employee_id === targetEmployeeId) : null;
    const button = row.querySelector('.my-time-admin-save');
    const status = row.querySelector('.my-time-admin-status');
    const done = window.LineCrewUI?.loadingButton?.(button, editingEntry ? 'Updating…' : 'Saving…') || (() => {});
    if (status) status.textContent = `Saving ${employeeName(targetEmployeeId)} and recalculating the company workweek…`;
    try {
      const common = {
        p_entry_id: editingEntry?.id || null,
        p_work_date: draft.workDate || null,
        p_start_time: startTime || null,
        p_stop_time: stopTime || null,
        p_lunch_minutes: Math.round(num(draft.lunch)),
        p_job_id: jobId,
        p_labor_code: laborCode,
        p_per_diem: !!draft.perDiem,
        p_equipment_used: String(draft.equipment || '').trim() || null,
        p_equipment_not_used: !!draft.equipmentNotUsed,
        p_notes: String(draft.notes || '').trim() || null
      };
      const result = targetEmployeeId === employee?.id
        ? await getSb().rpc('upsert_my_leadership_time', common)
        : await getSb().rpc('upsert_leadership_employee_time', {...common, p_employee_id: targetEmployeeId});
      if (result.error) throw result.error;
      captureAdminRows();
      personDrafts.set(targetEmployeeId, emptyDraft());
      editId = null;
      selectedEmployeeIds = [...new Set([...assignedRosterIds(), ...temporaryEmployeeIds])];
      toast(`${employeeName(targetEmployeeId)}'s time was ${editingEntry ? 'updated' : 'saved'}.`, 'success');
      renderPeople();
      renderPersonOptions();
      await loadEntries();
      await window.LineCrewTimekeepingReport?.run?.();
    } catch (error) {
      if (status) status.textContent = 'This row was not saved.';
      toast('Could not save time: ' + error.message, 'error');
    } finally {
      done();
    }
  }

  async function save() {
    if (!canEnterMyTime()) return toast('This role cannot submit My Time.', 'error');
    if (!employee?.id) return toast('Your payroll employee record is not ready yet. Refresh the page or ask an Admin to update your profile.', 'error');
    const targetEmployeeId = activeEmployeeId;
    if (!targetEmployeeId || !selectedEmployeeIds.includes(targetEmployeeId)) return toast('Choose the person whose time you want to save.', 'warning');
    if (targetEmployeeId !== employee.id && !canAddOtherPeople()) return toast('Only Admin and General Foreman can add another employee.', 'error');
    const startTime = normalizeMilitaryInput(byId('myTimeStart'));
    const stopTime = normalizeMilitaryInput(byId('myTimeStop'));
    const worked = calculateWorked();
    if (worked === null) return toast('Enter a valid Start, Stop, and Lunch. Overnight shifts are supported.', 'warning');
    const chargeType = byId('myTimeChargeType')?.value || 'job';
    const jobId = chargeType === 'job' ? (byId('myTimeJob')?.value || null) : null;
    const laborCode = chargeType === 'overhead' ? (byId('myTimeLabor')?.value || null) : null;
    if (chargeType === 'job' && !jobId) return toast('Choose the active job this time belongs to.', 'warning');
    const lunch = Math.round(num(byId('myTimeLunch')?.value));
    const button = byId('myTimeSaveBtn');
    const wasEditing = !!editId;
    const done = window.LineCrewUI?.loadingButton?.(button, wasEditing ? 'Updating…' : 'Saving…') || (() => {});
    const status = byId('myTimeStatus');
    if (status) status.textContent = `Saving ${employeeName(targetEmployeeId)} and recalculating the company workweek…`;
    try {
      const common = {
        p_entry_id: editId,
        p_work_date: byId('myTimeDate')?.value || null,
        p_start_time: startTime || null,
        p_stop_time: stopTime || null,
        p_lunch_minutes: lunch,
        p_job_id: jobId,
        p_labor_code: laborCode,
        p_per_diem: !!byId('myTimePerDiem')?.checked,
        p_equipment_used: (byId('myTimeEquipment')?.value || '').trim() || null,
        p_equipment_not_used: !!byId('myTimeEquipmentNotUsed')?.checked,
        p_notes: (byId('myTimeNotes')?.value || '').trim() || null
      };
      const result = targetEmployeeId === employee.id
        ? await getSb().rpc('upsert_my_leadership_time', common)
        : await getSb().rpc('upsert_leadership_employee_time', {...common, p_employee_id: targetEmployeeId});
      if (result.error) throw result.error;
      toast(`${employeeName(targetEmployeeId)}'s time was ${wasEditing ? 'updated' : 'saved'}.`, 'success');
      if (status) status.textContent = 'Saved. Regular and overtime now reflect the company workweek.';
      resetForm();
      await loadEntries();
      await window.LineCrewTimekeepingReport?.run?.();
    } catch (error) {
      if (status) status.textContent = 'Your entry was not saved.';
      toast('Could not save time: ' + error.message, 'error');
    } finally {
      done();
      updateActivePersonLabel();
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
