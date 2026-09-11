/* LineCrew Pro — Daily Report core helpers.
 * Staged extraction from index.html. Keep helpers pure and side-effect free.
 */
(() => {
  'use strict';

  function workTypeLabel(workType) {
    if (workType === 'retirement') return 'Remove / Retirement';
    if (workType === 'transfer') return 'Transfer';
    return 'Install';
  }

  function safeStorageFilename(filename) {
    const parts = String(filename || 'attachment').split('.');
    const extension = parts.length > 1
      ? '.' + parts.pop().replace(/[^a-z0-9]/gi, '').slice(0, 12).toLowerCase()
      : '';
    const base = parts.join('.')
      .replace(/[^a-z0-9_-]+/gi, '-')
      .replace(/^-+|-+$/g, '')
      .slice(0, 80) || 'attachment';
    return base + extension;
  }

  const api = Object.freeze({ workTypeLabel, safeStorageFilename });
  window.LineCrewDailyReportCore = api;

  // Compatibility bridges while the legacy inline copies still exist.
  // Existing callers keep using the same public function names.
  window.dailyUnitWorkTypeLabel = workTypeLabel;
  window.safeStorageFilename = safeStorageFilename;
})();
