/* LineCrew Pro — Jobs core helpers.
 * Staged extraction from index.html. Keep helpers pure and side-effect free.
 */
(() => {
  'use strict';

  function fileNameWithoutExtension(value){
    return String(value || 'Job Packet').replace(/\.[^.]+$/, '');
  }

  function jobPacketFileValidationMessage(file){
    if(!file) return '';
    const filename = String(file.name || '').trim();
    if(!/\.(pdf|csv|tsv|txt|xlsx|xls|ods)$/i.test(filename)){
      return 'Choose a PDF, Excel, CSV, TSV, TXT or ODS job jacket.';
    }
    if(/\.pdf$/i.test(filename) && Number(file.size || 0) > 20 * 1024 * 1024){
      return 'The PDF job jacket must be 20 MB or smaller.';
    }
    return '';
  }

  function formatCompletedJobDate(value){
    return value ? new Date(value).toLocaleString() : 'Not recorded';
  }

  const api = Object.freeze({
    fileNameWithoutExtension,
    jobPacketFileValidationMessage,
    formatCompletedJobDate
  });
  window.LineCrewJobsCore = api;

  // Compatibility bridges while the legacy inline copies remain available.
  window.fileNameWithoutExtension = fileNameWithoutExtension;
  window.jobPacketFileValidationMessage = jobPacketFileValidationMessage;
  window.formatCompletedJobDate = formatCompletedJobDate;
})();
