/* LineCrew Pro recovery guard + expanded JSA loader */
(() => {
  'use strict';

  const isRecoveryUrl = () => {
    const text = (window.location.search || '') + '&' + (window.location.hash || '');
    return /(?:^|[&#?])type=recovery(?:&|$)/i.test(text) || /password_recovery/i.test(text);
  };

  const forceRecoveryUi = () => {
    const authPage = document.getElementById('authPage');
    const setupPage = document.getElementById('setupPage');
    const dashboardPage = document.getElementById('dashboardPage');
    const teamPage = document.getElementById('teamPage');
    const jobsPage = document.getElementById('jobsPage');
    const productionPage = document.getElementById('productionPage');
    const safetyPage = document.getElementById('safetyPage');
    const priceBooksPage = document.getElementById('priceBooksPage');
    const recoveryCard = document.getElementById('passwordRecoveryCard');
    const recoveryPassword = document.getElementById('recoveryPassword');

    [setupPage, dashboardPage, teamPage, jobsPage, productionPage, safetyPage, priceBooksPage]
      .forEach((el) => el?.classList.add('hidden'));
    authPage?.classList.remove('hidden');
    recoveryCard?.classList.remove('hidden');
    setTimeout(() => recoveryPassword?.focus(), 0);
  };

  const markRecovery = () => {
    sessionStorage.setItem('linecrew-password-recovery', '1');
    forceRecoveryUi();
    [0, 50, 150, 400, 900].forEach((delay) => setTimeout(forceRecoveryUi, delay));
  };

  if (isRecoveryUrl()) markRecovery();
  if (sessionStorage.getItem('linecrew-password-recovery') === '1') forceRecoveryUi();

  if (window.sb?.auth?.onAuthStateChange) {
    window.sb.auth.onAuthStateChange((event) => {
      if (event === 'PASSWORD_RECOVERY') {
        markRecovery();
        return;
      }
      if (event === 'USER_UPDATED' && sessionStorage.getItem('linecrew-password-recovery') === '1') {
        sessionStorage.removeItem('linecrew-password-recovery');
      }
    });
  }

  const saveButton = document.getElementById('saveRecoveryPassword');
  if (saveButton) {
    saveButton.addEventListener('click', () => {
      setTimeout(() => {
        const card = document.getElementById('passwordRecoveryCard');
        if (card?.classList.contains('hidden')) {
          sessionStorage.removeItem('linecrew-password-recovery');
        }
      }, 1200);
    });
  }

  const productionTile = document.getElementById('productionTile');
  const productionDescription = productionTile?.querySelector('.muted');
  if (productionDescription) {
    productionDescription.textContent = 'Daily production reporting and review';
  }

  const load = (src, onload) => {
    const script = document.createElement('script');
    script.src = src;
    script.defer = false;
    if (onload) script.onload = onload;
    document.head.appendChild(script);
  };

  load('app-polish.js?v=20260822a');
  load('role-workspace-polish.js?v=20260822a');
  load('expanded-jsa-core.js?v=20260820', () => {
    load('jsa-signatures.js?v=20260820j', () => load('jsa-signature-layout-fix.js?v=20260820a'));
  });
  load('timekeeping.js?v=20260823a', () => {
    load('timekeeping-roster.js?v=20260823a');
    load('timekeeping-report-v2.js?v=20260820b', () => {
      load('timekeeping-polish.js?v=20260820a');
      load('timekeeping-payroll.js?v=20260820a');
    });
  });
})();

/* Returned Daily Report recovery + Foreman notification */
(() => {
  'use strict';

  const RETURN_NOTICE_ID = 'linecrewReturnedReportNotice';

  function esc(value) {
    return String(value ?? '')
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&#039;');
  }

  function foremanReady() {
    try {
      return typeof currentProfile !== 'undefined' &&
        currentProfile &&
        String(currentProfile.role || '').toLowerCase() === 'foreman' &&
        typeof sb !== 'undefined';
    } catch (_) {
      return false;
    }
  }

  async function getReturnedReports() {
    if (!foremanReady()) return [];
    const { data, error } = await sb
      .from('daily_reports')
      .select(`
        id,
        job_id,
        work_date,
        foreman_name,
        crew_name,
        regular_hours,
        overtime_hours,
        weather_conditions,
        delay_hours,
        delay_reason,
        notes,
        status,
        review_notes,
        reviewed_at,
        updated_at,
        jobs (
          job_number,
          job_name
        )
      `)
      .eq('company_id', currentProfile.company_id)
      .eq('foreman_id', currentProfile.id)
      .eq('status', 'draft')
      .not('review_notes', 'is', null)
      .order('reviewed_at', { ascending:false });

    if (error) {
      console.warn('Unable to check returned Daily Reports:', error.message);
      return [];
    }
    return (data || []).filter(report => String(report.review_notes || '').trim());
  }

  async function openReturnedReport(report) {
    const form = document.getElementById('dailyReportForm');
    if (!form) return;

    form.classList.remove('hidden');
    form.dataset.reportId = report.id;

    const setValue = (id, value) => {
      const el = document.getElementById(id);
      if (el) el.value = value ?? '';
    };

    setValue('dailyForemanName', report.foreman_name || currentProfile?.full_name || '');
    setValue('dailyWorkDate', report.work_date || '');
    setValue('dailyRegularHours', report.regular_hours || 0);
    setValue('dailyOvertimeHours', report.overtime_hours || 0);
    setValue('dailyCrewName', report.crew_name || '');
    setValue('dailyWeatherConditions', report.weather_conditions || '');
    setValue('dailyDelayHours', report.delay_hours || 0);
    setValue('dailyDelayReason', report.delay_reason || '');
    setValue('dailyNotes', report.notes || '');

    const saveBtn = document.getElementById('saveDailyReportBtn');
    if (saveBtn) saveBtn.textContent = 'Save & Continue to Units';

    const jobSelect = document.getElementById('dailyJobId');
    if (jobSelect) {
      jobSelect.innerHTML = '<option value="">Select active job</option>';
      const { data:jobs, error } = await sb
        .from('jobs')
        .select('id, job_number, job_name')
        .eq('company_id', currentProfile.company_id)
        .eq('active', true)
        .order('job_number', { ascending:true });

      if (error) {
        alert('The returned report is safe, but its job list could not be loaded: ' + error.message);
        return;
      }

      (jobs || []).forEach(job => {
        const option = document.createElement('option');
        option.value = job.id;
        option.textContent = (job.job_number || 'Job') + ' - ' + (job.job_name || 'Unnamed');
        option.selected = job.id === report.job_id;
        jobSelect.appendChild(option);
      });
    }

    form.scrollIntoView({ behavior:'smooth', block:'start' });
  }

  async function openReturnedUnits(report) {
    if (typeof openDailyUnitEditor !== 'function') {
      alert('Unit editor is still loading. Try again in a moment.');
      return;
    }

    const freshReportResult = await sb
      .from('daily_reports')
      .select(`id,job_id,work_date,status,review_notes,jobs(job_number,job_name)`)
      .eq('id', report.id)
      .eq('company_id', currentProfile.company_id)
      .eq('foreman_id', currentProfile.id)
      .single();

    if (freshReportResult.error) {
      alert('Unable to reload the returned report: ' + freshReportResult.error.message);
      return;
    }

    const savedResult = await sb.rpc('get_daily_report_unit_locations', {
      p_report_id: report.id
    });

    if (savedResult.error) {
      alert('Unable to reload the returned units: ' + savedResult.error.message);
      return;
    }

    if (!savedResult.data || savedResult.data.length === 0) {
      alert('No saved units are attached to this returned report. Do not re-enter them yet; contact the trial admin so the report can be checked.');
      return;
    }

    await openDailyUnitEditor(freshReportResult.data);

    setTimeout(() => {
      document.querySelectorAll('#dailyUnitList .daily-saved-pole').forEach(details => {
        details.open = true;
      });
      const firstQuantity = document.querySelector(
        '#dailyUnitList .daily-install-quantity, #dailyUnitList .daily-retirement-quantity'
      );
      firstQuantity?.scrollIntoView({ behavior:'smooth', block:'center' });
    }, 150);
  }

  async function resubmitReturnedReport(report, button) {
    const savedResult = await sb.rpc('get_daily_report_unit_locations', {
      p_report_id: report.id
    });
    if (savedResult.error) {
      alert('Unable to verify corrected units before resubmitting: ' + savedResult.error.message);
      return;
    }
    if (!savedResult.data || savedResult.data.length === 0) {
      alert('This report still has no saved units. Correct and save at least one unit before resubmitting.');
      return;
    }

    if (!confirm('Send this corrected Daily Report back to the General Foreman for review?')) return;

    button.disabled = true;
    button.textContent = 'Resubmitting...';
    const { error } = await sb.rpc('submit_daily_report', {
      p_report_id: report.id
    });
    button.disabled = false;
    button.textContent = 'Resubmit to GF';

    if (error) {
      alert('Unable to resubmit report: ' + error.message);
      return;
    }

    alert('Corrected Daily Report sent back to the General Foreman.');
    document.getElementById('dailyUnitEditor')?.classList.add('hidden');
    if (typeof loadProductionReports === 'function') await loadProductionReports();
    await refreshReturnedReports();
  }

  function showOneTimePopup(report) {
    const token = [report.id, report.reviewed_at || report.updated_at || '', report.review_notes || ''].join('|');
    const key = 'linecrew-return-seen:' + token;
    if (localStorage.getItem(key) === '1') return;
    localStorage.setItem(key, '1');

    const job = report.jobs?.job_number || 'Daily Report';
    alert(
      'REPORT RETURNED BY GENERAL FOREMAN\n\n' +
      job + ' has been returned for correction.\n\n' +
      'GF Note: ' + String(report.review_notes || 'No note provided') + '\n\n' +
      'Open Production and choose Correct Returned Units or Edit Report Details.'
    );
  }

  function renderReturnedNotice(reports) {
    const productionList = document.getElementById('productionList');
    if (!productionList?.parentElement) return;

    document.getElementById(RETURN_NOTICE_ID)?.remove();
    if (!reports.length) return;

    const wrap = document.createElement('div');
    wrap.id = RETURN_NOTICE_ID;
    wrap.className = 'card';
    wrap.style.border = '2px solid #d97706';
    wrap.style.background = '#fff7ed';

    const heading = document.createElement('h3');
    heading.textContent = reports.length === 1
      ? 'Daily Report Returned by GF'
      : reports.length + ' Daily Reports Returned by GF';
    wrap.appendChild(heading);

    reports.forEach(report => {
      const item = document.createElement('div');
      item.className = 'job-card';
      item.innerHTML =
        '<strong>' + esc(report.jobs?.job_number || 'Daily Report') + '</strong>' +
        (report.jobs?.job_name ? ' — ' + esc(report.jobs.job_name) : '') +
        '<br><span class="muted">Work date: ' + esc(report.work_date || '') + '</span>' +
        '<br><strong>GF Note:</strong> ' + esc(report.review_notes || 'No note provided');

      const units = document.createElement('button');
      units.className = 'warning small';
      units.textContent = 'Correct Returned Units';
      units.onclick = () => openReturnedUnits(report);
      item.appendChild(units);

      const edit = document.createElement('button');
      edit.className = 'secondary small';
      edit.textContent = 'Edit Report Details';
      edit.onclick = () => openReturnedReport(report);
      item.appendChild(edit);

      const resubmit = document.createElement('button');
      resubmit.className = 'success small';
      resubmit.textContent = 'Resubmit to GF';
      resubmit.onclick = () => resubmitReturnedReport(report, resubmit);
      item.appendChild(resubmit);

      wrap.appendChild(item);
    });

    productionList.parentElement.insertBefore(wrap, productionList);
  }

  async function refreshReturnedReports() {
    const reports = await getReturnedReports();
    renderReturnedNotice(reports);
    reports.forEach(showOneTimePopup);
  }

  const productionTile = document.getElementById('productionTile');
  productionTile?.addEventListener('click', () => setTimeout(refreshReturnedReports, 300));

  [1500, 3500, 7000].forEach(delay => setTimeout(refreshReturnedReports, delay));
  setInterval(refreshReturnedReports, 10000);
})();
