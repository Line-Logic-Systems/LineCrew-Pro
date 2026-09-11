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

  function simpleJobBrowserViewModel(jobs, options = {}){
    const list = Array.isArray(jobs) ? jobs : [];
    const search = String(options.search || '').trim().toLowerCase();
    const status = String(options.status || 'active');
    const visibleCount = Math.max(0, Number(options.visibleCount ?? list.length) || 0);
    const matchingJobs = list.filter(job => {
      if(status === 'active' && job?.active !== true) return false;
      if(status === 'closed' && job?.active === true) return false;
      return !search ||
        String(job?.job_number || '').toLowerCase().includes(search) ||
        String(job?.job_name || '').toLowerCase().includes(search);
    });
    const visibleJobs = matchingJobs.slice(0, visibleCount);
    return {
      matchingCount: matchingJobs.length,
      visibleCount: visibleJobs.length,
      visibleJobs,
      hasMore: matchingJobs.length > visibleCount
    };
  }

  function jobProgressRowViewModel(job, summary = {}, assignments = [], options = {}){
    const assignedNames = (Array.isArray(assignments) ? assignments : [])
      .map(assignment => assignment?.full_name)
      .filter(Boolean);
    const role = String(options.role || '');
    const profileName = String(options.profileName || '');
    const assignmentLabel = assignedNames.length
      ? assignedNames.join(', ')
      : (role === 'foreman' ? (profileName || 'Assigned to you') : 'Unassigned');
    const active = job?.active === true;
    return {
      statusText: active ? 'ACTIVE' : 'CLOSED',
      statusClass: active ? 'active' : 'closed',
      assignmentLabel,
      packageCount: Number(summary?.package_count || 0),
      workPointCount: Number(summary?.work_point_count || 0)
    };
  }

  function jobCardDisplayModel(job = {}){
    const active = job?.active === true;
    const customer = job?.customer_name || 'No customer listed';
    const utility = job?.utility_name || 'No utility listed';
    const contract = job?.contracts;
    const contractLabel = contract
      ? contract.contract_name + (contract.contract_number ? ' (' + contract.contract_number + ')' : '')
      : 'Legacy job — contract not assigned';
    const contractCustomer = contract?.customers?.name || customer;
    return {
      statusText: active ? 'ACTIVE' : 'CLOSED',
      statusClass: active ? 'active' : 'closed',
      customer: contractCustomer,
      utility,
      contractLabel
    };
  }

  function jobAssignmentPanelViewModel(assignments = [], assignableLeaders = []){
    const assigned = Array.isArray(assignments) ? assignments : [];
    const leaders = Array.isArray(assignableLeaders) ? assignableLeaders : [];
    const assignedIds = new Set(assigned.map(item => item?.member_id).filter(Boolean));
    const available = leaders.filter(leader => !assignedIds.has(leader?.member_id));
    return {
      assignments: assigned,
      available,
      isEmpty: assigned.length === 0,
      assignButtonLabel: assigned.length > 0
        ? 'Assign Another Foreman / Leader'
        : 'Assign Foreman / Leader'
    };
  }

  function jobAssignmentRowViewModel(assignment = {}){
    const hasAssignedAt = Boolean(assignment?.assigned_at);
    return {
      fullName: assignment?.full_name || '',
      memberRole: assignment?.member_role || '',
      hasAssignedAt,
      assignedByName: hasAssignedAt
        ? (assignment?.assigned_by_name || 'Unknown Team Member')
        : '',
      assignedAt: hasAssignedAt ? assignment.assigned_at : ''
    };
  }

  function jobPackagesForJob(packages = [], jobId = ''){
    const list = Array.isArray(packages) ? packages : [];
    return list.filter(jobPackage => String(jobPackage?.job_id) === String(jobId));
  }

  function jobPackageOpenButtonLabel(packageCount){
    return Number(packageCount) === 1 ? 'Open Package' : 'View Packages';
  }

  function jobPackageDetailSubtitle(jobPackage = {}){
    const status = String(jobPackage?.status || 'draft').toUpperCase();
    const source = jobPackage?.source_filename
      ? ' · Source: ' + jobPackage.source_filename
      : '';
    return 'Reference: ' + (jobPackage?.package_number || 'Not provided') +
      ' · Status: ' + status + source;
  }

  function completedJobSummaryViewModel(record = {}){
    const progress = record?.progress || {};
    const count = value => Array.isArray(value) ? value.length : 0;
    return {
      reportedPercent: Number(progress?.reported_percent || 0).toFixed(1),
      approvedPercent: Number(progress?.approved_percent || 0).toFixed(1),
      dailyReports: count(record?.reports),
      unitLines: count(record?.units),
      packetRevisions: count(record?.packages),
      jsas: count(record?.jsas),
      attachments: count(record?.attachments)
    };
  }

  function completedJobPackageRowViewModel(jobPackage = {}){
    return {
      revisionLabel: jobPackageRevisionLabel(jobPackage),
      packageName: jobPackage?.package_name || jobPackage?.package_number || 'Utility Job Packet',
      statusText: String(jobPackage?.status || '').toUpperCase(),
      sourceFilename: jobPackage?.source_filename || 'No source filename'
    };
  }

  function completedJobDailyReportRowViewModel(report = {}){
    return {
      workDate: report?.work_date || '',
      foremanName: report?.foreman_name || 'Foreman not recorded',
      crewName: report?.crew_name || 'Crew not recorded',
      regularHours: Number(report?.regular_hours || 0),
      overtimeHours: Number(report?.overtime_hours || 0),
      statusText: String(report?.status || '').toUpperCase(),
      notes: report?.notes || ''
    };
  }

  const api = Object.freeze({
    fileNameWithoutExtension,
    jobPacketFileValidationMessage,
    formatCompletedJobDate,
    completedJobUnitRows,
    jobPackageRevisionLabel,
    normalizeJobPacketPoint,
    jobProgressViewModel,
    simpleJobBrowserViewModel,
    jobProgressRowViewModel,
    jobCardDisplayModel,
    jobAssignmentPanelViewModel,
    jobAssignmentRowViewModel,
    jobPackagesForJob,
    jobPackageOpenButtonLabel,
    jobPackageDetailSubtitle,
    completedJobSummaryViewModel,
    completedJobPackageRowViewModel,
    completedJobDailyReportRowViewModel
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
  window.simpleJobBrowserViewModel = simpleJobBrowserViewModel;
  window.jobProgressRowViewModel = jobProgressRowViewModel;
  window.jobCardDisplayModel = jobCardDisplayModel;
  window.jobAssignmentPanelViewModel = jobAssignmentPanelViewModel;
  window.jobAssignmentRowViewModel = jobAssignmentRowViewModel;
  window.jobPackagesForJob = jobPackagesForJob;
  window.jobPackageOpenButtonLabel = jobPackageOpenButtonLabel;
  window.jobPackageDetailSubtitle = jobPackageDetailSubtitle;
  window.completedJobSummaryViewModel = completedJobSummaryViewModel;
  window.completedJobPackageRowViewModel = completedJobPackageRowViewModel;
  window.completedJobDailyReportRowViewModel = completedJobDailyReportRowViewModel;
})();
