/* LineCrew Pro — Price Book core helpers.
 * Staged extraction from index.html. Keep helpers pure and side-effect free.
 */
(() => {
  'use strict';

  function normalizeImportHeader(value) {
    return String(value || '')
      .trim()
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, '');
  }

  function normalizedPriceWorkType(value, itemCode = '') {
    const workType = normalizeImportHeader(value);
    if (/^(transfer|xfer|move|reframe|relocate)/.test(workType)) return 'transfer';
    if (/^(remove|removal|retire|retirement|demo|salvage)/.test(workType)) return 'retirement';
    if (/^(install|installation|new|construct|construction|set)/.test(workType)) return 'install';
    const suffixMatch = String(itemCode || '').trim().toUpperCase().match(/[0-9]([IRT])$/);
    const suffix = suffixMatch ? suffixMatch[1] : '';
    if (suffix === 'T') return 'transfer';
    if (suffix === 'R') return 'retirement';
    if (suffix === 'I') return 'install';
    return workType ? 'unknown' : '';
  }

  const api = Object.freeze({ normalizeImportHeader, normalizedPriceWorkType });
  window.LineCrewPriceBookCore = api;

  // Compatibility bridges while the legacy inline copies still exist.
  window.normalizeImportHeader = normalizeImportHeader;
  window.normalizedPriceWorkType = normalizedPriceWorkType;
})();
