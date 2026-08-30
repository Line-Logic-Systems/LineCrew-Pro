const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const ALLOWED_PAGE_PATTERN = /^[A-Za-z][A-Za-z0-9_-]{0,79}$/;
const ALLOWED_ID_KEYS = new Set([
  'job_id',
  'report_id',
  'job_package_id',
  'price_book_id',
  'billing_batch_id',
  'pay_period_id'
]);
const ALLOWED_LABEL_KEYS = new Set([
  'job',
  'report',
  'job_package',
  'price_book',
  'billing_batch',
  'pay_period',
  'crew',
  'production_status',
  'search'
]);

const LIVE_CONTEXT_TERMS = Object.freeze({
  jobs: /\b(job|jobs|assignment|assigned|job packet|utility packet|work point|remaining units|job progress|closeout|reopen)\b/i,
  reports: /\b(daily report|daily reports|production|approve|approval|submitted|returned|redline|pending packet|review queue)\b/i,
  team: /\b(team|member|role|permission|owner|admin|superintendent|general foreman|\bgf\b|foreman|cannot see|can't see|access)\b/i,
  timekeeping: /\b(timekeeping|crew time|payroll|timesheet|hours|overtime|\bot\b|per diem|pay period|start time|stop time|lunch)\b/i,
  billing: /\b(billing|bill|invoice|final bill|partial bill|billing batch|paid|submitted batch|credit|adjustment)\b/i,
  pricing: /\b(price book|pricing|unit price|contract price|field value|actual price|adjustment percent)\b/i
});

const COMPLEX_REQUEST_PATTERN = /\b(why|diagnose|investigate|cannot|can't|won't|not working|failed|failure|error|blocked|preventing|missing|mismatch|incorrect|wrong|conflict|ready for|safe to|final bill|closeout)\b/i;
const MEMORY_REQUEST_PATTERN = /\b(remember(?:\s+that)?|remind\s+me(?:\s+to)?|from\s+now\s+on|always\s+(?:remember|make\s+sure|check|include|attach|add|verify))\b/i;
const EXPLICIT_NAVIGATION_PATTERN = /\b(?:(?:take|bring)\s+me\s+to|(?:go|navigate)\s+to|open|(?:show|view)\s+(?:the\s+)?(?:page|screen|dashboard))\b/i;
const ASSISTANT_NAVIGATION_DESTINATIONS = Object.freeze([
  { destination:'assistant_memory', label:'Assistant Memory', pattern:/\b(?:assistant\s+memor(?:y|ies)|saved\s+memor(?:y|ies)|saved\s+reminders?)\b/i },
  { destination:'company_settings', label:'Company Settings', pattern:/\b(?:company\s+settings|admin\s+controls?|company\s+controls?)\b/i },
  { destination:'company_billing', label:'Company Billing', pattern:/\b(?:company|subscription|stripe|plan|payment\s+method)\s+billing\b|\bbilling\s+(?:plan|subscription|payment\s+method)\b/i },
  { destination:'completed_jobs', label:'Completed Jobs', pattern:/\b(?:completed|closed|archived)\s+jobs?\b/i },
  { destination:'billing_exports', label:'Billing Exports', pattern:/\b(?:billing\s+(?:batch|batches|export|exports)|final\s+bill(?:ing)?|partial\s+bill(?:ing)?|invoice\s+batch)\b/i },
  { destination:'price_books', label:'Price Books', pattern:/\b(?:price\s*books?|pricing|customers?|utilities|contracts?|unit\s+prices?)\b/i },
  { destination:'timekeeping', label:'Timekeeping', pattern:/\b(?:timekeeping|crew\s+time|payroll|timesheets?|pay\s+periods?|employee\s+roster|equipment\s+roster)\b/i },
  { destination:'safety', label:'Safety / JSA', pattern:/\b(?:safety|jsa|job\s+safety)\b/i },
  { destination:'production', label:'Production', pattern:/\b(?:production|daily\s+reports?|report\s+review|review\s+reports?|approval\s+queue)\b/i },
  { destination:'team', label:'Team', pattern:/\b(?:team|team\s+access|members?|roles?|permissions?|superintendents?|general\s+foremen|foremen)\b/i },
  { destination:'training', label:'Training', pattern:/\b(?:training|training\s+center|training\s+videos?|how-to\s+videos?)\b/i },
  { destination:'jobs', label:'Jobs', pattern:/\b(?:jobs?|job\s+progress|assigned\s+jobs?|utility\s+(?:job\s+)?packages?|work\s+points?)\b/i },
  { destination:'dashboard', label:'Dashboard', pattern:/\b(?:dashboard|home\s+screen|main\s+screen)\b/i }
]);

function clippedText(value, maxLength) {
  return String(value ?? '').replace(/\s+/g, ' ').trim().slice(0, maxLength);
}

export function sanitizeAssistantScreenContext(input) {
  if (!input || typeof input !== 'object' || Array.isArray(input)) return {};
  const source = input;
  const context = {};

  const page = clippedText(source.page, 80);
  if (page && ALLOWED_PAGE_PATTERN.test(page)) context.page = page;

  const title = clippedText(source.title, 120);
  if (title) context.title = title;

  const selectedIds = {};
  if (source.selected_ids && typeof source.selected_ids === 'object' && !Array.isArray(source.selected_ids)) {
    for (const [key, value] of Object.entries(source.selected_ids)) {
      const normalized = clippedText(value, 36);
      if (ALLOWED_ID_KEYS.has(key) && UUID_PATTERN.test(normalized)) selectedIds[key] = normalized;
    }
  }
  if (Object.keys(selectedIds).length) context.selected_ids = selectedIds;

  const selectedLabels = {};
  if (source.selected_labels && typeof source.selected_labels === 'object' && !Array.isArray(source.selected_labels)) {
    for (const [key, value] of Object.entries(source.selected_labels)) {
      const normalized = clippedText(value, 160);
      if (ALLOWED_LABEL_KEYS.has(key) && normalized) selectedLabels[key] = normalized;
    }
  }
  if (Object.keys(selectedLabels).length) context.selected_labels = selectedLabels;

  if (Array.isArray(source.visible_messages)) {
    const messages = source.visible_messages
      .map(value => clippedText(value, 240))
      .filter(Boolean)
      .slice(0, 5);
    if (messages.length) context.visible_messages = messages;
  }

  const lastError = clippedText(source.last_error, 300);
  if (lastError) context.last_error = lastError;

  return context;
}

export function classifyAssistantRequest(question, page = '', screenContext = {}) {
  const text = `${clippedText(question, 1200)} ${clippedText(page, 80)} ${clippedText(screenContext?.title, 120)}`;
  const categories = Object.entries(LIVE_CONTEXT_TERMS)
    .filter(([, pattern]) => pattern.test(text))
    .map(([category]) => category);
  if (/\b(can't|cannot|won't|unable to)\b.{0,80}\b(see|access|open|find)\b/i.test(text) && !categories.includes('team')) {
    categories.push('team');
  }
  if (/\b(final bill|final billing|closeout|close job|ready.{0,30}bill)\b/i.test(text)) {
    for (const category of ['jobs','reports','billing']) {
      if (!categories.includes(category)) categories.push(category);
    }
  }

  const selectedIds = screenContext?.selected_ids && typeof screenContext.selected_ids === 'object'
    ? screenContext.selected_ids
    : {};
  if (selectedIds.job_id && !categories.includes('jobs')) categories.push('jobs');
  if (selectedIds.job_package_id && !categories.includes('jobs')) categories.push('jobs');
  if (selectedIds.report_id && !categories.includes('reports')) categories.push('reports');
  if (selectedIds.billing_batch_id && !categories.includes('billing')) categories.push('billing');
  if (selectedIds.pay_period_id && !categories.includes('timekeeping')) categories.push('timekeeping');
  if (selectedIds.price_book_id && !categories.includes('pricing')) categories.push('pricing');

  const route = COMPLEX_REQUEST_PATTERN.test(text) || categories.length >= 3 || Boolean(screenContext?.last_error)
    ? 'reasoning'
    : 'fast';

  return { categories, route };
}

export function detectAssistantNavigation(question) {
  const text = clippedText(question, 1200);
  if (!text) return null;
  const target = ASSISTANT_NAVIGATION_DESTINATIONS.find(destination => destination.pattern.test(text));
  if (!target) return null;
  const result = {
    destination: target.destination,
    label: target.label,
    mode: EXPLICIT_NAVIGATION_PATTERN.test(text) ? 'auto' : 'suggest'
  };
  if (target.destination === 'jobs' || target.destination === 'billing_exports') {
    const jobMatch = text.match(/\bjob\s+(?:number\s+)?([A-Za-z0-9][A-Za-z0-9._/-]{1,39})\b/i);
    if (jobMatch && /\d/.test(jobMatch[1])) result.query = jobMatch[1];
  }
  return result;
}

export function assistantModelConfig(route, env = {}) {
  const fastModel = clippedText(env.OPENAI_MODEL_FAST || env.OPENAI_MODEL || 'gpt-5-mini', 80);
  const reasoningModel = clippedText(env.OPENAI_MODEL_REASONING || 'gpt-5.6-terra', 80);
  if (route === 'reasoning') {
    return { model: reasoningModel, effort: 'medium', fallbackModel: fastModel };
  }
  return { model: fastModel, effort: 'low', fallbackModel: fastModel };
}

export function detectAssistantMemoryProposal(question, screenContext = {}) {
  const original = clippedText(question, 1200);
  if (!original || !MEMORY_REQUEST_PATTERN.test(original)) return null;
  if (/\b(how|where|can\s+you)\b.{0,30}\b(reminders?|memory|remember)\b/i.test(original) &&
      !/\b(remind\s+me|remember\s+that|from\s+now\s+on)\b/i.test(original)) return null;

  const selectedIds = screenContext?.selected_ids && typeof screenContext.selected_ids === 'object'
    ? screenContext.selected_ids
    : {};
  const selectedLabels = screenContext?.selected_labels && typeof screenContext.selected_labels === 'object'
    ? screenContext.selected_labels
    : {};
  const jobId = UUID_PATTERN.test(String(selectedIds.job_id || '')) ? String(selectedIds.job_id) : null;
  const companyScopeRequested = /\b(company|company-wide|workflow|every\s+job|all\s+jobs|from\s+now\s+on)\b/i.test(original);
  const jobScopeRequested = Boolean(jobId) && !companyScopeRequested && (
    /\b(on|for|about)\s+(?:this|the|selected|current)\s+job\b/i.test(original) ||
    /\bthis\s+job\b/i.test(original) ||
    /\bremind\s+me\b/i.test(original)
  );
  const memoryType = jobScopeRequested ? 'job_reminder' : 'company_workflow';

  let instruction = original
    .replace(/^\s*(?:on|for)\s+(?:this|the|selected|current)\s+job\s*[,;:-]?\s*/i, '')
    .replace(/^\s*(?:please\s+)?(?:can\s+you\s+)?(?:remember(?:\s+that)?|remind\s+me(?:\s+to)?|from\s+now\s+on\s*[,;:-]?|always\s+(?:remember\s+to|make\s+sure\s+to)?)\s*/i, '')
    .replace(/^\s*(?:on|for)\s+(?:this|the|selected|current)\s+job\s*[,;:-]?\s*/i, '')
    .replace(/^\s*(?:remember(?:\s+that)?|remind\s+me(?:\s+to)?|to)\s*/i, '')
    .replace(/[?.!]+$/, '')
    .trim();
  if (!instruction || instruction.length < 3) return null;
  instruction = instruction.slice(0, 800);

  let triggerType = memoryType === 'job_reminder' ? 'job_open' : 'always';
  if (/\b(final\s+bill(?:ing)?|before\s+(?:the\s+)?final\s+bill)\b/i.test(original)) triggerType = 'final_billing';
  else if (/\b(production\s+review|report\s+(?:review|approval)|before\s+approv(?:e|ing))\b/i.test(original)) triggerType = 'production_review';
  else if (/\b(timekeeping|timesheet|payroll|pay\s+period)\b/i.test(original)) triggerType = 'timekeeping';
  else if (/\b(bill(?:ing)?|invoice)\b/i.test(original)) triggerType = 'billing';
  else if (/\b(manual|only\s+when\s+asked)\b/i.test(original)) triggerType = 'manual';

  const compactTitle = instruction.charAt(0).toUpperCase() + instruction.slice(1);
  const title = compactTitle.length > 96 ? `${compactTitle.slice(0, 93).trim()}...` : compactTitle;
  return {
    memory_type: memoryType,
    title,
    instruction,
    trigger_type: triggerType,
    job_id: memoryType === 'job_reminder' ? jobId : null,
    job_label: memoryType === 'job_reminder' ? clippedText(selectedLabels.job, 160) || 'Selected job' : null,
    requires_confirmation: true,
  };
}

export function assistantMemoryManagementRequested(question) {
  const text = clippedText(question, 1200);
  if (!text) return false;
  return /\b(saved\s+memor(?:y|ies)|assistant\s+memor(?:y|ies))\b/i.test(text) ||
    /\b(where|find|view|show|list|open|manage|edit|change|delete|remove|complete)\b.{0,100}\b(reminder|reminders|memor(?:y|ies))\b/i.test(text) ||
    /\b(reminder|reminders|memor(?:y|ies))\b.{0,100}\b(where|find|view|show|list|open|manage|edit|change|delete|remove|complete)\b/i.test(text);
}
