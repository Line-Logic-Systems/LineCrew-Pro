/* LineCrew Pro — Daily Report core helpers.
 * First staged extraction from index.html. Keep helpers pure and side-effect free.
 */
(() => {
  'use strict';

  function workTypeLabel(workType) {
    if (workType === 'retirement') return 'Remove / Retirement';
    if (workType === 'transfer') return 'Transfer';
    return 'Install';
  }

  const api = Object.freeze({ workTypeLabel });
  window.LineCrewDailyReportCore = api;

  // Compatibility bridge while the legacy inline copy still exists.
  // Existing callers keep using the same public function name.
  window.dailyUnitWorkTypeLabel = workTypeLabel;
})();
