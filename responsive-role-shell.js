/* LineCrew Pro — responsive, permission-preserving navigation shell. */
(() => {
  'use strict';

  const byId = id => document.getElementById(id);
  const desktopQuery = window.matchMedia('(min-width: 1100px) and (pointer: fine)');
  const pageToTile = {
    dashboardPage: 'dashboard',
    jobsPage: 'jobsTile',
    completedJobsPage: 'completedJobsTile',
    productionPage: 'productionTile',
    safetyPage: 'safetyTile',
    priceBooksPage: 'priceBooksTile',
    teamPage: 'teamTile',
    utilityPortalPage: 'utilityPortalTile',
    remainingUnitsPage: 'remainingUnitsTile',
    timekeepingPage: 'timekeepingTile'
  };
  const iconPaths = {
    dashboard: '<path d="M3 11.5 12 4l9 7.5"/><path d="M5 10.5V20h14v-9.5"/><path d="M9 20v-6h6v6"/>',
    jobsTile: '<path d="M4 7h16v13H4z"/><path d="M8 7V4h8v3"/><path d="M4 12h16"/>',
    completedJobsTile: '<path d="M6 3h9l4 4v14H6z"/><path d="M15 3v5h5"/><path d="m9 14 2 2 4-4"/>',
    productionTile: '<path d="M4 20V10"/><path d="M10 20V4"/><path d="M16 20v-7"/><path d="M22 20H2"/>',
    safetyTile: '<path d="M12 3 4.5 6v5.5c0 4.7 3.1 8 7.5 9.5 4.4-1.5 7.5-4.8 7.5-9.5V6z"/><path d="m8.5 12 2.2 2.2 4.8-5"/>',
    priceBooksTile: '<path d="M4 5.5A2.5 2.5 0 0 1 6.5 3H20v15H6.5A2.5 2.5 0 0 0 4 20.5z"/><path d="M4 5.5v15"/>',
    teamTile: '<path d="M16 20v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2"/><circle cx="9" cy="7" r="4"/><path d="M22 20v-2a4 4 0 0 0-3-3.87"/><path d="M16 3.13a4 4 0 0 1 0 7.75"/>',
    timekeepingTile: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
    remainingUnitsTile: '<path d="M4 5h16v14H4z"/><path d="M8 9h8M8 13h5"/>',
    trainingTile: '<path d="m3 10 9-5 9 5-9 5z"/><path d="M7 12.5V17c3 2 7 2 10 0v-4.5"/>',
    billingTile: '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M3 10h18M7 15h4"/>',
    assistantMemoryTile: '<path d="M5 4h11a3 3 0 0 1 3 3v13l-4-3H5z"/><path d="M9 8h6M9 12h4"/>',
    utilityPortalTile: '<circle cx="12" cy="5" r="2"/><circle cx="5" cy="18" r="2"/><circle cx="19" cy="18" r="2"/><path d="m11 7-5 9M13 7l5 9M7 18h10"/>',
    signOut: '<path d="M10 5H5v14h5"/><path d="m15 8 4 4-4 4M19 12H9"/>'
  };

  let sidebar;
  let nav;
  let observer;
  let syncQueued = false;

  function setText(element, value) {
    if (element && element.textContent !== value) element.textContent = value;
  }

  function observe() {
    observer?.observe(document.body, {
      subtree: true,
      childList: true,
      characterData: true,
      attributes: true,
      attributeFilter: ['class']
    });
  }

  function svgFor(key) {
    const paths = iconPaths[key] || iconPaths.jobsTile;
    return `<svg viewBox="0 0 24 24" fill="none" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${paths}</svg>`;
  }

  function currentRole() {
    try {
      return String(currentProfile?.role || window.currentProfile?.role || '');
    } catch (_) {
      return String(window.currentProfile?.role || '');
    }
  }

  function roleLabel(value) {
    return ({ owner: 'Owner', admin: 'Admin', superintendent: 'Superintendent', gf: 'General Foreman', foreman: 'Foreman' })[value] || value || 'Team Member';
  }

  function signedInProfile() {
    try {
      return currentProfile || window.currentProfile || null;
    } catch (_) {
      return window.currentProfile || null;
    }
  }

  function visibleSectionId() {
    return [...document.querySelectorAll('main > section')]
      .find(section => !section.classList.contains('hidden'))?.id || '';
  }

  function eligibleForShell() {
    const page = visibleSectionId();
    return Boolean(
      desktopQuery.matches &&
      signedInProfile() &&
      page &&
      !['authPage', 'mfaPage', 'setupPage', 'utilityViewerPage'].includes(page)
    );
  }

  function createItem(key, label, action) {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'lc-role-sidebar__item';
    button.dataset.shellTarget = key;
    button.setAttribute('aria-label', label);
    button.innerHTML = svgFor(key);
    const text = document.createElement('span');
    text.textContent = label;
    button.appendChild(text);
    button.addEventListener('click', action);
    return button;
  }

  function enhanceDesktopChrome() {
    let account = byId('lcShellAccount');
    if (!account) {
      account = document.createElement('div');
      account.id = 'lcShellAccount';
      account.className = 'lc-shell-account';
      account.innerHTML = '<span class="lc-shell-account__avatar" aria-hidden="true"></span><span class="lc-shell-account__copy"><strong></strong><small></small></span><button type="button" class="lc-shell-account__signout">' + svgFor('signOut') + '<span>Sign Out</span></button>';
      account.querySelector('button').addEventListener('click', () => byId('signOutBtn')?.click());
      document.querySelector('header .app-brand')?.appendChild(account);
    }

    const profile = signedInProfile();
    const name = byId('userName')?.textContent?.trim() || profile?.full_name || profile?.name || 'Team Member';
    const role = roleLabel(String(profile?.role || currentRole()).toLowerCase());
    const avatar = account.querySelector('.lc-shell-account__avatar');
    const avatarText = String(name).split(/\s+/).filter(Boolean).map(part => part[0]).slice(0, 2).join('').toUpperCase() || 'LC';
    const avatarFallback = avatar.querySelector('span');
    if (avatarFallback) setText(avatarFallback, avatarText);
    else setText(avatar, avatarText);
    setText(account.querySelector('strong'), name);
    setText(account.querySelector('small'), role);

    const dashboard = byId('dashboardPage');
    if (!dashboard) return;
    byId('companyName')?.closest('.card')?.classList.add('lc-dashboard-hero');

    dashboardTiles().forEach(tile => {
      if (tile.querySelector('.lc-dashboard-tile__icon')) return;
      const icon = document.createElement('span');
      icon.className = 'lc-dashboard-tile__icon';
      icon.innerHTML = svgFor(tile.id);
      tile.prepend(icon);
    });
  }

  function createShell() {
    if (sidebar) return;
    sidebar = document.createElement('aside');
    sidebar.id = 'lcRoleSidebar';
    sidebar.className = 'lc-role-sidebar';
    sidebar.setAttribute('aria-label', 'LineCrew Pro navigation');

    const brand = document.createElement('button');
    brand.type = 'button';
    brand.className = 'lc-role-sidebar__brand';
    brand.innerHTML = '<img src="/icons/linecrew-pro-192.png" alt=""><span><strong>LineCrew Pro</strong><span>Powerline Management Platform</span></span>';
    brand.addEventListener('click', () => {
      if (typeof window.returnToDashboard === 'function') void window.returnToDashboard();
      else byId('dashboardPage')?.scrollIntoView({ block: 'start' });
    });

    const identity = document.createElement('div');
    identity.className = 'lc-role-sidebar__identity';
    identity.innerHTML = '<strong id="lcSidebarCompany">LineCrew Pro</strong><span id="lcSidebarRole">Team Member</span>';

    nav = document.createElement('nav');
    nav.className = 'lc-role-sidebar__nav';

    const footer = document.createElement('div');
    footer.className = 'lc-role-sidebar__footer';
    footer.appendChild(createItem('signOut', 'Sign Out', () => byId('signOutBtn')?.click()));

    sidebar.append(brand, identity, nav, footer);
    document.body.appendChild(sidebar);
  }

  function dashboardTiles() {
    const grid = byId('dashboardTileGrid');
    if (!grid) return [];
    return [...grid.children].filter(tile =>
      tile.classList.contains('metric') &&
      !tile.classList.contains('hidden') &&
      tile.querySelector('strong')
    );
  }

  function itemMatchesTile(item, tile) {
    return item.dataset.shellTarget === tile.id &&
      item.querySelector('span')?.textContent === tile.querySelector('strong')?.textContent.trim();
  }

  function syncNavigation() {
    createShell();
    const tiles = dashboardTiles();
    const existing = [...nav.querySelectorAll('.lc-role-sidebar__item:not([data-shell-target="dashboard"])')];
    const currentIsValid = existing.length === tiles.length && existing.every((item, index) => itemMatchesTile(item, tiles[index]));

    if (!nav.querySelector('[data-shell-target="dashboard"]')) {
      nav.prepend(createItem('dashboard', 'Dashboard', () => {
        if (typeof window.returnToDashboard === 'function') void window.returnToDashboard();
      }));
    }

    if (!currentIsValid) {
      existing.forEach(item => item.remove());
      tiles.forEach(tile => {
        const label = tile.querySelector('strong').textContent.trim();
        nav.appendChild(createItem(tile.id, label, () => tile.click()));
      });
    }

    const profile = signedInProfile();
    const companyName = byId('companyName')?.textContent?.trim() || byId('companyBrandNameHeader')?.textContent?.trim() || 'LineCrew Pro';
    setText(byId('lcSidebarCompany'), companyName);
    setText(byId('lcSidebarRole'), roleLabel(String(profile?.role || currentRole()).toLowerCase()));
  }

  function syncActiveItem() {
    const activeTarget = pageToTile[visibleSectionId()] || '';
    nav?.querySelectorAll('.lc-role-sidebar__item').forEach(item => {
      if (item.dataset.shellTarget === activeTarget) item.setAttribute('aria-current', 'page');
      else item.removeAttribute('aria-current');
    });
  }

  function sync() {
    syncQueued = false;
    createShell();
    observer?.disconnect();
    try {
      const active = eligibleForShell();
      document.body.classList.toggle('lc-shell-active', active);
      sidebar.setAttribute('aria-hidden', active ? 'false' : 'true');
      if (!active) return;
      syncNavigation();
      enhanceDesktopChrome();
      syncActiveItem();
    } finally {
      observe();
    }
  }

  function scheduleSync() {
    if (syncQueued) return;
    syncQueued = true;
    requestAnimationFrame(sync);
  }

  function init() {
    createShell();
    observer = new MutationObserver(scheduleSync);
    observe();
    desktopQuery.addEventListener?.('change', scheduleSync);
    window.addEventListener('popstate', scheduleSync);
    window.addEventListener('focus', scheduleSync);
    document.addEventListener('linecrew:profile-updated', scheduleSync);
    [0, 150, 600, 1500, 3000].forEach(delay => setTimeout(scheduleSync, delay));
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
