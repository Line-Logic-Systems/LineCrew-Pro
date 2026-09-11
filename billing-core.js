/* LineCrew Pro — Billing core helpers.
 * Staged extraction from index.html. Keep helpers pure and side-effect free.
 */
(() => {
  'use strict';

  function billingStatusLabel(status){
    return String(status || 'draft').replaceAll('_',' ').toUpperCase();
  }

  const api = Object.freeze({ billingStatusLabel });
  window.LineCrewBillingCore = api;

  // Compatibility bridge while the legacy inline copy remains available.
  window.billingStatusLabel = billingStatusLabel;
})();
