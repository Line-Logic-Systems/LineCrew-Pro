/* LineCrew Pro - zero-first numeric input behavior */
(() => {
  'use strict';

  const isEditableNumber = (element) =>
    element instanceof HTMLInputElement &&
    element.type === 'number' &&
    !element.disabled &&
    !element.readOnly;

  const hasZeroDefault = (input) =>
    input.dataset.linecrewZeroDefault === 'true' ||
    input.defaultValue === '0' ||
    input.getAttribute('value') === '0';

  const selectDisplayedZero = (input) => {
    if(!isEditableNumber(input) || Number(input.value) !== 0 || input.value === '') return;
    input.dataset.linecrewZeroDefault = 'true';
    requestAnimationFrame(() => {
      if(document.activeElement === input) input.select();
    });
  };

  document.addEventListener('focusin', (event) => {
    selectDisplayedZero(event.target);
  });

  document.addEventListener('pointerup', (event) => {
    const input = event.target;
    if(!isEditableNumber(input) || Number(input.value) !== 0 || input.value === '') return;
    event.preventDefault();
    selectDisplayedZero(input);
  });

  document.addEventListener('focusout', (event) => {
    const input = event.target;
    if(!isEditableNumber(input) || input.value !== '' || !hasZeroDefault(input)) return;
    input.value = '0';
    input.dispatchEvent(new Event('input', { bubbles:true }));
    input.dispatchEvent(new Event('change', { bubbles:true }));
  });
})();

/* F1 payroll-data safety guard.
 * timekeeping.js historically filtered invalid/duplicate crew rows out of the
 * snapshot and then deleted saved rows that were absent from that snapshot.
 * Validate the visible crew grid before the existing save function can run so
 * a typo can never turn into a destructive delete.
 */
(() => {
  'use strict';

  const validationError = () => {
    const rows = Array.from(document.querySelectorAll('#dailyCrewTimeRows .tk-crew-row'));
    const crewBox = document.querySelector('#dailyCrewTimeRows');
    if(crewBox?.dataset?.loading === 'true'){
      return 'Crew Time is still loading. Wait for the crew rows to appear before saving.';
    }
    if(rows.length === 0){
      return 'Crew Time did not load. Reload the crew rows before saving so existing time is not removed.';
    }
    const seen = new Set();
    for(const row of rows){
      const employeeId = String(row.querySelector('.tk-employee')?.value || '').trim();
      if(!employeeId) return 'Select an employee for every Crew Time row, or remove the blank row before saving.';
      if(seen.has(employeeId)) return 'Each employee can appear only once in Crew Time. Remove the duplicate row before saving.';
      seen.add(employeeId);
      const regular = Number(row.querySelector('.tk-regular')?.value || 0);
      const overtime = Number(row.querySelector('.tk-ot')?.value || 0);
      if(!Number.isFinite(regular) || !Number.isFinite(overtime)){
        return 'Crew Time hours must be valid numbers before saving.';
      }
      if(regular < 0 || overtime < 0 || regular + overtime > 24){
        return 'Crew Time cannot be negative or exceed 24 total hours for one employee in one day.';
      }
    }
    return '';
  };

  const wrapSave = (save) => {
    if(typeof save !== 'function' || save.__lineCrewCrewTimeValidated) return save;
    const guarded = async (...args) => {
      const error = validationError();
      if(error) throw new Error(error);
      return save(...args);
    };
    guarded.__lineCrewCrewTimeValidated = true;
    return guarded;
  };

  const existing = window.saveDailyReportCrewTime;
  if(typeof existing === 'function'){
    window.saveDailyReportCrewTime = wrapSave(existing);
    return;
  }

  let pending;
  Object.defineProperty(window, 'saveDailyReportCrewTime', {
    configurable:true,
    get(){ return pending; },
    set(value){
      pending = wrapSave(value);
      Object.defineProperty(window, 'saveDailyReportCrewTime', {
        configurable:true,
        writable:true,
        value:pending
      });
    }
  });
})();

/* Staged App Core modularization bootstrap.
 * Legacy inline helpers remain the fallback if this module cannot load.
 */
(() => {
  if (window.LineCrewAppCore || document.querySelector('script[data-linecrew-app-core]')) return;
  const script = document.createElement('script');
  script.src = '/app-core.js?v=20260910a';
  script.async = false;
  script.dataset.linecrewAppCore = '1';
  script.onerror = () => console.warn('App core module unavailable; using inline compatibility fallback.');
  document.head.appendChild(script);
})();

