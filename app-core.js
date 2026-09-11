/* LineCrew Pro — shared app core helpers.
 * Staged extraction from index.html. Keep helpers pure and side-effect free.
 */
(() => {
  'use strict';

  function uniqueOfflineJsaJobs(jobs){
    const unique = new Map();
    (jobs || []).forEach(job => {
      const id = String(job?.id || '');
      if(!id || unique.has(id)) return;
      unique.set(id,{
        id,
        job_number:String(job.job_number || 'Job').slice(0,100),
        job_name:String(job.job_name || 'Unnamed').slice(0,180)
      });
    });
    return [...unique.values()];
  }

  function offlineJsaNetworkFailure(error){
    const message = String(error?.message || error || '').toLowerCase();
    return !navigator.onLine || /failed to fetch|network|load failed|timeout|timed out|connection/.test(message);
  }

  function companyAccessInactive(error){
    const text = String(error?.message || '') + ' ' + String(error?.hint || '');
    return /company access is inactive/i.test(text);
  }

  const api = Object.freeze({
    uniqueOfflineJsaJobs,
    offlineJsaNetworkFailure,
    companyAccessInactive
  });
  window.LineCrewAppCore = api;

  // Compatibility bridges while the legacy inline copies remain available.
  window.uniqueOfflineJsaJobs = uniqueOfflineJsaJobs;
  window.offlineJsaNetworkFailure = offlineJsaNetworkFailure;
  window.companyAccessInactive = companyAccessInactive;
})();
