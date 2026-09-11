/* LineCrew Pro — Assistant core helpers.
 * Staged extraction from index.html. Keep helpers pure and side-effect free.
 */
(() => {
  'use strict';

  const ASSISTANT_MEMORY_TRIGGER_LABELS = Object.freeze({
    always:'Always',
    job_open:'When the job is open',
    production_review:'During production review',
    final_billing:'Before final billing',
    timekeeping:'During timekeeping',
    billing:'During billing',
    manual:'Only in Saved Memories'
  });

  function assistantMemoryTriggerLabel(trigger){
    return ASSISTANT_MEMORY_TRIGGER_LABELS[String(trigger || '')] || 'Saved reminder';
  }

  function assistantMemoryJobLabel(memory){
    const job = Array.isArray(memory?.jobs) ? memory.jobs[0] : memory?.jobs;
    if(!job) return 'Selected job';
    return [job.job_number,job.job_name].filter(Boolean).join(' — ') || 'Selected job';
  }

  const api = Object.freeze({ assistantMemoryTriggerLabel, assistantMemoryJobLabel });
  window.LineCrewAssistantCore = api;

  // Compatibility bridges while the legacy inline copies remain available.
  window.assistantMemoryTriggerLabel = assistantMemoryTriggerLabel;
  window.assistantMemoryJobLabel = assistantMemoryJobLabel;
})();
