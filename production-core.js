/* LineCrew Pro — Production core helpers.
 * Staged extraction from index.html. Keep helpers pure and side-effect free.
 */
(() => {
  'use strict';

  const legacyProductionReportingTotals =
    typeof window.productionReportingTotals === 'function'
      ? window.productionReportingTotals
      : null;
  const legacyProductionUtilityPrimaryMetricsMarkup =
    typeof window.productionUtilityPrimaryMetricsMarkup === 'function'
      ? window.productionUtilityPrimaryMetricsMarkup
      : null;

  function reportUtilityKey(report) {
    return String(report?.jobs?.contracts?.customers?.id || 'unassigned');
  }

  function groupReportsByContractJob(reports) {
    const contracts = new Map();
    (reports || []).forEach(report => {
      const contract = report?.jobs?.contracts || {};
      const contractKey = String(contract.id || 'no-contract');
      if (!contracts.has(contractKey)) {
        contracts.set(contractKey, {
          id: contractKey,
          label: [contract.contract_number, contract.contract_name].filter(Boolean).join(' — ') || 'No Contract Assigned',
          reports: [],
          jobs: new Map()
        });
      }
      const contractGroup = contracts.get(contractKey);
      contractGroup.reports.push(report);
      const jobKey = String(report?.job_id || 'no-job');
      if (!contractGroup.jobs.has(jobKey)) {
        contractGroup.jobs.set(jobKey, {
          id: jobKey,
          label: [report?.jobs?.job_number, report?.jobs?.job_name].filter(Boolean).join(' — ') || 'No Job Assigned',
          reports: []
        });
      }
      contractGroup.jobs.get(jobKey).reports.push(report);
    });

    return [...contracts.values()]
      .sort((a, b) => a.label.localeCompare(b.label))
      .map(contract => ({
        id: contract.id,
        label: contract.label,
        reports: contract.reports,
        jobs: [...contract.jobs.values()].sort((a, b) => a.label.localeCompare(b.label))
      }));
  }

  function groupReportsByUtility(reports) {
    const utilities = new Map();
    (reports || [])
      .filter(report => report?.archived !== true)
      .forEach(report => {
        const utility = report?.jobs?.contracts?.customers || {};
        const key = reportUtilityKey(report);
        if (!utilities.has(key)) {
          utilities.set(key, {
            id: key,
            name: String(utility.name || 'No Utility / Cooperative Assigned'),
            reports: []
          });
        }
        utilities.get(key).reports.push(report);
      });

    return [...utilities.values()].sort((a, b) => a.name.localeCompare(b.name));
  }

  function reportingTotals(reports, valueSummaries = new Map(), authorizationSummaries = new Map()) {
    const list = Array.isArray(reports) ? reports : [];
    const totals = {
      reports: list.length,
      approved: 0,
      actualValue: 0,
      fieldValue: 0,
      regularHours: 0,
      overtimeHours: 0,
      redlines: 0,
      pending: 0
    };

    list.forEach(report => {
      const value = valueSummaries?.get?.(report?.id) || {};
      const authorization = authorizationSummaries?.get?.(report?.id) || {};
      totals.actualValue += Number(value.actual_total || 0);
      totals.fieldValue += Number(value.adjusted_total || 0);
      totals.regularHours += Number(report?.regular_hours || 0);
      totals.overtimeHours += Number(report?.overtime_hours || 0);
      totals.redlines += Number(authorization.redline_count || 0);
      totals.pending += Number(authorization.pending_packet_count || 0);
      if (String(report?.status || '').toLowerCase() === 'approved') totals.approved += 1;
    });

    return totals;
  }

  function utilityPrimaryMetrics(
    reports,
    valueSummaries = new Map(),
    authorizationSummaries = new Map(),
    options = {}
  ) {
    const list = Array.isArray(reports) ? reports : [];
    const totals = reportingTotals(list, valueSummaries, authorizationSummaries);
    const approvedReports = list.filter(
      report => String(report?.status || '').toLowerCase() === 'approved'
    );
    const approvedTotals = reportingTotals(
      approvedReports,
      valueSummaries,
      authorizationSummaries
    );
    const awaitingReview = list.filter(
      report => report?.archived !== true &&
        String(report?.status || '').toLowerCase() === 'submitted'
    ).length;
    const showActual = options?.showActual === true;
    const showField = options?.showField === true;
    const showMoney = showActual || showField;
    const approvedValue = showActual
      ? approvedTotals.actualValue
      : approvedTotals.fieldValue;
    const totalValue = showActual ? totals.actualValue : totals.fieldValue;
    const hours = totals.regularHours + totals.overtimeHours;
    const runRate = hours ? totalValue / hours : 0;
    const activeJobCount = new Set(
      list
        .filter(report => report?.jobs?.active === true)
        .map(report => String(report?.job_id || ''))
        .filter(Boolean)
    ).size;

    return {
      awaitingReview,
      approvedValue,
      totalValue,
      hours,
      runRate,
      activeJobCount,
      approvedReports: approvedTotals.approved,
      showActual,
      showField,
      showMoney
    };
  }

  function utilityPrimaryMetricsMarkup(
    reports,
    valueSummaries = new Map(),
    authorizationSummaries = new Map(),
    options = {},
    helpers = {}
  ) {
    const metrics = utilityPrimaryMetrics(
      reports,
      valueSummaries,
      authorizationSummaries,
      options
    );
    const formatMoney = typeof helpers.formatCurrency === 'function'
      ? helpers.formatCurrency
      : value => String(value);
    const escape = typeof helpers.escapeHtml === 'function'
      ? helpers.escapeHtml
      : value => String(value);

    return '<div class="production-utility-primary-metrics">' +
      '<span><strong>' + metrics.awaitingReview + '</strong>Awaiting Review</span>' +
      '<span><strong>' + (
        metrics.showMoney
          ? escape(formatMoney(metrics.approvedValue))
          : metrics.approvedReports
      ) + '</strong>' + (
        metrics.showMoney ? 'Approved Production' : 'Approved Reports'
      ) + '</span>' +
      '<span><strong>' + metrics.activeJobCount + '</strong>Active Jobs</span>' +
      '<span><strong>' + (
        metrics.showMoney
          ? escape(formatMoney(metrics.runRate))
          : '—'
      ) + '</strong>' + (
        metrics.showActual ? 'Actual' : 'Field'
      ) + ' MH Rate</span>' +
      '</div>';
  }

  function runtimeReportingTotals(reports) {
    try {
      if (
        typeof currentDailyReportValueSummaries !== 'undefined' &&
        typeof currentDailyAuthorizationSummaries !== 'undefined'
      ) {
        return reportingTotals(
          reports,
          currentDailyReportValueSummaries,
          currentDailyAuthorizationSummaries
        );
      }
    } catch (error) {
      // Fall through to the captured inline implementation.
    }

    if (legacyProductionReportingTotals) {
      return legacyProductionReportingTotals(reports);
    }
    return reportingTotals(reports);
  }

  function runtimeUtilityPrimaryMetricsMarkup(reports) {
    try {
      if (
        typeof currentDailyReportValueSummaries !== 'undefined' &&
        typeof currentDailyAuthorizationSummaries !== 'undefined' &&
        typeof userCanSeeActualContractPrices === 'function' &&
        typeof userCanSeeFieldMoney === 'function' &&
        typeof formatCurrency === 'function' &&
        typeof escapeHtml === 'function'
      ) {
        return utilityPrimaryMetricsMarkup(
          reports,
          currentDailyReportValueSummaries,
          currentDailyAuthorizationSummaries,
          {
            showActual: userCanSeeActualContractPrices(),
            showField: userCanSeeFieldMoney()
          },
          { formatCurrency, escapeHtml }
        );
      }
    } catch (error) {
      // Fall through to the captured inline implementation.
    }

    if (legacyProductionUtilityPrimaryMetricsMarkup) {
      return legacyProductionUtilityPrimaryMetricsMarkup(reports);
    }
    return utilityPrimaryMetricsMarkup(reports);
  }

  const api = Object.freeze({
    reportUtilityKey,
    groupReportsByContractJob,
    groupReportsByUtility,
    reportingTotals,
    utilityPrimaryMetrics,
    utilityPrimaryMetricsMarkup,
    runtimeReportingTotals,
    runtimeUtilityPrimaryMetricsMarkup
  });
  window.LineCrewProductionCore = api;

  // Compatibility bridges while the legacy inline behavior remains available.
  window.productionReportUtilityKey = reportUtilityKey;
  window.productionGroupReportsByContractJob = groupReportsByContractJob;
  window.productionGroupReportsByUtility = groupReportsByUtility;
  window.productionReportingTotalsCore = reportingTotals;
  window.productionUtilityPrimaryMetricsCore = utilityPrimaryMetrics;
  window.productionUtilityPrimaryMetricsMarkupCore = utilityPrimaryMetricsMarkup;
  window.productionReportingTotals = runtimeReportingTotals;
  window.productionUtilityPrimaryMetricsMarkup = runtimeUtilityPrimaryMetricsMarkup;
})();
