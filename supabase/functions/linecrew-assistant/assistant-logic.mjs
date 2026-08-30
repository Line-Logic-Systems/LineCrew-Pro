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

export function assistantModelConfig(route, env = {}) {
  const fastModel = clippedText(env.OPENAI_MODEL_FAST || env.OPENAI_MODEL || 'gpt-5-mini', 80);
  const reasoningModel = clippedText(env.OPENAI_MODEL_REASONING || 'gpt-5.6-terra', 80);
  if (route === 'reasoning') {
    return { model: reasoningModel, effort: 'medium', fallbackModel: fastModel };
  }
  return { model: fastModel, effort: 'low', fallbackModel: fastModel };
}
