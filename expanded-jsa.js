/* LineCrew Pro - Expanded Digital JSA
   Structured powerline pre-job briefing form. Keeps the existing company-upload JSA option intact.
*/
(() => {
  'use strict';

  const byId = (id) => document.getElementById(id);
  const esc = (value) => String(value ?? '').replace(/[&<>'"]/g, (ch) => ({'&':'&amp;','<':'&lt;','>':'&gt;',"'":'&#39;','"':'&quot;'}[ch]));
  const value = (id) => (byId(id)?.value || '').trim();
  const checked = (name) => [...document.querySelectorAll(`[name="${name}"]:checked`)].map((el) => el.value);
  const yn = (id) => value(id);

  // Simple subscriber help entry point. No training completion dashboard or manager tracking.
  function addTrainingTile(){
    const dashboard = byId('dashboardPage');
    if(!dashboard || byId('trainingTile')) return;
    const grid = dashboard.querySelector('.grid');
    if(!grid) return;
    const tile = document.createElement('div');
    tile.className = 'metric';
    tile.id = 'trainingTile';
    tile.setAttribute('role','link');
    tile.setAttribute('tabindex','0');
    tile.innerHTML = '<strong>Training</strong><span class="muted">How-to videos for your LineCrew Pro role</span>';
    const openTraining = () => { window.location.href = '/training/'; };
    tile.addEventListener('click', openTraining);
    tile.addEventListener('keydown', (event) => {
      if(event.key === 'Enter' || event.key === ' '){
        event.preventDefault();
        openTraining();
      }
    });
    grid.appendChild(tile);
  }
  if(document.readyState === 'loading') document.addEventListener('DOMContentLoaded', addTrainingTile);
  else addTrainingTile();

  const form = byId('safetyJsaForm');
  if (!form) return;

  const style = document.createElement('style');
  style.textContent = `
    .lc-jsa-progress{display:flex;gap:6px;overflow-x:auto;padding:4px 0 12px;scrollbar-width:thin}
    .lc-jsa-progress span{white-space:nowrap;padding:7px 10px;border-radius:999px;background:#edf3f8;color:#456;font-size:12px;font-weight:800}
    .lc-jsa-card{border:1px solid #d9e3ec;border-radius:16px;background:#fff;padding:16px;margin:0 0 14px;box-shadow:0 2px 8px rgba(20,45,70,.05)}
    .lc-jsa-card h3{margin:0 0 4px;color:#0b2d4d;font-size:18px}
    .lc-jsa-card .lc-help{margin:0 0 12px;color:#667788;font-size:13px}
    .lc-jsa-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px 12px}
    .lc-jsa-grid.three{grid-template-columns:repeat(3,minmax(0,1fr))}
    .lc-jsa-grid label,.lc-jsa-card>label{display:block;font-weight:700;font-size:13px;color:#283a4b}
    .lc-jsa-grid input,.lc-jsa-grid select,.lc-jsa-card input,.lc-jsa-card select,.lc-jsa-card textarea{width:100%;margin-top:5px}
    .lc-jsa-checks{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:8px}
    .lc-jsa-check{display:flex;align-items:center;gap:8px;border:1px solid #dbe5ee;border-radius:11px;padding:10px;background:#fbfdff;font-weight:650;font-size:13px}
    .lc-jsa-check input{width:auto;margin:0;transform:scale(1.15)}
    .lc-jsa-yn{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px 12px}
    .lc-jsa-task{border:1px solid #dce5ed;border-radius:12px;padding:12px;margin:9px 0;background:#f9fbfd}
    .lc-jsa-task-head{display:flex;align-items:center;justify-content:space-between;gap:8px;margin-bottom:8px;font-weight:800;color:#0b2d4d}
    .lc-jsa-task textarea{min-height:76px}
    .lc-jsa-remove{border:0;background:#fce8e8;color:#9e2929;border-radius:8px;padding:7px 9px;font-weight:800;cursor:pointer}
    .lc-jsa-add{border:1px dashed #1677d2;background:#f2f8fe;color:#0b5fa8;border-radius:10px;padding:10px 12px;font-weight:800;cursor:pointer;width:100%}
    .lc-stop{border-left:5px solid #d97706;background:#fff8ed;padding:12px 14px;border-radius:10px;margin-bottom:12px;font-weight:700;color:#5d3a08}
    .lc-crew-row{display:grid;grid-template-columns:1fr 1fr;gap:10px;margin:8px 0}
    .lc-jsa-actions{position:sticky;bottom:0;background:linear-gradient(transparent,#fff 22%);padding:26px 0 4px;z-index:4}
    .lc-jsa-hidden-legacy{display:none!important}
    @media(max-width:720px){
      .lc-jsa-grid,.lc-jsa-grid.three,.lc-jsa-checks,.lc-jsa-yn{grid-template-columns:1fr}
      .lc-crew-row{grid-template-columns:1fr}
      .lc-jsa-card{padding:13px}
    }
  `;
  document.head.appendChild(style);

  const yesNo = (id, label, allowNa = true) => `
    <label>${label}
      <select id="${id}">
        <option value="">Select</option>
        <option value="Yes">Yes</option>
        <option value="No">No</option>
        ${allowNa ? '<option value="N/A">N/A</option>' : ''}
      </select>
    </label>`;

  const checkItems = (name, items) => items.map((item) => `
    <label class="lc-jsa-check"><input type="checkbox" name="${name}" value="${esc(item)}"> ${esc(item)}</label>`).join('');

  const ppeItems = [
    'Eye/Face Protection','FR Clothing','Hand and Foot Protection','Chainsaw Chaps',
    'Fall Protection Inspection','Head Protection','Rubber Gloves and Sleeves','High Viz'
  ];
  const energyItems = ['Temperature','Gravity','Motion','Mechanical','Pressure','Electrical','Sound','Radiation','Biological','Chemical'];
  const humanItems = [
    'Time Pressure','Distractions and Interruptions','Multi-tasking','Over confidence or Complacency',
    'Vague or Interpretive Guidance','Fatigue','First or Last Shift','Peer Pressure',
    'Change from Normal Operations','Physical Environment Issues','Mental Stress'
  ];

  form.innerHTML = `
    <div class="lc-jsa-progress" aria-label="JSA sections">
      <span>Job</span><span>System</span><span>Emergency</span><span>Storm/Energy</span><span>PPE</span><span>Transformer</span><span>Hazards</span><span>Tasks</span><span>Sign-Off</span>
    </div>

    <div class="lc-jsa-card">
      <h3>1. Job Information</h3>
      <p class="lc-help">Pre-job briefing identification, job location, and JSA leadership.</p>
      <div class="lc-jsa-grid three">
        <label>Date *<input id="safetyJsaDate" type="date"></label>
        <label>Time *<input id="safetyJsaTime" type="time"></label>
        <label>Foreman<input id="safetyJsaForeman" type="text" readonly></label>
        <label>JSA Leader *<input id="safetyJsaLeader" type="text" placeholder="JSA leader / person in charge"></label>
        <label>Job # or Work Order # *<select id="safetyJsaJob"><option value="">Select an active job</option></select></label>
        <label>Customer<input id="safetyJsaCustomer" type="text" placeholder="Customer / utility"></label>
      </div>
      <div class="lc-jsa-grid">
        <label>Crew / Crew Name *<input id="safetyJsaCrew" type="text" placeholder="Crew name or number"></label>
        <label>Weather / Conditions<input id="safetyJsaWeather" type="text" placeholder="Optional"></label>
      </div>
      <label>Nearest Physical Address, Cross Street, or GPS Location<input id="safetyJsaLocation" type="text" placeholder="Address, cross street, coordinates, or GPS description"></label>
    </div>

    <div class="lc-jsa-card">
      <h3>2. Substation, Circuit, Pole & Dispatch</h3>
      <div class="lc-jsa-grid three">
        <label>Substation<input id="jsaSubstation" type="text"></label>
        <label>Circuit<input id="jsaCircuit" type="text"></label>
        <label>Voltage<input id="jsaVoltage" type="text"></label>
        ${yesNo('jsaLocateYn','Locate — Y or N')}
        <label>811 Locate #<input id="jsa811Locate" type="text"></label>
        <label>Pole #<input id="jsaPoleNumber" type="text"></label>
        <label>OCR / LR #<input id="jsaOcrLr" type="text"></label>
        <label>Nearest Meter<input id="jsaNearestMeter" type="text"></label>
        <label>Dispatch #<input id="jsaDispatchNumber" type="text"></label>
        <label>After Hours #<input id="jsaAfterHoursNumber" type="text"></label>
      </div>
      <h3 style="margin-top:16px">Switching / Clearance / Hold Card</h3>
      <div class="lc-jsa-grid three">
        <label>Hold Card #<input id="jsaHoldCard" type="text"></label>
        <label>Switching Order #<input id="jsaSwitchingOrder" type="text"></label>
        ${yesNo('jsaNonReclosing','Non-Reclosing / Clearance Issued — Y or N')}
        <label>Time Issued<input id="jsaTimeIssued" type="time"></label>
        <label>Returned<input id="jsaReturned" type="text" placeholder="Time, date, or status"></label>
        <label>Clearance #<input id="jsaClearanceNumber" type="text"></label>
      </div>
      <h3 style="margin-top:16px">Designated Safety / Rescue Roles</h3>
      <div class="lc-jsa-grid">
        <label>Designated Qualified Observer (QO)<input id="jsaQualifiedObserver" type="text"></label>
        <label>Designated H2O Monitor<input id="jsaH2oMonitor" type="text"></label>
        <label>Designated Pole Top Rescue<input id="jsaPoleTopRescue" type="text"></label>
        <label>Designated Bucket Rescue<input id="jsaBucketRescue" type="text"></label>
      </div>
    </div>

    <div class="lc-jsa-card">
      <h3>3. Emergency Information</h3>
      <div class="lc-jsa-grid">
        <label>Local Emergency #<input id="jsaLocalEmergency" type="text" placeholder="911 or local number"></label>
        <label>Medical Facility #<input id="jsaMedicalFacilityNumber" type="text"></label>
        <label>Nearest Medical Facility Name<input id="jsaMedicalFacilityName" type="text"></label>
        <label>Address<input id="jsaMedicalFacilityAddress" type="text"></label>
      </div>
      <label>Emergency Meeting Point<input id="jsaEmergencyMeetingPoint" type="text"></label>
    </div>

    <div class="lc-jsa-card">
      <h3>4. Storm Restoration Work & Energy Source Control</h3>
      <div class="lc-jsa-yn">
        ${yesNo('jsaStormWork','Storm Work — Y or N')}
        ${yesNo('jsaBackfeedPotential','Back Feed Potential — Y or N')}
        ${yesNo('jsaGrounds','Grounds — Y or N')}
        ${yesNo('jsaAdjacentStructures','Adjacent Structures Inspected — Y or N')}
        ${yesNo('jsaDispatchNotified','Dispatch Notified — Y or N')}
        ${yesNo('jsaVoltageTest','Voltage Test — Y or N')}
        ${yesNo('jsaLockoutTagout','Lockout / Tagout — Y or N')}
      </div>
    </div>

    <div class="lc-jsa-card">
      <h3>5. Personal Protection Equipment (PPE)</h3>
      <p class="lc-help">Check all that apply.</p>
      <div class="lc-jsa-checks">${checkItems('jsaPpeItem', ppeItems)}</div>
      <div style="margin-top:12px">${yesNo('jsaRubberGloveFieldTest','Pre-use field tests performed on all rubber gloves being utilized? — Y or N')}</div>
    </div>

    <div class="lc-jsa-card">
      <h3>6. Transformers — Checklist</h3>
      <div class="lc-jsa-grid three">
        ${yesNo('jsaTransformerNameplate','Check Name Plate')}
        <label>Primary Voltage<input id="jsaTransformerPrimaryVoltage" type="text"></label>
        <label>Secondary Voltage<input id="jsaTransformerSecondaryVoltage" type="text"></label>
        ${yesNo('jsaTransformerImpedance','Impedance / Polarity')}
        ${yesNo('jsaCustomerBreakerOff','Turn Customer Breaker Off')}
        <label>Reading from Old Transformer<input id="jsaOldTransformerReading" type="text"></label>
        ${yesNo('jsaPreCheckRotation','Pre-Check Rotation')}
        ${yesNo('jsaPostCheckRotation','Post Check Rotation')}
        <label>New Transformer Voltage Reading<input id="jsaNewTransformerReading" type="text"></label>
        <label>Rotation<input id="jsaTransformerRotation" type="text"></label>
        ${yesNo('jsaClockwise','Clockwise — Y or N')}
        ${yesNo('jsaCounterclockwise','Counterclockwise — Y or N')}
      </div>
      <div class="lc-stop" style="margin-top:12px">DO NOT ENERGIZE unless positive checks indicate voltage and rotation are correct at the customer's breaker.</div>
    </div>

    <div class="lc-jsa-card">
      <h3>7. Energy Sources</h3>
      <p class="lc-help">Use the energy-source review to identify hazards. Check all that apply.</p>
      <div class="lc-jsa-checks">${checkItems('jsaEnergySource', energyItems)}</div>
      <h3 style="margin-top:18px">Human Performance — 11 Common Human Error Traps</h3>
      <p class="lc-help">Identify human-performance traps present today and address them in the mitigation plan.</p>
      <div class="lc-jsa-checks">${checkItems('jsaHumanTrap', humanItems)}</div>
    </div>

    <div class="lc-jsa-card">
      <h3>8. Job Tasks, Hazards & Mitigation</h3>
      <div class="lc-stop">Stop Work Authority — All employees have the right and responsibility to stop a job due to an unsafe act or condition. Ask questions if you are unsure of your role or how to perform your role safely.</div>
      <div id="jsaTaskRows"></div>
      <button id="addJsaTaskRow" type="button" class="lc-jsa-add">+ Add Job Task / Hazard Row</button>
    </div>

    <div class="lc-jsa-card">
      <h3>9. Crew Acknowledgment</h3>
      <p class="lc-help">Each crew member confirms they understand the job tasks, hazards, mitigation plan, roles/responsibilities, and required PPE.</p>
      <div id="jsaCrewRows"></div>
    </div>

    <div class="lc-jsa-card">
      <h3>10. JSA Leader / Person in Charge Sign-Off</h3>
      <p class="lc-help">I verify that my crew has been given the above information and has indicated an understanding of the job tasks, hazards, mitigation plan, roles/responsibilities, and proper PPE for the tasks.</p>
      <div class="lc-jsa-grid">
        <label>JSA Leader / Person in Charge Name *<input id="jsaPersonInChargeName" type="text"></label>
        <label>Signature *<input id="jsaPersonInChargeSignature" type="text" placeholder="Type full name as signature"></label>
        <label>Date<input id="jsaSignoffDate" type="date"></label>
        <label>Time<input id="jsaSignoffTime" type="time"></label>
      </div>
    </div>

    <div class="lc-jsa-card">
      <h3>Additional Information</h3>
      <label>Special Equipment / Additional Notes<textarea id="safetyJsaEquipment" rows="3" placeholder="Optional"></textarea></label>
      <label class="checkbox-row" style="margin-top:12px"><input id="safetyJsaAcknowledged" type="checkbox"> I certify that this pre-job briefing has been completed and discussed with the crew.</label>
    </div>

    <div class="lc-jsa-hidden-legacy" aria-hidden="true">
      <textarea id="safetyJsaBriefing"></textarea>
      <textarea id="safetyJsaHazards"></textarea>
      <textarea id="safetyJsaControls"></textarea>
      <textarea id="safetyJsaPpe"></textarea>
      <textarea id="safetyJsaEmergency"></textarea>
    </div>

    <div class="lc-jsa-actions">
      <div class="button-row">
        <button id="saveSafetyJsaBtn" type="button">Save JSA</button>
        <button id="cancelSafetyJsaBtn" class="button secondary" type="button">Cancel</button>
      </div>
      <div id="safetyJsaMsg" class="message"></div>
    </div>
  `;

  let taskCounter = 0;
  const taskRows = byId('jsaTaskRows');
  function addTaskRow(seed = {}) {
    taskCounter += 1;
    const row = document.createElement('div');
    row.className = 'lc-jsa-task';
    row.dataset.row = String(taskCounter);
    row.innerHTML = `
      <div class="lc-jsa-task-head"><span>Task / Hazard Row ${taskCounter}</span><button type="button" class="lc-jsa-remove">Remove</button></div>
      <div class="lc-jsa-grid three">
        <label>Job Task<textarea class="jsa-task-name" placeholder="Work step or task">${esc(seed.job_task || '')}</textarea></label>
        <label>Hazards<textarea class="jsa-task-hazards" placeholder="Hazards for this task">${esc(seed.hazards || '')}</textarea></label>
        <label>Work Procedure / Mitigation Plan / Special Precautions<textarea class="jsa-task-mitigation" placeholder="How the hazard will be controlled">${esc(seed.mitigation || '')}</textarea></label>
      </div>`;
    row.querySelector('.lc-jsa-remove').onclick = () => {
      if (taskRows.children.length <= 1) {
        row.querySelectorAll('textarea').forEach((el) => { el.value = ''; });
        return;
      }
      row.remove();
    };
    taskRows.appendChild(row);
  }
  byId('addJsaTaskRow').onclick = () => addTaskRow();

  const crewRows = byId('jsaCrewRows');
  function buildCrewRows() {
    crewRows.innerHTML = '';
    for (let i = 1; i <= 10; i += 1) {
      const row = document.createElement('div');
      row.className = 'lc-crew-row';
      row.innerHTML = `
        <label>Printed Name ${i}${i === 1 ? ' *' : ''}<input class="jsa-printed-name-input" data-index="${i}" type="text" placeholder="Crew member name"></label>
        <label>Signature ${i}${i === 1 ? ' *' : ''}<input class="jsa-signature-input" data-index="${i}" type="text" placeholder="Type full name as signature"></label>`;
      crewRows.appendChild(row);
    }
  }

  function setNowFields() {
    const now = new Date();
    const localDate = `${now.getFullYear()}-${String(now.getMonth()+1).padStart(2,'0')}-${String(now.getDate()).padStart(2,'0')}`;
    const localTime = `${String(now.getHours()).padStart(2,'0')}:${String(now.getMinutes()).padStart(2,'0')}`;
    if (byId('safetyJsaTime') && !byId('safetyJsaTime').value) byId('safetyJsaTime').value = localTime;
    if (byId('jsaSignoffDate') && !byId('jsaSignoffDate').value) byId('jsaSignoffDate').value = byId('safetyJsaDate')?.value || localDate;
    if (byId('jsaSignoffTime') && !byId('jsaSignoffTime').value) byId('jsaSignoffTime').value = localTime;
    if (byId('jsaPersonInChargeName') && !byId('jsaPersonInChargeName').value) byId('jsaPersonInChargeName').value = byId('safetyJsaLeader')?.value || byId('safetyJsaForeman')?.value || '';
  }

  function resetExpandedJsa() {
    form.querySelectorAll('input:not([readonly]), textarea').forEach((el) => {
      if (el.type === 'checkbox') el.checked = false;
      else el.value = '';
    });
    form.querySelectorAll('select').forEach((el) => {
      if (el.id !== 'safetyJsaJob') el.value = '';
    });
    taskRows.innerHTML = '';
    taskCounter = 0;
    addTaskRow();
    addTaskRow();
    addTaskRow();
    buildCrewRows();
    setNowFields();
  }

  function collectTasks() {
    return [...taskRows.querySelectorAll('.lc-jsa-task')].map((row) => ({
      job_task: row.querySelector('.jsa-task-name')?.value.trim() || '',
      hazards: row.querySelector('.jsa-task-hazards')?.value.trim() || '',
      mitigation: row.querySelector('.jsa-task-mitigation')?.value.trim() || ''
    })).filter((row) => row.job_task || row.hazards || row.mitigation);
  }

  function collectCrew() {
    const names = [...document.querySelectorAll('.jsa-printed-name-input')];
    const sigs = [...document.querySelectorAll('.jsa-signature-input')];
    return names.map((nameEl, idx) => ({
      printed_name: nameEl.value.trim(),
      signature: sigs[idx]?.value.trim() || ''
    })).filter((row) => row.printed_name || row.signature);
  }

  function detailsPayload() {
    return {
      form_version: 2,
      briefing: {
        time: value('safetyJsaTime'),
        foreman: value('safetyJsaForeman'),
        jsa_leader: value('safetyJsaLeader'),
        customer: value('safetyJsaCustomer'),
        nearest_physical_address_cross_street_or_gps: value('safetyJsaLocation')
      },
      system: {
        substation: value('jsaSubstation'), circuit: value('jsaCircuit'), voltage: value('jsaVoltage'),
        locate_yn: yn('jsaLocateYn'), locate_811_number: value('jsa811Locate'), pole_number: value('jsaPoleNumber'),
        ocr_lr_number: value('jsaOcrLr'), nearest_meter: value('jsaNearestMeter'), dispatch_number: value('jsaDispatchNumber'),
        after_hours_number: value('jsaAfterHoursNumber'), hold_card_number: value('jsaHoldCard'), switching_order_number: value('jsaSwitchingOrder'),
        non_reclosing_clearance_issued: yn('jsaNonReclosing'), time_issued: value('jsaTimeIssued'), returned: value('jsaReturned'),
        clearance_number: value('jsaClearanceNumber'), designated_qualified_observer: value('jsaQualifiedObserver'),
        designated_h2o_monitor: value('jsaH2oMonitor'), designated_pole_top_rescue: value('jsaPoleTopRescue'),
        designated_bucket_rescue: value('jsaBucketRescue')
      },
      emergency: {
        local_emergency_number: value('jsaLocalEmergency'), medical_facility_number: value('jsaMedicalFacilityNumber'),
        nearest_medical_facility_name: value('jsaMedicalFacilityName'), medical_facility_address: value('jsaMedicalFacilityAddress'),
        emergency_meeting_point: value('jsaEmergencyMeetingPoint')
      },
      storm_energy_control: {
        storm_work: yn('jsaStormWork'), back_feed_potential: yn('jsaBackfeedPotential'), grounds: yn('jsaGrounds'),
        adjacent_structures_inspected: yn('jsaAdjacentStructures'), dispatch_notified: yn('jsaDispatchNotified'),
        voltage_test: yn('jsaVoltageTest'), lockout_tagout: yn('jsaLockoutTagout')
      },
      ppe: { selected: checked('jsaPpeItem'), rubber_glove_preuse_field_test: yn('jsaRubberGloveFieldTest') },
      transformer: {
        check_name_plate: yn('jsaTransformerNameplate'), primary_voltage: value('jsaTransformerPrimaryVoltage'),
        secondary_voltage: value('jsaTransformerSecondaryVoltage'), impedance_polarity: yn('jsaTransformerImpedance'),
        customer_breaker_off: yn('jsaCustomerBreakerOff'), reading_from_old_transformer: value('jsaOldTransformerReading'),
        pre_check_rotation: yn('jsaPreCheckRotation'), post_check_rotation: yn('jsaPostCheckRotation'),
        new_transformer_voltage_reading: value('jsaNewTransformerReading'), rotation: value('jsaTransformerRotation'),
        clockwise: yn('jsaClockwise'), counterclockwise: yn('jsaCounterclockwise')
      },
      energy_sources: checked('jsaEnergySource'),
      human_performance_traps: checked('jsaHumanTrap'),
      tasks: collectTasks(),
      crew_acknowledgments: collectCrew(),
      signoff: {
        person_in_charge_name: value('jsaPersonInChargeName'), signature: value('jsaPersonInChargeSignature'),
        date: value('jsaSignoffDate'), time: value('jsaSignoffTime')
      },
      stop_work_authority_acknowledged: true
    };
  }

  async function saveExpandedJsa() {
    const msg = byId('safetyJsaMsg');
    const btn = byId('saveSafetyJsaBtn');
    if (msg) { msg.textContent = ''; msg.className = 'message'; }

    const tasks = collectTasks();
    const crew = collectCrew();
    const ppeSelected = checked('jsaPpeItem');
    const leader = value('safetyJsaLeader');
    const picName = value('jsaPersonInChargeName');
    const picSignature = value('jsaPersonInChargeSignature');

    if (!value('safetyJsaJob') || !value('safetyJsaDate') || !value('safetyJsaTime') || !value('safetyJsaCrew') || !leader) {
      if (msg) msg.textContent = 'Complete Job, Date, Time, Crew, and JSA Leader.';
      return;
    }
    if (!tasks.length || !tasks.some((row) => row.job_task && row.hazards && row.mitigation)) {
      if (msg) msg.textContent = 'Complete at least one Job Task / Hazards / Mitigation row.';
      return;
    }
    if (!crew.length || !crew.some((row) => row.printed_name && row.signature)) {
      if (msg) msg.textContent = 'Enter at least one crew member printed name and signature.';
      return;
    }
    if (!picName || !picSignature) {
      if (msg) msg.textContent = 'Complete the JSA Leader / Person in Charge name and signature.';
      return;
    }
    if (!byId('safetyJsaAcknowledged')?.checked) {
      if (msg) msg.textContent = 'Check the final JSA certification before saving.';
      return;
    }

    const jobBriefing = tasks.map((row, i) => `${i+1}. ${row.job_task}`).join('\n') || 'See expanded JSA details.';
    const hazards = tasks.map((row, i) => `${i+1}. ${row.hazards}`).join('\n') || 'See expanded JSA details.';
    const controls = tasks.map((row, i) => `${i+1}. ${row.mitigation}`).join('\n') || 'See expanded JSA details.';
    const ppe = ppeSelected.length ? ppeSelected.join(', ') : 'See expanded JSA details.';
    const emergency = [
      value('jsaLocalEmergency') && `Local Emergency: ${value('jsaLocalEmergency')}`,
      value('jsaMedicalFacilityName') && `Medical Facility: ${value('jsaMedicalFacilityName')}`,
      value('jsaMedicalFacilityAddress') && `Address: ${value('jsaMedicalFacilityAddress')}`,
      value('jsaEmergencyMeetingPoint') && `Meeting Point: ${value('jsaEmergencyMeetingPoint')}`
    ].filter(Boolean).join(' | ') || 'See expanded JSA details.';
    const crewText = crew.map((row) => `${row.printed_name}${row.signature ? ` | Signature: ${row.signature}` : ''}`).join('\n');

    btn.disabled = true;
    btn.textContent = 'Saving...';
    try {
      const { data, error } = await sb.rpc('create_standalone_jsa_v2', {
        p_job_id: value('safetyJsaJob'),
        p_work_date: value('safetyJsaDate'),
        p_crew_name: value('safetyJsaCrew'),
        p_job_briefing: jobBriefing,
        p_hazards: hazards,
        p_controls: controls,
        p_ppe: ppe,
        p_emergency_plan: emergency,
        p_crew_members: crewText,
        p_weather_conditions: value('safetyJsaWeather') || null,
        p_special_equipment: value('safetyJsaEquipment') || null,
        p_foreman_acknowledged: true,
        p_details: detailsPayload()
      });
      if (error) throw error;
      if (msg) { msg.textContent = 'JSA saved successfully.'; msg.className = 'message success'; }
      if (typeof window.showToast === 'function') window.showToast('JSA saved successfully.');
      setTimeout(async () => {
        form.classList.add('hidden');
        if (byId('createJsaBtn')) byId('createJsaBtn').classList.remove('hidden');
        if (typeof window.loadSafetyJsas === 'function') await window.loadSafetyJsas();
      }, 500);
      return data;
    } catch (error) {
      console.error('Expanded JSA save failed', error);
      if (msg) msg.textContent = error?.message || 'Unable to save JSA.';
    } finally {
      btn.disabled = false;
      btn.textContent = 'Save JSA';
    }
  }

  const originalCreate = byId('createJsaBtn')?.onclick;
  if (byId('createJsaBtn')) {
    byId('createJsaBtn').onclick = async function(event) {
      if (originalCreate) await originalCreate.call(this, event);
      resetExpandedJsa();
      if (byId('safetyJsaForeman')) byId('safetyJsaForeman').value = (typeof currentProfile !== 'undefined' && currentProfile?.full_name) ? currentProfile.full_name : 'Foreman';
      if (byId('safetyJsaDate') && !byId('safetyJsaDate').value) {
        const d = new Date();
        byId('safetyJsaDate').value = `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;
      }
      setNowFields();
    };
  }

  byId('safetyJsaLeader')?.addEventListener('change', () => {
    if (!value('jsaPersonInChargeName')) byId('jsaPersonInChargeName').value = value('safetyJsaLeader');
  });
  byId('safetyJsaDate')?.addEventListener('change', () => {
    if (byId('jsaSignoffDate')) byId('jsaSignoffDate').value = value('safetyJsaDate');
  });
  byId('saveSafetyJsaBtn').onclick = saveExpandedJsa;
  byId('cancelSafetyJsaBtn').onclick = () => {
    form.classList.add('hidden');
    byId('createJsaBtn')?.classList.remove('hidden');
    const msg = byId('safetyJsaMsg');
    if (msg) msg.textContent = '';
  };

  // Initial structure exists even before the first Create JSA click.
  taskRows.innerHTML = '';
  addTaskRow(); addTaskRow(); addTaskRow();
  buildCrewRows();
  setNowFields();

  window.LineCrewExpandedJsa = { collectTasks, collectCrew, detailsPayload, resetExpandedJsa, saveExpandedJsa };
})();