/* Staged Jobs Core modularization bootstrap.
 * The legacy inline helper remains the fallback if this module cannot load.
 */
(() => {
  if (window.LineCrewJobsCore || document.querySelector('script[data-linecrew-jobs-core]')) return;
  const script = document.createElement('script');
  script.src = '/jobs-core.js?v=20260910a';
  script.async = false;
  script.dataset.linecrewJobsCore = '1';
  script.onerror = () => console.warn('Jobs core module unavailable; using inline compatibility fallback.');
  document.head.appendChild(script);
})();

/* Staged Completed Jobs modularization bootstrap.
 * The live inline archive renderer remains the fallback if this module cannot load.
 */
(() => {
  if (window.LineCrewCompletedJobsCore || document.querySelector('script[data-linecrew-completed-jobs-core]')) return;
  const script = document.createElement('script');
  script.src = '/completed-jobs-core.js?v=20260911a';
  script.async = false;
  script.dataset.linecrewCompletedJobsCore = '1';
  script.onerror = () => console.warn('Completed Jobs core module unavailable; using inline compatibility fallback.');
  document.head.appendChild(script);
})();

/* Staged Assistant Core modularization bootstrap.
 * The legacy inline helper remains the fallback if this module cannot load.
 */
(() => {
  if (window.LineCrewAssistantCore || document.querySelector('script[data-linecrew-assistant-core]')) return;
  const script = document.createElement('script');
  script.src = '/assistant-core.js?v=20260910a';
  script.async = false;
  script.dataset.linecrewAssistantCore = '1';
  script.onerror = () => console.warn('Assistant core module unavailable; using inline compatibility fallback.');
  document.head.appendChild(script);
})();

/* Staged Billing Core modularization bootstrap.
 * The legacy inline helper remains the fallback if this module cannot load.
 */
(() => {
  if (window.LineCrewBillingCore || document.querySelector('script[data-linecrew-billing-core]')) return;
  const script = document.createElement('script');
  script.src = '/billing-core.js?v=20260910a';
  script.async = false;
  script.dataset.linecrewBillingCore = '1';
  script.onerror = () => console.warn('Billing core module unavailable; using inline compatibility fallback.');
  document.head.appendChild(script);
})();

/* Staged Notifications Core modularization bootstrap.
 * The legacy inline helper remains the fallback if this module cannot load.
 */
(() => {
  if (window.LineCrewNotificationsCore || document.querySelector('script[data-linecrew-notifications-core]')) return;
  const script = document.createElement('script');
  script.src = '/notifications-core.js?v=20260910a';
  script.async = false;
  script.dataset.linecrewNotificationsCore = '1';
  script.onerror = () => console.warn('Notifications core module unavailable; using inline compatibility fallback.');
  document.head.appendChild(script);
})();

/* Staged Daily Report modularization bootstrap.
 * The legacy inline helper remains the fallback if this module cannot load.
 */
(() => {
  if (window.LineCrewDailyReportCore || document.querySelector('script[data-linecrew-daily-report-core]')) return;
  const script = document.createElement('script');
  script.src = '/daily-report-core.js?v=20260910a';
  script.async = false;
  script.dataset.linecrewDailyReportCore = '1';
  script.onerror = () => console.warn('Daily Report core module unavailable; using inline compatibility fallback.');
  document.head.appendChild(script);
})();

/* Staged Production modularization bootstrap.
 * The legacy inline helper remains the fallback if this module cannot load.
 */
(() => {
  if (window.LineCrewProductionCore || document.querySelector('script[data-linecrew-production-core]')) return;
  const script = document.createElement('script');
  script.src = '/production-core.js?v=20260910a';
  script.async = false;
  script.dataset.linecrewProductionCore = '1';
  script.onerror = () => console.warn('Production core module unavailable; using inline compatibility fallback.');
  document.head.appendChild(script);
})();

/* Staged Price Book modularization bootstrap.
 * The legacy inline helpers remain the fallback if this module cannot load.
 */
(() => {
  if (window.LineCrewPriceBookCore || document.querySelector('script[data-linecrew-price-book-core]')) return;
  const script = document.createElement('script');
  script.src = '/price-book-core.js?v=20260910a';
  script.async = false;
  script.dataset.linecrewPriceBookCore = '1';
  script.onerror = () => console.warn('Price Book core module unavailable; using inline compatibility fallback.');
  document.head.appendChild(script);
})();
