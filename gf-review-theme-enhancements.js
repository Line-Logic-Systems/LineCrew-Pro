/* LineCrew Pro - GF review enhancements + Industrial Navy Dark Mode */
(() => {
  'use strict';
  const byId = id => document.getElementById(id);
  const esc = value => String(value ?? '').replace(/[&<>"']/g, ch => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[ch]));
  const profile = () => typeof currentProfile !== 'undefined' ? currentProfile : window.currentProfile;
  const role = () => String(profile()?.role || '').toLowerCase();
  const client = () => { try { return typeof sb !== 'undefined' ? sb : (window.sb || window.supabaseClient || null); } catch (_) { return window.sb || window.supabaseClient || null; } };

  let badgeTimer = null;
  let crewTimeBusy = false;

  function themeStorageKey(){
    const id = profile()?.id;
    return id ? `linecrew-pro-theme:${id}` : null;
  }

  function preferredTheme(){
    const key = themeStorageKey();
    if(!key) return 'light';
    try { return localStorage.getItem(key) === 'dark' ? 'dark' : 'light'; }
    catch (_) { return 'light'; }
  }

  function applyTheme(theme){
    const dark = theme === 'dark';
    document.documentElement.classList.toggle('lc-industrial-dark', dark);
    const toggle = byId('lcThemeToggle');
    if(toggle){
      toggle.textContent = dark ? 'Light Mode' : 'Dark Mode';
      toggle.setAttribute('aria-pressed', dark ? 'true' : 'false');
      toggle.title = dark ? 'Switch LineCrew Pro to Light Mode' : 'Switch LineCrew Pro to Industrial Navy Dark Mode';
    }
    const meta = document.querySelector('meta[name="theme-color"]');
    if(meta) meta.setAttribute('content', dark ? '#071522' : '#071d31');
  }

  function saveTheme(theme){
    const key = themeStorageKey();
    if(!key) return;
    try { localStorage.setItem(key, theme); } catch (_) {}
    applyTheme(theme);
  }

  function addThemeStyles(){
    if(byId('lcIndustrialDarkStyles')) return;
    const style = document.createElement('style');
    style.id = 'lcIndustrialDarkStyles';
    style.textContent = `
      @media screen {
        html.lc-industrial-dark {
          --navy:#071522;
          --blue:#2492ff;
          --bg:#07111d;
          --card:#10283a;
          --text:#f5f9fd;
          --muted:#9eb2c5;
          --border:#27506d;
          --green:#20a568;
          --red:#e15b5b;
          --orange:#e89a3d;
          color-scheme:dark;
        }
        html.lc-industrial-dark body{background:#07111d;color:#f5f9fd}
        html.lc-industrial-dark header{background:#06131f}
        html.lc-industrial-dark .card,
        html.lc-industrial-dark .job-card,
        html.lc-industrial-dark .metric,
        html.lc-industrial-dark .lc-role-workspace,
        html.lc-industrial-dark .tk-edit-card,
        html.lc-industrial-dark .jsa-attachment-viewer-card,
        html.lc-industrial-dark .pilot-feedback-card,
        html.lc-industrial-dark .assistant-panel,
        html.lc-industrial-dark .gf-assignment-list,
        html.lc-industrial-dark .production-job-group-reports .compact-report-card {
          background:#10283a!important;
          color:#f5f9fd!important;
          border-color:#27506d!important;
          box-shadow:0 2px 14px rgba(0,0,0,.28)!important;
        }
        html.lc-industrial-dark .production-job-group-reports,
        html.lc-industrial-dark .report-card-details,
        html.lc-industrial-dark .tk-employee-detail,
        html.lc-industrial-dark .gf-scope-bar,
        html.lc-industrial-dark #tkSummary,
        html.lc-industrial-dark .jsa-section,
        html.lc-industrial-dark .collapsible-card-content {
          background:#0c2030!important;
          border-color:#27506d!important;
          color:#f5f9fd!important;
        }
        html.lc-industrial-dark .muted,
        html.lc-industrial-dark .tk-help,
        html.lc-industrial-dark .tk-employee-meta,
        html.lc-industrial-dark .gf-assignment-help,
        html.lc-industrial-dark .jsa-history-note,
        html.lc-industrial-dark .lc-role-workspace span,
        html.lc-industrial-dark .mh-rate-status-text { color:#9eb2c5!important; }
        html.lc-industrial-dark h1,
        html.lc-industrial-dark h2,
        html.lc-industrial-dark h3,
        html.lc-industrial-dark strong,
        html.lc-industrial-dark .lc-role-workspace strong,
        html.lc-industrial-dark .tk-employee-metric strong { color:#f5f9fd!important; }
        html.lc-industrial-dark input,
        html.lc-industrial-dark select,
        html.lc-industrial-dark textarea {
          background:#0a1c2a!important;
          color:#f5f9fd!important;
          border-color:#315f7f!important;
        }
        html.lc-industrial-dark input::placeholder,
        html.lc-industrial-dark textarea::placeholder { color:#7890a4!important; }
        html.lc-industrial-dark button:not(.success):not(.danger):not(.warning),
        html.lc-industrial-dark .secondary {
          background:#17486c!important;
          color:#f7fbff!important;
          border-color:#2e78ab!important;
        }
        html.lc-industrial-dark button:not(.secondary):not(.success):not(.danger):not(.warning){background:#1687ee!important;color:white!important}
        html.lc-industrial-dark .success{background:#198f59!important;color:white!important}
        html.lc-industrial-dark table,
        html.lc-industrial-dark .tk-table { background:#0d2233!important;color:#f5f9fd!important; }
        html.lc-industrial-dark th { background:#16344a!important;color:#f5f9fd!important;border-color:#27506d!important; }
        html.lc-industrial-dark td { border-color:#24485f!important; }
        html.lc-industrial-dark .status.active,
        html.lc-industrial-dark .billing-status.paid { background:#173d2e!important;color:#79e1aa!important; }
        html.lc-industrial-dark .billing-preview-table th,
        html.lc-industrial-dark .billing-batch-card { border-color:#27506d!important; }
        html.lc-industrial-dark .billing-redline-row { background:#3b2026!important; }
        html.lc-industrial-dark .storm-mode-banner { background:#3a2916!important;color:#ffd59b!important; }
        .lc-theme-toggle-wrap{display:flex;justify-content:flex-end;align-items:center;margin:8px 0 12px}
        .lc-theme-toggle{width:auto!important;margin:0!important;padding:7px 11px!important;font-size:12px!important;border-radius:999px!important}
        .lc-production-review-badge{position:absolute;top:9px;right:10px;min-width:22px;height:22px;padding:0 6px;border-radius:999px;background:#d73939;color:#fff;display:flex;align-items:center;justify-content:center;font-size:11px;font-weight:800;box-shadow:0 0 0 2px var(--card)}
        #productionTile{position:relative}
        .gf-crew-time-review{margin:10px 0 8px;border:1px solid var(--border);border-radius:10px;overflow:hidden;background:var(--card)}
        .gf-crew-time-review>summary{cursor:pointer;list-style:none;padding:8px 10px;font-size:12px;font-weight:800;background:rgba(36,146,255,.08)}
        .gf-crew-time-review>summary::-webkit-details-marker{display:none}
        .gf-crew-time-scroll{overflow:auto}
        .gf-crew-time-table{width:100%;min-width:720px;border-collapse:collapse;font-size:11px}
        .gf-crew-time-table th,.gf-crew-time-table td{padding:6px 7px;border-bottom:1px solid var(--border);text-align:left;white-space:nowrap}
        .gf-crew-time-table th{font-size:10px;text-transform:uppercase;color:var(--muted);background:rgba(36,146,255,.05)}
        .gf-crew-time-empty{padding:9px 10px;color:var(--muted);font-size:11px}
      }
    `;
    document.head.appendChild(style);
  }

  function installThemeToggle(){
    const dashboard = byId('dashboardPage');
    if(!dashboard || dashboard.classList.contains('hidden') || !profile()) return;
    let wrap = byId('lcThemeToggleWrap');
    if(!wrap){
      wrap = document.createElement('div');
      wrap.id = 'lcThemeToggleWrap';
      wrap.className = 'lc-theme-toggle-wrap';
      wrap.innerHTML = '<button type="button" id="lcThemeToggle" class="secondary small lc-theme-toggle" aria-pressed="false">Dark Mode</button>';
      const banner = byId('lcRoleWorkspace');
      if(banner?.nextSibling) banner.parentNode.insertBefore(wrap, banner.nextSibling);
      else dashboard.prepend(wrap);
      byId('lcThemeToggle').addEventListener('click', () => {
        saveTheme(document.documentElement.classList.contains('lc-industrial-dark') ? 'light' : 'dark');
      });
    }
    applyTheme(preferredTheme());
  }

  function syncGfDashboardReviewAlert(count){
    if(role() !== 'gf') return;
    const card = byId('dashboardReviewAlert');
    if(!card) return;
    if(!count){
      card.classList.add('hidden');
      return;
    }
    const text = byId('dashboardReviewAlertText');
    const button = byId('openProductionReview');
    const heading = card.querySelector('h3');
    if(text){
      text.textContent = `${count} submitted daily report${count===1?'':'s'} waiting for GF review.`;
    }
    if(heading) heading.textContent = 'Production Needs Review';
    if(button) button.textContent = 'Review Reports';
    card.classList.remove('hidden');
  }

  async function refreshProductionBadge(){
    clearTimeout(badgeTimer);
    const tile = byId('productionTile');
    if(!tile) return;
    if(role() !== 'gf' || !profile()?.company_id || !client()){
      byId('lcProductionReviewBadge')?.remove();
      return;
    }
    try{
      let query = client().from('daily_reports')
        .select('id', { count:'exact', head:true })
        .eq('company_id', profile().company_id)
        .eq('status', 'submitted');
      const scope = window.linecrewGfCrewScope;
      if(scope){
        await scope.ensureLoaded?.();
        if(scope.shouldScope?.()){
          const ids = scope.foremanIds?.() || [];
          if(ids.length) query = query.in('foreman_id', ids);
        }
      }
      const {count,error} = await query;
      if(error) throw error;
      let badge = byId('lcProductionReviewBadge');
      if(!count){
        badge?.remove();
        syncGfDashboardReviewAlert(0);
        return;
      }
      if(!badge){
        badge = document.createElement('span');
        badge.id = 'lcProductionReviewBadge';
        badge.className = 'lc-production-review-badge';
        tile.appendChild(badge);
      }
      badge.textContent = count > 99 ? '99+' : String(count);
      badge.title = `${count} Daily Report${count===1?'':'s'} waiting for your review`;
      badge.setAttribute('aria-label', badge.title);
      syncGfDashboardReviewAlert(count);
    }catch(error){
      console.warn('Unable to refresh GF Production review badge:', error.message || error);
    }
  }

  function scheduleBadge(delay=100){
    clearTimeout(badgeTimer);
    badgeTimer = setTimeout(refreshProductionBadge, delay);
  }

  function parseReportCard(card){
    const meta = card.querySelector('.report-summary-meta')?.textContent || '';
    const date = (meta.match(/\b\d{4}-\d{2}-\d{2}\b/) || [])[0] || '';
    const jobNumber = (card.querySelector('.report-card-details .job-number')?.textContent || card.querySelector('.report-summary-main strong')?.textContent || '').trim();
    const text = (card.querySelector('.report-summary-main')?.textContent || card.textContent || '').toLowerCase();
    return {date,jobNumber,text};
  }

  async function resolveReportId(card){
    const {date,jobNumber,text} = parseReportCard(card);
    if(!date || !jobNumber || !profile()?.company_id) return null;
    const sbc = client();
    const jobs = await sbc.from('jobs').select('id').eq('company_id',profile().company_id).eq('job_number',jobNumber).limit(2);
    if(jobs.error || !jobs.data?.length) return null;
    const reports = await sbc.from('daily_reports').select('id,foreman_id').eq('company_id',profile().company_id).eq('job_id',jobs.data[0].id).eq('work_date',date).order('created_at',{ascending:false});
    if(reports.error || !reports.data?.length) return null;
    if(reports.data.length === 1) return reports.data[0].id;
    const ids = reports.data.map(r=>r.foreman_id).filter(Boolean);
    if(ids.length){
      const names = await sbc.from('profiles').select('id,full_name').in('id',ids);
      if(!names.error){
        const match = reports.data.find(r=>{
          const n = names.data?.find(p=>p.id===r.foreman_id)?.full_name;
          return n && text.includes(String(n).toLowerCase());
        });
        if(match) return match.id;
      }
    }
    return reports.data[0].id;
  }

  async function loadCrewTimeIntoCard(card){
    if(role() !== 'gf' || !card.open || card.dataset.gfCrewTimeLoaded === '1' || card.dataset.gfCrewTimeLoading === '1') return;
    const details = card.querySelector('.report-card-details');
    if(!details) return;
    card.dataset.gfCrewTimeLoading = '1';
    let box = card.querySelector('.gf-crew-time-review');
    if(!box){
      box = document.createElement('details');
      box.className = 'gf-crew-time-review';
      box.open = true;
      box.innerHTML = '<summary>Crew Time</summary><div class="gf-crew-time-empty">Loading individual crew time…</div>';
      details.appendChild(box);
    }
    try{
      const reportId = await resolveReportId(card);
      const date = parseReportCard(card).date;
      if(!reportId || !date) throw new Error('Could not identify this Daily Report.');
      const sbc = client();
      const result = await sbc.rpc('timekeeping_report_rows_v2',{p_from:date,p_through:date,p_employee:null,p_job:null});
      if(result.error) throw result.error;
      const rows = (result.data || []).filter(r=>r.daily_report_id===reportId);
      if(!rows.length){
        box.innerHTML = '<summary>Crew Time</summary><div class="gf-crew-time-empty">No individual crew time is recorded for this report.</div>';
        card.dataset.gfCrewTimeLoaded='1';
        return;
      }
      const employeeIds=[...new Set(rows.map(r=>r.employee_id).filter(Boolean))];
      const emps = await sbc.from('timekeeping_employees').select('id,full_name,classification').in('id',employeeIds);
      if(emps.error) throw emps.error;
      const employeeMap = new Map((emps.data||[]).map(e=>[e.id,e]));
      const grouped = new Map();
      rows.forEach(r=>{
        const key=r.employee_id;
        if(!grouped.has(key)) grouped.set(key,[]);
        grouped.get(key).push(r);
      });
      const display=[...grouped.entries()].map(([employeeId,segs])=>{
        const e=employeeMap.get(employeeId)||{};
        const reg=segs.reduce((s,r)=>s+Number(r.regular_hours||0),0);
        const ot=segs.reduce((s,r)=>s+Number(r.overtime_hours||0),0);
        const start=segs.map(r=>r.start_time).filter(Boolean).sort()[0]||'';
        const stop=segs.map(r=>r.stop_time).filter(Boolean).sort().slice(-1)[0]||'';
        const lunch=segs.reduce((s,r)=>s+Number(r.lunch_minutes||0),0);
        const perDiem=segs.some(r=>!!r.per_diem);
        const equipment=segs.find(r=>r.equipment_not_used)?.equipment_not_used ? 'Not used' : (segs.map(r=>r.equipment_used).find(Boolean)||'');
        return {name:e.full_name||'Employee',classification:e.classification||'',start:String(start).slice(0,5),stop:String(stop).slice(0,5),lunch,reg,ot,total:reg+ot,perDiem,equipment};
      }).sort((a,b)=>a.name.localeCompare(b.name));
      box.innerHTML = `<summary>Crew Time — ${display.length} people</summary><div class="gf-crew-time-scroll"><table class="gf-crew-time-table"><thead><tr><th>Employee</th><th>Start</th><th>Stop</th><th>Lunch</th><th>Regular</th><th>OT</th><th>Total</th><th>Per Diem</th><th>Equipment</th></tr></thead><tbody>${display.map(x=>`<tr><td><strong>${esc(x.name)}</strong>${x.classification?`<br><span class="muted">${esc(x.classification)}</span>`:''}</td><td>${esc(x.start||'—')}</td><td>${esc(x.stop||'—')}</td><td>${x.lunch}</td><td>${x.reg.toFixed(2)}</td><td>${x.ot.toFixed(2)}</td><td><strong>${x.total.toFixed(2)}</strong></td><td>${x.perDiem?'Yes':'No'}</td><td>${esc(x.equipment||'—')}</td></tr>`).join('')}</tbody></table></div>`;
      card.dataset.gfCrewTimeLoaded='1';
    }catch(error){
      box.innerHTML = `<summary>Crew Time</summary><div class="gf-crew-time-empty">Unable to load individual crew time: ${esc(error.message||error)}</div>`;
    }finally{
      delete card.dataset.gfCrewTimeLoading;
    }
  }

  async function refreshOpenCrewTimeCards(){
    if(crewTimeBusy || role()!=='gf') return;
    crewTimeBusy=true;
    try{
      const cards=[...document.querySelectorAll('#productionPage .production-job-group-reports details.compact-report-card[open]')];
      for(const card of cards) await loadCrewTimeIntoCard(card);
    }finally{crewTimeBusy=false;}
  }

  function refreshUi(){
    addThemeStyles();
    if(profile()) applyTheme(preferredTheme());
    else applyTheme('light');
    installThemeToggle();
    scheduleBadge();
    refreshOpenCrewTimeCards();
  }

  function init(){
    addThemeStyles();
    const observer = new MutationObserver(()=>setTimeout(refreshUi,40));
    observer.observe(document.body,{subtree:true,childList:true,attributes:true,attributeFilter:['class','open']});
    document.addEventListener('toggle',event=>{if(event.target?.matches?.('#productionPage details.compact-report-card')) loadCrewTimeIntoCard(event.target);},true);
    document.addEventListener('click',event=>{
      if(event.target?.closest?.('#productionTile,#openProductionReview,[data-production-review]')) scheduleBadge(250);
    });
    document.addEventListener('visibilitychange',()=>{if(!document.hidden){refreshUi();scheduleBadge();}});
    window.addEventListener('focus',()=>{refreshUi();scheduleBadge();});
    [0,250,800,1800,3500].forEach(delay=>setTimeout(refreshUi,delay));
    setInterval(()=>{scheduleBadge(0);refreshOpenCrewTimeCards();},30000);
  }
  if(document.readyState==='loading') document.addEventListener('DOMContentLoaded',init); else init();
})();
