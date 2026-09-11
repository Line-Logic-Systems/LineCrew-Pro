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

  function jobProgressViewModel(jobs, options = {}){
    const list = Array.isArray(jobs) ? jobs : [];
    const search = String(options.search || '').trim().toLowerCase();
    const attention = String(options.attention ?? '');
    const sort = String(options.sort || '');
    const visibleCount = Math.max(0, Number(options.visibleCount ?? list.length) || 0);
    const utilityLabel = job => job?.contracts?.customers?.name || job?.utility_name || job?.customer_name || 'No Utility Assigned';
    const contractLabel = job => {
      const contract = job?.contracts;
      if(!contract) return 'No Contract Assigned';
      return contract.contract_name + (contract.contract_number ? ' (' + contract.contract_number + ')' : '');
    };

    const matchingJobs = list.filter(job => {
      if(attention === '' && job?.active !== true) return false;
      if(attention === 'closed' && job?.active === true) return false;
      const searchable = [job?.job_number,job?.job_name,utilityLabel(job),contractLabel(job)]
        .map(value => String(value || '').toLowerCase()).join(' ');
      return !search || searchable.includes(search);
    });

    const sortedJobs = [...matchingJobs].sort((first, second) => {
      if(sort === 'job_number'){
        return String(first?.job_number || '').localeCompare(String(second?.job_number || ''),undefined,{numeric:true,sensitivity:'base'});
      }
      return utilityLabel(first).localeCompare(utilityLabel(second),undefined,{numeric:true,sensitivity:'base'}) ||
        contractLabel(first).localeCompare(contractLabel(second),undefined,{numeric:true,sensitivity:'base'}) ||
        String(first?.job_number || '').localeCompare(String(second?.job_number || ''),undefined,{numeric:true,sensitivity:'base'});
    });

    const visibleJobs = sortedJobs.slice(0, visibleCount);
    const grouped = new Map();
    visibleJobs.forEach(job => {
      const utility = utilityLabel(job);
      const contract = contractLabel(job);
      if(!grouped.has(utility)) grouped.set(utility,new Map());
      const contracts = grouped.get(utility);
      if(!contracts.has(contract)) contracts.set(contract,[]);
      contracts.get(contract).push(job);
    });

    return {
      matchingCount: matchingJobs.length,
      visibleJobs,
      groups: [...grouped.entries()].map(([utility, contracts]) => ({
        utility,
        contracts: [...contracts.entries()].map(([contract, contractJobs]) => ({
          contract,
          jobs: contractJobs
        }))
      }))
    };
  }

  const api = Object.freeze({
    fileNameWithoutExtension,
    jobPacketFileValidationMessage,
    formatCompletedJobDate,
    completedJobUnitRows,
    jobPackageRevisionLabel,
    normalizeJobPacketPoint,
    jobProgressViewModel
  });
  window.LineCrewJobsCore = api;

  // Compatibility bridges while the legacy inline copies remain available.
  window.fileNameWithoutExtension = fileNameWithoutExtension;
  window.jobPacketFileValidationMessage = jobPacketFileValidationMessage;
  window.formatCompletedJobDate = formatCompletedJobDate;
  window.completedJobUnitRows = completedJobUnitRows;
  window.jobPackageRevisionLabel = jobPackageRevisionLabel;
  window.normalizeJobPacketPoint = normalizeJobPacketPoint;
  window.jobProgressViewModel = jobProgressViewModel;
})();
