/* LineCrew Pro - JSA signature layout compatibility */
(() => {
  'use strict';
  if (document.getElementById('lcSignatureLayoutCompat')) return;
  const style = document.createElement('style');
  style.id = 'lcSignatureLayoutCompat';
  style.textContent = `
    .lc-crew-row > label:first-child { grid-column: 1 !important; }
    .lc-crew-row > label:nth-child(2) { grid-column: 2 !important; }
    .lc-crew-row > .lc-signature-cell { grid-column: 2 !important; }
    .lc-crew-row > .lc-signature-wrap { grid-column: 2 !important; width: 100%; margin-top: 0; }
    @media (max-width: 720px) {
      .lc-crew-row > label:first-child,
      .lc-crew-row > label:nth-child(2),
      .lc-crew-row > .lc-signature-cell,
      .lc-crew-row > .lc-signature-wrap { grid-column: 1 !important; }
    }
  `;
  document.head.appendChild(style);
})();
