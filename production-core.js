/* LineCrew Pro — Production core helpers.
 * Staged extraction from index.html. Keep helpers pure and side-effect free.
 */
(() => {
  'use strict';

  function reportUtilityKey(report) {
    return String(report?.jobs?.contracts?.customers?.id || 'unassigned');
  }

  const api = Object.freeze({ reportUtilityKey });
  window.LineCrewProductionCore = api;

  // Compatibility bridge while the legacy inline copy still exists.
  // Existing callers keep using the same public function name.
  window.productionReportUtilityKey = reportUtilityKey;
})();
