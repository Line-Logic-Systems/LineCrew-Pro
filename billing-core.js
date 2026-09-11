/* LineCrew Pro — Billing core helpers.
 * Staged extraction from index.html. Keep helpers pure and side-effect free.
 */
(() => {
  'use strict';

  function billingStatusLabel(status){
    return String(status || 'draft').replaceAll('_',' ').toUpperCase();
  }

  function billingStageLabel(batch){
    if(String(batch?.billing_type || '').toLowerCase() === 'credit') return 'Billing Adjustment';
    if(String(batch?.billing_type || 'partial').toLowerCase() === 'final') return 'Final Bill';
    return 'Partial Bill ' + Number(batch?.billing_sequence || 1);
  }

  const api = Object.freeze({ billingStatusLabel, billingStageLabel });
  window.LineCrewBillingCore = api;

  // Compatibility bridges while the legacy inline copies remain available.
  window.billingStatusLabel = billingStatusLabel;
  window.billingStageLabel = billingStageLabel;
})();
