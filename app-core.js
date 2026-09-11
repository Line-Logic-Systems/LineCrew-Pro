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

  const api = Object.freeze({ uniqueOfflineJsaJobs });
  window.LineCrewAppCore = api;

  // Compatibility bridge while the legacy inline copy remains available.
  window.uniqueOfflineJsaJobs = uniqueOfflineJsaJobs;
})();
