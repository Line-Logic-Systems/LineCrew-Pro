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

  const api = Object.freeze({ assistantMemoryTriggerLabel });
  window.LineCrewAssistantCore = api;

  // Compatibility bridge while the legacy inline copy remains available.
  window.assistantMemoryTriggerLabel = assistantMemoryTriggerLabel;
})();
