/* LineCrew Pro - full read-only JSA review and print layout */
(() => {
  'use strict';

  const byId = (id) => document.getElementById(id);
  const esc = (value) => String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;');

  function addStyles() {
    if (byId('linecrewFullJsaReviewStyles')) return;
    const style = document.createElement('style');
    style.id = 'linecrewFullJsaReviewStyles';
    style.textContent = `
      .lc-jsa-review{display:grid;gap:14px;margin-top:12px;color:#102235}
      .lc-jsa-review-head{display:flex;justify-content:space-between;gap:14px;flex-wrap:wrap;padding:14px;border:1px solid #cddae5;border-radius:14px;background:#f7fafc}
      .lc-jsa-review-head h2{margin:0 0 4px;font-size:20px}.lc-jsa-review-head p{margin:0;color:#5f7183}
      .lc-jsa-review-section{border:1px solid #dce5ed;border-radius:14px;padding:14px;background:#fff;break-inside:avoid}
      .lc-jsa-review-section h3{margin:0 0 12px;color:#0b2d4d;font-size:17px}
      .lc-jsa-review-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px}
      .lc-jsa-review-grid.three{grid-template-columns:repeat(3,minmax(0,1fr))}
      .lc-jsa-review-field{border:1px solid #e1e8ee;border-radius:10px;padding:9px 10px;min-width:0;background:#fbfdff}
      .lc-jsa-review-label{display:block;color:#617386;font-size:12px;font-weight:800;margin-bottom:4px}
      .lc-jsa-review-value{white-space:pre-wrap;overflow-wrap:anywhere;font-weight:650}
      .lc-jsa-review-pills{display:flex;gap:7px;flex-wrap:wrap}.lc-jsa-review-pill{display:inline-block;padding:6px 9px;border-radius:999px;background:#e9f2fa;color:#0b4b78;font-weight:750;font-size:12px}
      .lc-jsa-review-table{width:100%;border-collapse:collapse}.lc-jsa-review-table th,.lc-jsa-review-table td{border:1px solid #dce5ed;padding:9px;vertical-align:top;text-align:left;white-space:pre-wrap}.lc-jsa-review-table th{background:#eef4f8;color:#34516a}
      .lc-jsa-review-signatures{display:grid;gap:10px}.lc-jsa-review-signature{display:grid;grid-template-columns:minmax(160px,1fr) minmax(220px,1.5fr);gap:10px;align-items:center;border:1px solid #dce5ed;border-radius:12px;padding:10px;background:#fbfdff}
      .lc-jsa-review-signature img{display:block;width:100%;max-width:420px;height:90px;object-fit:contain;border:1px solid #d8e2ea;border-radius:8px;background:white}
      .lc-jsa-review-signature-text{font-family:cursive;font-size:20px;padding:12px;border-bottom:1px solid #677b8d}
      .lc-jsa-review-empty{color:#718191;font-style:italic}
      @media(max-width:720px){.lc-jsa-review-grid,.lc-jsa-review-grid.three{grid-template-columns:1fr}.lc-jsa-review-signature{grid-template-columns:1fr}}
      @media print{.lc-jsa-review{gap:10px}.lc-jsa-review-section{box-shadow:none}.lc-jsa-review-grid{grid-template-columns:repeat(2,minmax(0,1fr))}.lc-jsa-review-grid.three{grid-template-columns:repeat(3,minmax(0,1fr))}}
    `;
    document.head.appendChild(style);
  }

  function detailsOf(jsa) {
    if (jsa?.details && typeof jsa.details === 'object') return jsa.details;
    if (typeof jsa?.details === 'string') {
      try { return JSON.parse(jsa.details); } catch (_) {}
    }
    return {};
  }

  function field(label, value, options = {}) {
    const shown = value === true ? 'Yes' : value === false ? 'No' : String(value ?? '').trim();
    if (!shown && options.skipEmpty) return '';
    return `<div class="lc-jsa-review-field"><span class="lc-jsa-review-label">${esc(label)}</span><div class="lc-jsa-review-value${shown ? '' : ' lc-jsa-review-empty'}">${shown ? esc(shown) : 'Not recorded'}</div></div>`;
  }

  function section(title, body) {
    return `<section class="lc-jsa-review-section"><h3>${esc(title)}</h3>${body}</section>`;
  }

  function grid(items, columns = 2) {
    return `<div class="lc-jsa-review-grid${columns === 3 ? ' three' : ''}">${items.join('')}</div>`;
  }

  function pills(values) {
    const list = Array.isArray(values) ? values.filter((value) => String(value || '').trim()) : [];
    if (!list.length) return '<div class="lc-jsa-review-empty">None selected</div>';
    return `<div class="lc-jsa-review-pills">${list.map((value) => `<span class="lc-jsa-review-pill">${esc(value)}</span>`).join('')}</div>`;
  }

  function safeSignature(value) {
    const signature = String(value || '').trim();
    return /^data:image\/(?:svg\+xml|png|jpeg);base64,[A-Za-z0-9+/=]+$/.test(signature) ? signature : '';
  }

  function signatureDisplay(value, alt) {
    const image = safeSignature(value);
    if (image) return `<img src="${esc(image)}" alt="${esc(alt)}">`;
    const text = String(value || '').trim();
    if (text) return `<div class="lc-jsa-review-signature-text">${esc(text)}</div>`;
    return '<div class="lc-jsa-review-empty">No signature captured</div>';
  }

  function legacyCrewRows(text) {
    return String(text || '').split(/\r?\n/).map((line) => {
      const separator = line.indexOf('| Signature:');
      if (separator < 0) return { printed_name: line.trim(), signature: '' };
      return { printed_name: line.slice(0, separator).trim(), signature: line.slice(separator + 12).trim() };
    }).filter((row) => row.printed_name || row.signature);
  }

  function crewSignatures(rows) {
    const crew = Array.isArray(rows) ? rows : [];
    if (!crew.length) return '<div class="lc-jsa-review-empty">No crew acknowledgments recorded</div>';
    return `<div class="lc-jsa-review-signatures">${crew.map((row, index) => `
      <div class="lc-jsa-review-signature">
        <div><span class="lc-jsa-review-label">Printed Name ${index + 1}</span><strong>${esc(row.printed_name || 'Not recorded')}</strong></div>
        <div><span class="lc-jsa-review-label">Signature ${index + 1}</span>${signatureDisplay(row.signature, `${row.printed_name || `Crew member ${index + 1}`} signature`)}</div>
      </div>`).join('')}</div>`;
  }

  function tasksTable(tasks, fallback) {
    const rows = Array.isArray(tasks) ? tasks.filter((row) => row?.job_task || row?.hazards || row?.mitigation) : [];
    if (!rows.length) {
      return grid([
        field('Work Plan / Briefing', fallback.job_briefing),
        field('Hazards', fallback.hazards),
        field('Controls / Mitigation', fallback.controls)
      ]);
    }
    return `<div style="overflow-x:auto"><table class="lc-jsa-review-table"><thead><tr><th>Job Task</th><th>Hazards</th><th>Work Procedure / Mitigation / Special Precautions</th></tr></thead><tbody>${rows.map((row) => `<tr><td>${esc(row.job_task || '')}</td><td>${esc(row.hazards || '')}</td><td>${esc(row.mitigation || '')}</td></tr>`).join('')}</tbody></table></div>`;
  }

  function fullForm(jsa) {
    const details = detailsOf(jsa);
    const briefing = details.briefing || {};
    const system = details.system || {};
    const emergency = details.emergency || {};
    const storm = details.storm_energy_control || {};
    const ppe = details.ppe || {};
    const transformer = details.transformer || {};
    const signoff = details.signoff || {};
    const crew = Array.isArray(details.crew_acknowledgments) && details.crew_acknowledgments.length
      ? details.crew_acknowledgments
      : legacyCrewRows(jsa.crew_members);
    const hasExpanded = Number(details.form_version || 0) >= 2 || Object.keys(briefing).length > 0;

    const header = `<div class="lc-jsa-review-head"><div><h2>Morning Job Safety Analysis</h2><p>${esc(jsa.job_number || 'Job')} — ${esc(jsa.job_name || '')}</p></div><div><strong>${esc(jsa.work_date || '')}</strong><br><span class="lc-jsa-review-label">COMPLETED</span></div></div>`;

    if (!hasExpanded) {
      return `<div class="lc-jsa-review">${header}${section('Work & Crew Information', grid([
        field('Foreman', jsa.foreman_name), field('Crew', jsa.crew_name), field('Conditions', jsa.weather_conditions), field('Special Equipment / Notes', jsa.special_equipment)
      ]))}${section('Job Tasks, Hazards & Mitigation', tasksTable([], jsa))}${section('Required PPE', field('Selected PPE', jsa.ppe))}${section('Emergency Information', field('Emergency Plan', jsa.emergency_plan))}${section('Crew Acknowledgment', crewSignatures(crew))}</div>`;
    }

    const systemFields = [
      ['Substation', 'substation'], ['Circuit', 'circuit'], ['Voltage', 'voltage'], ['Locate', 'locate_yn'], ['811 Locate #', 'locate_811_number'],
      ['Pole #', 'pole_number'], ['OCR / LR #', 'ocr_lr_number'], ['Nearest Meter', 'nearest_meter'], ['Dispatch #', 'dispatch_number'], ['After Hours #', 'after_hours_number'],
      ['Hold Card #', 'hold_card_number'], ['Switching Order #', 'switching_order_number'], ['Non-Reclosing Clearance Issued', 'non_reclosing_clearance_issued'],
      ['Time Issued', 'time_issued'], ['Returned', 'returned'], ['Clearance #', 'clearance_number'], ['Designated Qualified Observer (QO)', 'designated_qualified_observer'],
      ['Designated H2O Monitor', 'designated_h2o_monitor'], ['Designated Pole Top Rescue', 'designated_pole_top_rescue'], ['Designated Bucket Rescue', 'designated_bucket_rescue']
    ];
    const stormFields = [
      ['Storm Work', 'storm_work'], ['Back Feed Potential', 'back_feed_potential'], ['Grounds', 'grounds'], ['Adjacent Structures Inspected', 'adjacent_structures_inspected'],
      ['Dispatch Notified', 'dispatch_notified'], ['Voltage Test', 'voltage_test'], ['Lockout / Tagout', 'lockout_tagout']
    ];
    const transformerFields = [
      ['Check Name Plate', 'check_name_plate'], ['Primary Voltage', 'primary_voltage'], ['Secondary Voltage', 'secondary_voltage'], ['Impedance / Polarity', 'impedance_polarity'],
      ['Customer Breaker Off', 'customer_breaker_off'], ['Reading from Old Transformer', 'reading_from_old_transformer'], ['Pre-Check Rotation', 'pre_check_rotation'],
      ['Post Check Rotation', 'post_check_rotation'], ['New Transformer Voltage Reading', 'new_transformer_voltage_reading'], ['Rotation', 'rotation'],
      ['Clockwise', 'clockwise'], ['Counterclockwise', 'counterclockwise']
    ];

    return `<div class="lc-jsa-review">${header}
      ${section('1. Work & Crew Information', grid([
        field('Job', `${jsa.job_number || ''}${jsa.job_name ? ` — ${jsa.job_name}` : ''}`), field('Date', jsa.work_date), field('Time', briefing.time),
        field('Foreman', briefing.foreman || jsa.foreman_name), field('Crew', jsa.crew_name), field('JSA Leader', briefing.jsa_leader),
        field('Customer', briefing.customer), field('Nearest Physical Address / Cross Street / GPS', briefing.nearest_physical_address_cross_street_or_gps)
      ]))}
      ${section('2. System Information & Designated Safety / Rescue Roles', grid(systemFields.map(([label, key]) => field(label, system[key])), 3))}
      ${section('3. Emergency Information', grid([
        field('Local Emergency #', emergency.local_emergency_number), field('Medical Facility #', emergency.medical_facility_number),
        field('Nearest Medical Facility Name', emergency.nearest_medical_facility_name), field('Medical Facility Address', emergency.medical_facility_address),
        field('Emergency Meeting Point', emergency.emergency_meeting_point)
      ]))}
      ${section('4. Storm Restoration Work & Energy Source Control', grid(stormFields.map(([label, key]) => field(label, storm[key])), 3))}
      ${section('5. Personal Protection Equipment (PPE)', `${pills(ppe.selected)}${grid([field('Rubber Glove Pre-Use Field Test', ppe.rubber_glove_preuse_field_test)])}`)}
      ${section('6. Transformers — Checklist', grid(transformerFields.map(([label, key]) => field(label, transformer[key])), 3))}
      ${section('7. Energy Sources', `${pills(details.energy_sources)}<h3 style="margin-top:18px">Human Performance — 11 Common Human Error Traps</h3>${pills(details.human_performance_traps)}`)}
      ${section('8. Job Tasks, Hazards & Mitigation', tasksTable(details.tasks, jsa))}
      ${section('9. Crew Acknowledgment', crewSignatures(crew))}
      ${section('10. JSA Leader / Person in Charge Sign-Off', `<div class="lc-jsa-review-signature"><div>${field('Person in Charge Name', signoff.person_in_charge_name)}${grid([field('Date', signoff.date), field('Time', signoff.time)])}</div><div><span class="lc-jsa-review-label">JSA Leader Signature</span>${signatureDisplay(signoff.signature, 'JSA Leader signature')}</div></div>`)}
      ${section('Additional Information', grid([field('Morning Conditions', jsa.weather_conditions), field('Special Equipment / Additional Notes', jsa.special_equipment)]))}
    </div>`;
  }

  function printFullJsa(jsa) {
    const popup = window.open('', '_blank');
    if (!popup) { alert('Allow pop-ups to print or save this JSA as a PDF.'); return; }
    popup.document.write(`<!doctype html><html><head><title>Morning JSA</title><style>
      body{font-family:Arial,sans-serif;max-width:980px;margin:24px auto;padding:0 20px;color:#102235}.lc-jsa-review{display:grid;gap:10px}.lc-jsa-review-head{display:flex;justify-content:space-between;gap:14px;padding:12px;border:1px solid #b9c9d6;border-radius:10px}.lc-jsa-review-head h2{margin:0}.lc-jsa-review-head p{margin:4px 0 0}.lc-jsa-review-section{border:1px solid #ccd8e3;border-radius:10px;padding:12px;break-inside:avoid}.lc-jsa-review-section h3{margin:0 0 10px}.lc-jsa-review-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:7px}.lc-jsa-review-grid.three{grid-template-columns:repeat(3,minmax(0,1fr))}.lc-jsa-review-field{border:1px solid #e0e7ed;border-radius:7px;padding:7px}.lc-jsa-review-label{display:block;color:#617386;font-size:10px;font-weight:bold;margin-bottom:3px}.lc-jsa-review-value{white-space:pre-wrap;overflow-wrap:anywhere}.lc-jsa-review-pills{display:flex;flex-wrap:wrap;gap:5px}.lc-jsa-review-pill{padding:4px 7px;border-radius:999px;background:#e9f2fa;font-size:10px}.lc-jsa-review-table{width:100%;border-collapse:collapse}.lc-jsa-review-table th,.lc-jsa-review-table td{border:1px solid #ccd8e3;padding:7px;vertical-align:top;text-align:left;white-space:pre-wrap}.lc-jsa-review-table th{background:#eef4f8}.lc-jsa-review-signatures{display:grid;gap:7px}.lc-jsa-review-signature{display:grid;grid-template-columns:1fr 1.5fr;gap:8px;align-items:center;border:1px solid #d5dfe7;border-radius:8px;padding:8px}.lc-jsa-review-signature img{width:100%;height:70px;object-fit:contain;border:1px solid #d8e2ea}.lc-jsa-review-signature-text{font-family:cursive;font-size:18px;border-bottom:1px solid #677b8d}.lc-jsa-review-empty{color:#718191;font-style:italic}@media print{body{margin:0;max-width:none;padding:0}.lc-jsa-review-section{break-inside:avoid}}
    </style></head><body>${fullForm(jsa)}</body></html>`);
    popup.document.close();
    popup.focus();
    setTimeout(() => popup.print(), 350);
  }

  function refreshMetrics(records) {
    const metrics = byId('safetyJsaReportingMetrics');
    if (!metrics || !records.length) return;
    const jobs = new Set(records.map((jsa) => String(jsa.job_number || jsa.job_name || '').trim()).filter(Boolean));
    const foremen = new Set(records.map((jsa) => String(jsa.foreman_name || '').trim()).filter(Boolean));
    const crews = new Set(records.map((jsa) => String(jsa.crew_name || '').trim()).filter(Boolean));
    const crewSignIns = records.reduce((total, jsa) => {
      const details = detailsOf(jsa);
      const rows = Array.isArray(details.crew_acknowledgments) ? details.crew_acknowledgments : legacyCrewRows(jsa.crew_members);
      return total + rows.filter((row) => row.printed_name || row.signature).length;
    }, 0);
    metrics.innerHTML = `<span><strong>${records.length}</strong><br>Completed JSAs</span><span><strong>${jobs.size}</strong><br>Jobs</span><span><strong>${foremen.size}</strong><br>Foremen</span><span><strong>${crews.size}</strong><br>Crews</span><span><strong>${crewSignIns}</strong><br>Crew Sign-ins</span>`;
  }

  function upgradeRenderedCards() {
    if (typeof window.getFilteredSafetyJsas !== 'function') return;
    const records = window.getFilteredSafetyJsas();
    const cards = [...document.querySelectorAll('#safetyJsaList > details')];
    records.forEach((jsa, index) => {
      const target = cards[index]?.querySelector('.report-card-details');
      if (!target) return;
      target.innerHTML = fullForm(jsa);
      const button = document.createElement('button');
      button.className = 'secondary small';
      button.textContent = 'Print / Save Full JSA PDF';
      button.onclick = () => printFullJsa(jsa);
      target.appendChild(button);
    });
    refreshMetrics(records);
  }

  function install() {
    addStyles();
    const originalRender = window.renderSafetyJsas;
    if (typeof originalRender === 'function' && !originalRender.__linecrewFullReview) {
      const wrapped = function(...args) {
        const result = originalRender.apply(this, args);
        upgradeRenderedCards();
        return result;
      };
      wrapped.__linecrewFullReview = true;
      window.renderSafetyJsas = wrapped;
    }
    window.printSafetyJsa = printFullJsa;
    setTimeout(upgradeRenderedCards, 200);
  }

  window.LineCrewJsaReview = { fullForm, print: printFullJsa, refresh: upgradeRenderedCards };
  install();
})();
