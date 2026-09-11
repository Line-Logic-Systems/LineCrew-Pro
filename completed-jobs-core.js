/* LineCrew Pro — Completed Jobs read-only presentation helpers.
 * Final staged cleanup before beta workflow testing. Keep helpers pure and side-effect free.
 */
(() => {
  'use strict';

  function completedJobCardViewModel(job = {}, progress = {}, assignments = []){
    const supervision = (Array.isArray(assignments) ? assignments : [])
      .map(item => item?.full_name)
      .filter(Boolean)
      .join(', ') || 'No retained assignment';
    return {
      jobNumber: job?.job_number || '',
      jobName: job?.job_name || '',
      customer: job?.contracts?.customers?.name || job?.customer_name || 'Not recorded',
      contract: job?.contracts?.contract_name || 'Not assigned',
      closedAt: job?.closed_at || '',
      reportedPercent: Number(progress?.reported_percent || 0).toFixed(1),
      approvedPercent: Number(progress?.approved_percent || 0).toFixed(1),
      reportCount: Number(progress?.report_count || 0),
      workPointCount: Number(progress?.work_point_count || 0),
      supervision
    };
  }

  function completedJobAttachmentRowViewModel(item = {}){
    return {
      attachmentId: item?.id || '',
      fileName: item?.original_filename || 'Attachment',
      caption: item?.caption || '',
      createdAt: item?.created_at || ''
    };
  }

  function completedJobCloseoutRowViewModel(item = {}){
    return {
      actionText: String(item?.action || '').replaceAll('_',' ').toUpperCase(),
      actorName: item?.actor_name || 'System',
      actorRole: item?.actor_role || '',
      occurredAt: item?.occurred_at || '',
      reason: item?.reason || '',
      isOwnerOverride: item?.action === 'override_closed'
    };
  }

  function completedJobAuditRowViewModel(item = {}){
    return {
      eventType: String(item?.event_type || 'updated').replaceAll('_',' '),
      actorName: item?.actor_name || 'System',
      eventAt: item?.event_at || '',
      eventNotes: item?.event_notes || ''
    };
  }

  window.LineCrewCompletedJobsCore = Object.freeze({
    completedJobCardViewModel,
    completedJobAttachmentRowViewModel,
    completedJobCloseoutRowViewModel,
    completedJobAuditRowViewModel
  });
})();
