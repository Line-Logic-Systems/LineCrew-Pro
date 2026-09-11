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

  function dailyQuantityText(value){
    const quantity = Number(value || 0);
    if(!Number.isFinite(quantity)) return '0';
    return Number.isInteger(quantity)
      ? String(quantity)
      : quantity.toFixed(2).replace(/0+$/, '').replace(/\.$/, '');
  }

  const api = Object.freeze({ workTypeLabel, safeStorageFilename, dailyQuantityText });
  window.LineCrewDailyReportCore = api;

  // Compatibility bridges while the legacy inline copies still exist.
  window.dailyUnitWorkTypeLabel = workTypeLabel;
  window.safeStorageFilename = safeStorageFilename;
  window.dailyQuantityText = dailyQuantityText;
})();
