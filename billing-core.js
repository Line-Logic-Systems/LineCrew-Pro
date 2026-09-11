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

  function completeBillingSafeName(value,fallback='record'){
    return String(value || fallback).replace(/[^a-z0-9._-]+/gi,'-').replace(/^-+|-+$/g,'').slice(0,110) || fallback;
  }

  function billingSafeStorageFilename(filename){
    const parts=String(filename || 'billing-attachment').split('.');
    const extension=parts.length>1
      ? '.'+parts.pop().replace(/[^a-z0-9]/gi,'').slice(0,12).toLowerCase()
      : '';
    const base=parts.join('.')
      .replace(/[^a-z0-9_-]+/gi,'-')
      .replace(/^-+|-+$/g,'')
      .slice(0,80) || 'billing-attachment';
    return base+extension;
  }

  const api = Object.freeze({ billingStatusLabel, billingStageLabel, completeBillingSafeName, billingSafeStorageFilename });
  window.LineCrewBillingCore = api;

  // Compatibility bridges while the legacy inline copies remain available.
  window.billingStatusLabel = billingStatusLabel;
  window.billingStageLabel = billingStageLabel;
  window.completeBillingSafeName = completeBillingSafeName;
  window.billingSafeStorageFilename = billingSafeStorageFilename;
})();
