#!/usr/bin/env node

const supabaseUrl = process.env.SUPABASE_URL?.replace(/\/$/, '');
const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
const errorWindowMinutes = Number.parseInt(process.env.ERROR_WINDOW_MINUTES || '15', 10);
const errorThreshold = Number.parseInt(process.env.ERROR_THRESHOLD || '10', 10);
if (!supabaseUrl || !serviceKey) throw new Error('SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are required');
if (!Number.isInteger(errorWindowMinutes) || errorWindowMinutes < 1) throw new Error('ERROR_WINDOW_MINUTES must be a positive integer');
if (!Number.isInteger(errorThreshold) || errorThreshold < 1) throw new Error('ERROR_THRESHOLD must be a positive integer');

const checks = [];
const failures = [];
const requestTimeoutMs = 20_000;
const publicTargets = [
  { name: 'Marketing website', url: 'https://linecrewpro.com/', marker: 'LineCrew Pro' },
  { name: 'Application login', url: 'https://app.linecrewpro.com/', marker: 'LineCrew Pro' },
];

async function timedFetch(url, options = {}) {
  const startedAt = Date.now();
  const response = await fetch(url, {
    ...options,
    cache: 'no-store',
    signal: AbortSignal.timeout(requestTimeoutMs),
    headers: { 'cache-control': 'no-cache', ...(options.headers || {}) },
  });
  return { response, elapsedMs: Date.now() - startedAt };
}

for (const target of publicTargets) {
  try {
    const separator = target.url.includes('?') ? '&' : '?';
    const { response, elapsedMs } = await timedFetch(`${target.url}${separator}healthcheck=${Date.now()}`);
    const body = await response.text();
    const passed = response.ok && body.includes(target.marker);
    checks.push({ name: target.name, status: response.status, elapsed_ms: elapsedMs, passed });
    if (!passed) failures.push(`${target.name} returned HTTP ${response.status} or did not contain the expected page marker`);
  } catch (error) {
    checks.push({ name: target.name, passed: false, error: error.message });
    failures.push(`${target.name} could not be reached: ${error.message}`);
  }
}

const supabaseHeaders = { apikey: serviceKey, Authorization: `Bearer ${serviceKey}` };
try {
  const { response, elapsedMs } = await timedFetch(`${supabaseUrl}/auth/v1/health`, { headers: supabaseHeaders });
  const passed = response.ok;
  checks.push({ name: 'Supabase Auth', status: response.status, elapsed_ms: elapsedMs, passed });
  if (!passed) failures.push(`Supabase Auth health returned HTTP ${response.status}`);
} catch (error) {
  checks.push({ name: 'Supabase Auth', passed: false, error: error.message });
  failures.push(`Supabase Auth could not be reached: ${error.message}`);
}

try {
  const since = new Date(Date.now() - errorWindowMinutes * 60_000).toISOString();
  const query = new URLSearchParams({ select: 'id', created_at: `gte.${since}`, limit: '1' });
  const { response, elapsedMs } = await timedFetch(`${supabaseUrl}/rest/v1/app_error_events?${query}`, {
    headers: { ...supabaseHeaders, Prefer: 'count=exact', Range: '0-0' },
  });
  const contentRange = response.headers.get('content-range') || '';
  const countText = contentRange.split('/')[1];
  const count = Number.parseInt(countText, 10);
  const passed = response.ok && Number.isInteger(count) && count < errorThreshold;
  checks.push({
    name: 'Application error rate', status: response.status, elapsed_ms: elapsedMs,
    window_minutes: errorWindowMinutes, errors: Number.isInteger(count) ? count : null,
    threshold: errorThreshold, passed,
  });
  if (!response.ok) failures.push(`Application error-rate query returned HTTP ${response.status}`);
  else if (!Number.isInteger(count)) failures.push('Application error-rate query did not return an exact count');
  else if (count >= errorThreshold) failures.push(`${count} sanitized application errors occurred within ${errorWindowMinutes} minutes`);
} catch (error) {
  checks.push({ name: 'Application error rate', passed: false, error: error.message });
  failures.push(`Application error rate could not be checked: ${error.message}`);
}

console.log(JSON.stringify({ checked_at: new Date().toISOString(), checks }, null, 2));
if (failures.length) {
  console.error(failures.map((failure) => `HEALTH FAILURE: ${failure}`).join('\n'));
  process.exitCode = 1;
} else {
  console.log('PASS: production website, app, authentication, and application error rate are healthy.');
}
