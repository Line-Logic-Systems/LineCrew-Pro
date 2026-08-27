/* LineCrew Pro - Foreman Crew Time labels and Remaining Units workspace */
(() => {
  'use strict';

  const byId = id => document.getElementById(id);
  const esc = value => String(value ?? '').replace(/[&<>"']/g, char => ({
    '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'
  }[char]));
  const number = value => Number(value || 0) || 0;
  const profile = () => {
    try { return typeof currentProfile !== 'undefined' ? currentProfile : window.currentProfile; }
    catch (_) { return window.currentProfile; }
  };
  const role = () => String(profile()?.role || '').toLowerCase();
  const client = () => {
    try { return typeof sb !== 'undefined' ? sb : (window.sb || window.supabaseClient); }
    catch (_) { return window.sb || window.supabaseClient; }
  };

  let jobs = [];
  let rows = [];

  function toast(message, type='info') {
    if (window.LineCrewUI?.toast) window.LineCrewUI.toast(message, type);
    else window.alert(message);
  }

  function addStyles() {
    if (byId('foremanFieldToolsStyles')) return;
    const style = document.createElement('style');
    style.id = 'foremanFieldToolsStyles';
    style.textContent = `
      .remaining-units-tools{display:grid;grid-template-columns:minmax(220px,1fr) minmax(180px,.8fr) auto;gap:10px;align-items:end}
      .remaining-units-tools label{margin:0}
      .remaining-units-tools button{width:auto;margin:0}
      .remaining-units-help{border:1px solid #dce5ed;background:#f8fafc;border-radius:12px;padding:11px 12px;margin:12px 0;font-size:13px;color:#5f7182;line-height:1.45}
      .remaining-units-summary{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:10px;margin:12px 0}
      .remaining-units-summary>div{border:1px solid #dce5ed;background:#f8fafc;border-radius:12px;padding:10px;text-align:center}
      .remaining-units-summary strong{display:block;font-size:21px;color:#0b2d4d}
      .remaining-units-table-wrap{overflow-x:auto}
      .remaining-units-table{width:100%;border-collapse:collapse;min-width:860px}
      .remaining-units-table th,.remaining-units-table td{padding:9px 8px;border-bottom:1px solid #dce5ed;text-align:left;vertical-align:middle}
      .remaining-units-table th{font-size:11px;text-transform:uppercase;color:#617284}
      .remaining-units-table td:nth-last-child(-n+5),.remaining-units-table th:nth-last-child(-n+5){text-align:right;font-variant-numeric:tabular-nums}
      .remaining-unit-toggle{appearance:none!important;display:block!important;width:100%!important;margin:0!important;padding:0!important;border:0!important;background:transparent!important;box-shadow:none!important;color:inherit!important;font:inherit!important;text-align:left!important;cursor:pointer}
      .remaining-unit-code{display:flex;align-items:center;gap:5px;min-width:0;line-height:1.2}
      .remaining-unit-code strong{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
      .remaining-unit-toggle-icon{flex:0 0 auto;color:#1677d2;font-size:11px;transition:transform .15s ease}
      .remaining-unit-description{display:-webkit-box;-webkit-box-orient:vertical;-webkit-line-clamp:2;overflow:hidden;max-height:2.4em;margin-top:1px;line-height:1.2}
      .remaining-unit-toggle.is-expanded .remaining-unit-description{display:block;-webkit-line-clamp:unset;max-height:none}
      .remaining-unit-toggle.is-expanded .remaining-unit-toggle-icon{transform:rotate(180deg)}
      .remaining-unit-toggle:focus-visible{outline:2px solid #1677d2!important;outline-offset:3px}
      .remaining-units-left{font-size:16px;color:#1677d2}
      .remaining-units-complete{opacity:.62}
      .remaining-units-empty{border:1px dashed #cbd7e2;border-radius:12px;padding:16px;color:#607386;background:#f8fbfe}
      .remaining-units-check{display:flex;align-items:center;gap:7px;margin:10px 0;font-size:13px}
      .remaining-units-check input{width:auto;margin:0}
      html.lc-industrial-dark .remaining-units-help,
      html.lc-industrial-dark .remaining-units-summary>div,
      html.lc-industrial-dark .remaining-units-empty{background:#10283a!important;border-color:#315f7f!important;color:#9eb2c5!important}
      html.lc-industrial-dark .remaining-units-summary strong,
      html.lc-industrial-dark .remaining-units-left{color:#73bfff!important}
      @media(max-width:720px){
        .remaining-units-tools{grid-template-columns:1fr}
        .remaining-units-tools button{width:100%}
        .remaining-units-summary{grid-template-columns:repeat(3,1fr);gap:6px}
        .remaining-units-summary>div{padding:8px 4px;font-size:10px}
        .remaining-units-summary strong{font-size:17px}
      }
    `;
    document.head.appendChild(style);
  }

  function syncCrewTimeLabels() {
    const isForeman = role() === 'foreman';
    const tile = byId('timekeepingTile');
    const title = tile?.querySelector('strong');
    const description = tile?.querySelector('.muted');
    const titleText = isForeman ? 'Crew Time' : 'Timekeeping';
    if (title && title.textContent !== titleText) title.textContent = titleText;
    if (description && isForeman && description.textContent !== 'Review your crew hours and per diem') description.textContent = 'Review your crew hours and per diem';
    const page = byId('timekeepingPage');
    const heading = page?.querySelector('.section-header h2');
    const subtitle = page?.querySelector('.section-header .muted');
    const reportHeading = page?.querySelector('#timekeepingRosterCard + .card h3');
    const headingText = isForeman ? 'Crew Time' : 'Timekeeping';
    const reportHeadingText = isForeman ? 'Crew Time Report' : 'Time Report';
    if (heading && heading.textContent !== headingText) heading.textContent = headingText;
    if (subtitle && isForeman && subtitle.textContent !== 'Review hours, overtime, per diem and equipment for your assigned crew.') subtitle.textContent = 'Review hours, overtime, per diem and equipment for your assigned crew.';
    if (reportHeading && reportHeading.textContent !== reportHeadingText) reportHeading.textContent = reportHeadingText;
  }

  function createPage() {
    if (byId('remainingUnitsPage')) return;
    const main = document.querySelector('main');
    if (!main) return;
    const page = document.createElement('section');
    page.id = 'remainingUnitsPage';
    page.className = 'hidden';
    page.innerHTML = `
      <div class="card">
        <div class="section-header">
          <div><h2>Remaining Units</h2><p class="muted">Authorized units still available by job and work point.</p></div>
          <button id="remainingUnitsBack" type="button" class="secondary small">Back to Dashboard</button>
        </div>
      </div>
      <div class="card">
        <div class="remaining-units-tools">
          <label>Assigned Job<select id="remainingUnitsJob"><option value="">Select a job</option></select></label>
          <label>Search Work Point or Unit<input id="remainingUnitsSearch" type="search" placeholder="Example: WP 1 or OH4200"></label>
          <button id="remainingUnitsRefresh" type="button" class="secondary">Refresh</button>
        </div>
        <div class="remaining-units-help">Saved drafts and submitted reports reserve those quantities so another Foreman does not report them twice. Returned quantities become available again until the corrected report is resubmitted. Redlines are kept separate and never reduce the authorized quantity shown here.</div>
        <label class="remaining-units-check"><input id="remainingUnitsShowComplete" type="checkbox"> Show units with zero remaining</label>
        <div id="remainingUnitsSummary" class="remaining-units-summary"></div>
        <div id="remainingUnitsList" class="remaining-units-empty">Choose an assigned job to see its remaining units.</div>
      </div>`;
    main.appendChild(page);
    byId('remainingUnitsBack').onclick = backToDashboard;
    byId('remainingUnitsJob').onchange = () => loadRows().catch(error => {
      toast('Could not load Remaining Units: ' + (error.message || error), 'error');
    });
    byId('remainingUnitsRefresh').onclick = refresh;
    byId('remainingUnitsSearch').addEventListener('input', renderRows);
    byId('remainingUnitsShowComplete').addEventListener('change', renderRows);
    byId('remainingUnitsList').addEventListener('click', event => {
      const toggle = event.target?.closest?.('.remaining-unit-toggle');
      if (!toggle) return;
      const expanded = toggle.getAttribute('aria-expanded') === 'true';
      toggle.classList.toggle('is-expanded', !expanded);
      toggle.setAttribute('aria-expanded', String(!expanded));
      toggle.title = expanded ? 'Show full unit description' : 'Collapse unit description';
    });
  }

  function createTile() {
    const dashboard = byId('dashboardPage');
    const grid = dashboard?.querySelector('.grid');
    if (!grid || byId('remainingUnitsTile')) return;
    const tile = document.createElement('div');
    tile.id = 'remainingUnitsTile';
    tile.className = 'metric hidden';
    tile.setAttribute('role', 'link');
    tile.tabIndex = 0;
    tile.innerHTML = '<strong>Remaining Units</strong><span class="muted">What is left by job and work point</span>';
    tile.onclick = open;
    tile.addEventListener('keydown', event => {
      if (event.key === 'Enter' || event.key === ' ') {
        event.preventDefault();
        open();
      }
    });
    grid.appendChild(tile);
  }

  function syncVisibility() {
    const tile = byId('remainingUnitsTile');
    if (tile) tile.classList.toggle('hidden', role() !== 'foreman');
    syncCrewTimeLabels();
  }

  function hideAppPages() {
    document.querySelectorAll('main > section').forEach(section => section.classList.add('hidden'));
  }

  function backToDashboard() {
    byId('remainingUnitsPage')?.classList.add('hidden');
    if (typeof show === 'function') show('dashboardPage');
    else byId('dashboardPage')?.classList.remove('hidden');
  }

  async function open() {
    if (role() !== 'foreman') return;
    hideAppPages();
    byId('remainingUnitsPage')?.classList.remove('hidden');
    await refresh();
  }

  async function loadJobs() {
    const activeProfile = profile();
    const sbClient = client();
    if (!activeProfile?.company_id || !sbClient) return;
    const { data, error } = await sbClient.from('jobs')
      .select('id,job_number,job_name')
      .eq('company_id', activeProfile.company_id)
      .eq('active', true)
      .order('job_number');
    if (error) throw error;
    const unique = new Map();
    (data || []).forEach(job => { if (job?.id && !unique.has(job.id)) unique.set(job.id, job); });
    jobs = [...unique.values()];
    const select = byId('remainingUnitsJob');
    if (!select) return;
    const previous = select.value;
    select.innerHTML = '<option value="">Select an assigned job</option>' + jobs.map(job =>
      `<option value="${esc(job.id)}">${esc(job.job_number || '')}${job.job_name ? ' — ' + esc(job.job_name) : ''}</option>`
    ).join('');
    if (jobs.some(job => job.id === previous)) select.value = previous;
    else if (jobs.length === 1) select.value = jobs[0].id;
  }

  async function refresh() {
    const button = byId('remainingUnitsRefresh');
    const done = window.LineCrewUI?.loadingButton?.(button, 'Refreshing…') || (() => {});
    try {
      if (!navigator.onLine) throw new Error('Reconnect to service to refresh Remaining Units.');
      await loadJobs();
      if (!jobs.length) {
        rows = [];
        byId('remainingUnitsSummary').innerHTML = '';
        byId('remainingUnitsList').className = 'remaining-units-empty';
        byId('remainingUnitsList').textContent = 'No active jobs are currently assigned to this Foreman.';
        return;
      }
      await loadRows();
    } catch (error) {
      rows = [];
      byId('remainingUnitsSummary').innerHTML = '';
      byId('remainingUnitsList').className = 'remaining-units-empty';
      byId('remainingUnitsList').textContent = error.message || 'Remaining Units could not be loaded.';
      toast('Could not load Remaining Units: ' + (error.message || error), 'error');
    } finally {
      done();
    }
  }

  async function loadRows() {
    const jobId = byId('remainingUnitsJob')?.value;
    if (!jobId) {
      rows = [];
      renderRows();
      return;
    }
    const { data, error } = await client().rpc('get_remaining_job_units_for_field', { p_job_id:jobId });
    if (error) throw error;
    rows = data || [];
    renderRows();
  }

  function quantity(value) {
    const amount = number(value);
    return Number.isInteger(amount) ? String(amount) : amount.toFixed(2).replace(/0+$/, '').replace(/\.$/, '');
  }

  function workTypeLabel(value) {
    return ({install:'Install',transfer:'Transfer',remove:'Remove'})[String(value || '').toLowerCase()] || value || '';
  }

  function renderRows() {
    const list = byId('remainingUnitsList');
    const summary = byId('remainingUnitsSummary');
    if (!list || !summary) return;
    const jobId = byId('remainingUnitsJob')?.value;
    if (!jobId) {
      summary.innerHTML = '';
      list.className = 'remaining-units-empty';
      list.textContent = 'Choose an assigned job to see its remaining units.';
      return;
    }
    const search = String(byId('remainingUnitsSearch')?.value || '').trim().toLowerCase();
    const showComplete = byId('remainingUnitsShowComplete')?.checked === true;
    const visible = rows.filter(row => {
      if (!showComplete && number(row.remaining_quantity) <= 0) return false;
      if (!search) return true;
      return [row.work_point_code,row.work_point_description,row.unit_code,row.unit_name,row.unit_description,row.work_type]
        .some(value => String(value || '').toLowerCase().includes(search));
    });
    const workPoints = new Set(rows.filter(row => number(row.remaining_quantity) > 0).map(row => row.work_point_id)).size;
    const unitLines = rows.filter(row => number(row.remaining_quantity) > 0).length;
    const remaining = rows.reduce((sum,row) => sum + number(row.remaining_quantity), 0);
    summary.innerHTML = `<div><strong>${workPoints}</strong>Work Points Left</div><div><strong>${unitLines}</strong>Unit Lines Left</div><div><strong>${quantity(remaining)}</strong>Total Quantity Left</div>`;
    if (!rows.length) {
      list.className = 'remaining-units-empty';
      list.textContent = 'This job does not have an active authorized unit packet yet.';
      return;
    }
    if (!visible.length) {
      list.className = 'remaining-units-empty';
      list.textContent = search ? 'No remaining units match this search.' : 'All authorized units on this job have been reported.';
      return;
    }
    list.className = 'remaining-units-table-wrap';
    list.innerHTML = `<table class="remaining-units-table"><thead><tr><th>Work Point</th><th>Unit</th><th>Work</th><th>Authorized</th><th>Saved Draft</th><th>Awaiting GF</th><th>Approved</th><th>Remaining</th></tr></thead><tbody>${visible.map(row => {
      const complete = number(row.remaining_quantity) <= 0;
      const unitCode = row.unit_code || '';
      const unitDescription = row.unit_name || row.unit_description || '';
      const unitCell = unitDescription
        ? `<button type="button" class="remaining-unit-toggle" aria-expanded="false" aria-label="Show full description for ${esc(unitCode)}" title="Show full unit description"><span class="remaining-unit-code"><strong>${esc(unitCode)}</strong><span class="remaining-unit-toggle-icon" aria-hidden="true">▼</span></span><span class="remaining-unit-description muted">${esc(unitDescription)}</span></button>`
        : `<strong>${esc(unitCode)}</strong>`;
      return `<tr class="${complete ? 'remaining-units-complete' : ''}"><td><strong>${esc(row.work_point_code || '')}</strong>${row.work_point_description ? `<br><span class="muted">${esc(row.work_point_description)}</span>` : ''}</td><td>${unitCell}</td><td>${esc(workTypeLabel(row.work_type))}</td><td>${quantity(row.authorized_quantity)}</td><td>${quantity(row.draft_quantity)}</td><td>${quantity(row.submitted_quantity)}</td><td>${quantity(row.approved_quantity)}</td><td><strong class="remaining-units-left">${quantity(row.remaining_quantity)}</strong></td></tr>`;
    }).join('')}</tbody></table>`;
  }

  function init() {
    addStyles();
    createPage();
    createTile();
    syncVisibility();
    const observer = new MutationObserver(syncVisibility);
    observer.observe(document.body, {subtree:true, childList:true});
    [200,700,1500,3000].forEach(delay => setTimeout(syncVisibility, delay));
    document.addEventListener('visibilitychange', () => { if (!document.hidden) syncVisibility(); });
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
