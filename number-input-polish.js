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
