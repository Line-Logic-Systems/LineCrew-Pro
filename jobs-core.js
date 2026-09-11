/* LineCrew Pro — Jobs core helpers.
 * Staged extraction from index.html. Keep helpers pure and side-effect free.
 */
(() => {
  'use strict';

  function fileNameWithoutExtension(value){
    return String(value || 'Job Packet').replace(/\.[^.]+$/, '');
  }

  const api = Object.freeze({ fileNameWithoutExtension });
  window.LineCrewJobsCore = api;

  // Compatibility bridge while the legacy inline copy remains available.
  window.fileNameWithoutExtension = fileNameWithoutExtension;
})();
