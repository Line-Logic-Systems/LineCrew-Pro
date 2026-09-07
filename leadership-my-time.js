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
            <p class="muted">Enter each person's hours, then save everyone at once. Admin roster members appear automatically.</p>
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
          <div id="myTimeBatchActions" class="my-time-actions hidden">
            <button id="myTimeSaveAllBtn" type="button" class="success">Save All Time</button>
            <span id="myTimeBatchStatus" class="my-time-status">Only rows with entered times will be saved.</span>
          </div>
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
    byId('myTimeSingleEntry')?.classList.toggle('hidden', canAddOtherPeople());
    byId('myTimePersonList')?.classList.toggle('hidden', canAddOtherPeople());
    byId('myTimeAdminRosterRows')?.classList.toggle('hidden', !canAddOtherPeople());
    byId('myTimeBatchActions')?.classList.toggle('hidden', !canAddOtherPeople());
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
    byId('myTimeSaveAllBtn').onclick = saveAllRows;
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
    byId('myTimeStart').value = draft.