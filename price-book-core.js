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

  function importEditDistance(left, right) {
    const a = String(left || '');
    const b = String(right || '');
    const row = Array.from({ length:b.length + 1 }, (_, index) => index);
    for (let i = 1; i <= a.length; i++) {
      let previous = row[0];
      row[0] = i;
      for (let j = 1; j <= b.length; j++) {
        const held = row[j];
        row[j] = Math.min(
          row[j] + 1,
          row[j - 1] + 1,
          previous + (a[i - 1] === b[j - 1] ? 0 : 1)
        );
        previous = held;
      }
    }
    return row[b.length];
  }

  function importHeaderMatchConfidence(value, aliases) {
    const normalized = normalizeImportHeader(value);
    if (!normalized) return 0;
    if (aliases.includes(normalized)) return 1;
    if (aliases.some(alias =>
      alias.length >= 5 &&
      (normalized.includes(alias) || (normalized.length >= 6 && alias.includes(normalized)))
    )) return .92;
    if (normalized.length >= 5 && aliases.some(alias =>
      alias.length >= 5 && importEditDistance(normalized, alias) === 1
    )) return .82;
    return 0;
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

  const api = Object.freeze({
    normalizeImportHeader,
    importEditDistance,
    importHeaderMatchConfidence,
    normalizedPriceWorkType
  });
  window.LineCrewPriceBookCore = api;

  // Compatibility bridges while the legacy inline copies still exist.
  window.normalizeImportHeader = normalizeImportHeader;
  window.importEditDistance = importEditDistance;
  window.importHeaderMatchConfidence = importHeaderMatchConfidence;
  window.normalizedPriceWorkType = normalizedPriceWorkType;
})();
