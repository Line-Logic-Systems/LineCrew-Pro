/* LineCrew Pro — Production core helpers.
 * Staged extraction from index.html. Keep helpers pure and side-effect free.
 */
(() => {
  'use strict';

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

  const api = Object.freeze({
    reportUtilityKey,
    groupReportsByContractJob,
    groupReportsByUtility,
    reportingTotals
  });
  window.LineCrewProductionCore = api;

  // Compatibility bridges while the legacy inline behavior remains available.
  window.productionReportUtilityKey = reportUtilityKey;
  window.productionGroupReportsByContractJob = groupReportsByContractJob;
  window.productionGroupReportsByUtility = groupReportsByUtility;
  window.productionReportingTotalsCore = reportingTotals;
})();
