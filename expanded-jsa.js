/* LineCrew Pro recovery guard + expanded JSA loader */
(() => {
  'use strict';

  const isRecoveryUrl = () => {
    const text = (window.location.search || '') + '&' + (window.location.hash || '');
    return /(?:^|[&#?])type=recovery(?:&|$)/i.test(text) || /password_recovery/i.test(text);
  };

  const forceRecoveryUi = () => {
    const authPage = document.getElementById('authPage');
    const setupPage = document.getElementById('setupPage');
    const dashboardPage = document.getElementById('dashboardPage');
    const teamPage = document.getElementById('teamPage');
    const jobsPage = document.getElementById('jobsPage');
    const productionPage = document.getElementById('productionPage');
    const safetyPage = document.getElementById('safetyPage');
    const priceBooksPage = document.getElementById('priceBooksPage');
    const recoveryCard = document.getElementById('passwordRecoveryCard');
    const recoveryPassword = document.getElementById('recoveryPassword');

    [setupPage, dashboardPage, teamPage, jobsPage, productionPage, safetyPage, priceBooksPage]
      .forEach((el) => el?.classList.add('hidden'));
    authPage?.classList.remove('hidden');
    recoveryCard?.classList.remove('hidden');
    setTimeout(() => recoveryPassword?.focus(), 0);
  };

  const markRecovery = () => {
    sessionStorage.setItem('linecrew-password-recovery', '1');
    forceRecoveryUi();
    [0, 50, 150, 400, 900].forEach((delay) => setTimeout(forceRecoveryUi, delay));
  };

  if (isRecoveryUrl()) markRecovery();
  if (sessionStorage.getItem('linecrew-password-recovery') === '1') forceRecoveryUi();

  if (window.sb?.auth?.onAuthStateChange) {
    window.sb.auth.onAuthStateChange((event) => {
      if (event === 'PASSWORD_RECOVERY') {
        markRecovery();
        return;
      }
      if (event === 'USER_UPDATED' && sessionStorage.getItem('linecrew-password-recovery') === '1') {
        sessionStorage.removeItem('linecrew-password-recovery');
      }
    });
  }

  const saveButton = document.getElementById('saveRecoveryPassword');
  if (saveButton) {
    saveButton.addEventListener('click', () => {
      setTimeout(() => {
        const card = document.getElementById('passwordRecoveryCard');
        if (card?.classList.contains('hidden')) {
          sessionStorage.removeItem('linecrew-password-recovery');
        }
      }, 1200);
    });
  }

  const productionTile = document.getElementById('productionTile');
  const productionDescription = productionTile?.querySelector('.muted');
  if (productionDescription) {
    productionDescription.textContent = 'Daily production reporting and review';
  }

  const load = (src, onload) => {
    const script = document.createElement('script');
    script.src = src;
    script.defer = false;
    if (onload) script.onload = onload;
    document.head.appendChild(script);
  };

  load('app-polish.js?v=20260820');
  load('expanded-jsa-core.js?v=20260820', () => load('jsa-signatures.js?v=20260820c'));
  load('timekeeping.js?v=20260820', () => {
    load('timekeeping-roster.js?v=20260820b');
    load('timekeeping-report-v2.js?v=20260820');
  });
})();
