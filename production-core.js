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

  const api = Object.freeze({ reportUtilityKey, groupReportsByContractJob });
  window.LineCrewProductionCore = api;

  // Compatibility bridge while the legacy inline copy still exists.
  window.productionReportUtilityKey = reportUtilityKey;
  window.productionGroupReportsByContractJob = groupReportsByContractJob;
})();
