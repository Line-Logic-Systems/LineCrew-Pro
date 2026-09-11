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

  function pushUnsupportedReason(){
    if(!('serviceWorker' in navigator) || !('PushManager' in window) || !('Notification' in window)){
      return 'Not supported on this browser.';
    }
    if(/iPad|iPhone|iPod/.test(navigator.userAgent) && !window.navigator.standalone){
      return 'On iPhone, add LineCrew Pro to your Home Screen first: Share → Add to Home Screen.';
    }
    if(Notification.permission === 'denied'){
      return 'Blocked in browser settings. Allow notifications for LineCrew Pro in this device’s browser or app settings.';
    }
    return '';
  }

  const api = Object.freeze({ urlBase64ToUint8Array, pushUnsupportedReason });
  window.LineCrewNotificationsCore = api;

  // Compatibility bridges while the legacy inline copies remain available.
  window.urlBase64ToUint8Array = urlBase64ToUint8Array;
  window.pushUnsupportedReason = pushUnsupportedReason;
})();
