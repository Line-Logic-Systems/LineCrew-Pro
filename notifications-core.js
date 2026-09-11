/* LineCrew Pro — Notifications core helpers.
 * Staged extraction from index.html. Keep helpers pure and side-effect free.
 */
(() => {
  'use strict';

  function urlBase64ToUint8Array(value){
    const padding = '='.repeat((4 - value.length % 4) % 4);
    const base64 = (value + padding).replace(/-/g, '+').replace(/_/g, '/');
    const raw = window.atob(base64);
    return Uint8Array.from(raw, character => character.charCodeAt(0));
  }

  const api = Object.freeze({ urlBase64ToUint8Array });
  window.LineCrewNotificationsCore = api;

  // Compatibility bridge while the legacy inline copy remains available.
  window.urlBase64ToUint8Array = urlBase64ToUint8Array;
})();
