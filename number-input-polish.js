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

/* Staged App Core modularization bootstrap.
 * Legacy inline helpers remain the fallback if this module cannot load.
 */
(() => {
  if (window.LineCrewAppCore || document.querySelector('script[data-linecrew-app-core]')) return;
  const script = document.createElement('script');
  script.src = '/app-core.js?v=20260910a';
  script.defer = false;
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
  script.defer = false;
  script.dataset.linecrewJobsCore = '1';
  script.onerror = () => console.warn('Jobs core module unavailable; using inline compatibility fallback.');
  document.head.appendChild(script);
})();

/* Staged Daily Report modularization bootstrap.
 * The legacy inline helper remains the fallback if this module cannot load.
 */
(() => {
  if (window.LineCrewDailyReportCore || document.querySelector('script[data-linecrew-daily-report-core]')) return;
  const script = document.createElement('script');
  script.src = '/daily-report-core.js?v=20260910a';
  script.defer = false;
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
  script.defer = false;
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
  script.defer = false;
  script.dataset.linecrewPriceBookCore = '1';
  script.onerror = () => console.warn('Price Book core module unavailable; using inline compatibility fallback.');
  document.head.appendChild(script);
})();
