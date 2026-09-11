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

  function completedJobUnitRows(record){
    return record.units.map(unit=>({
      'Work Date':unit.work_date||'',
      'Foreman':unit.foreman_name||'',
      'Crew':unit.crew_name||'',
      'Pole / Work Point':unit.pole_location||unit.work_point||'',
      'Unit Code':unit.item_code||unit.unit_code||'',
      'Description':unit.item_name||unit.unit_name||unit.description||'',
      'Installed':Number(unit.install_quantity||0),
      'Transferred':Number(unit.transfer_quantity||0),
      'Removed':Number(unit.retirement_quantity||unit.remove_quantity||0),
      'Authorization':String(unit.authorization_status||'').replaceAll('_',' '),
      'Visible Value':Number(unit.visible_line_value||unit.adjusted_line_value||unit.actual_line_value||0)
    }));
  }

  function jobPackageRevisionLabel(jobPackage){
    const revision = Math.max(1, Number(jobPackage?.revision_number || 1));
    return revision > 1 ? 'Revision ' + (revision - 1) : 'Original Packet';
  }

  function normalizeJobPacketPoint(value){
    const key = String(value || '')
      .trim()
      .toLowerCase()
      .replace(/^(pole|wp|work[\s_-]*point)[\s#:_-]*/i, '')
      .replace(/[^a-z0-9]+/g, '');
    return /^\d+$/.test(key)
      ? (key.replace(/^0+(?=\d)/, '') || '0')
      : key;
  }

  const api = Object.freeze({
    fileNameWithoutExtension,
    jobPacketFileValidationMessage,
    formatCompletedJobDate,
    completedJobUnitRows,
    jobPackageRevisionLabel,
    normalizeJobPacketPoint
  });
  window.LineCrewJobsCore = api;

  // Compatibility bridges while the legacy inline copies remain available.
  window.fileNameWithoutExtension = fileNameWithoutExtension;
  window.jobPacketFileValidationMessage = jobPacketFileValidationMessage;
  window.formatCompletedJobDate = formatCompletedJobDate;
  window.completedJobUnitRows = completedJobUnitRows;
  window.jobPackageRevisionLabel = jobPackageRevisionLabel;
  window.normalizeJobPacketPoint = normalizeJobPacketPoint;
})();
