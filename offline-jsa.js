/* LineCrew Pro - durable offline JSA outbox (digital forms and uploaded pages) */
(() => {
  'use strict';

  const DB_NAME = 'linecrew-offline-jsa-v2';
  const DB_VERSION = 1;
  const STORE = 'submissions';
  const LEGACY_QUEUE_KEY = 'linecrew-offline-jsa-queue-v1';
  const CONTEXT_KEY = 'linecrew-offline-jsa-context-v1';
  const MAX_FILE_BYTES = 15728640;
  const MAX_BACKOFF_MS = 5 * 60 * 1000;
  const byId = (id) => document.getElementById(id);
  const value = (id) => (byId(id)?.value || '').trim();
  const checked = (name) => [...document.querySelectorAll(`[name="${name}"]:checked`)].map((el) => el.value);
  const toast = (message, type = 'info') => window.LineCrewUI?.toast?.(message, type) || window.showToast?.(message) || console.log(message);
  const getClient = () => {
    try { return typeof sb !== 'undefined' ? sb : (window.sb || null); }
    catch (_) { return window.sb || null; }
  };
  const getProfile = () => {
    try { return typeof currentProfile !== 'undefined' ? currentProfile : window.currentProfile; }
    catch (_) { return window.currentProfile; }
  };

  let dbPromise = null;
  let syncPromise = null;

  function uuid() {
    if (crypto.randomUUID) return crypto.randomUUID();
    const bytes = crypto.getRandomValues(new Uint8Array(16));
    bytes[6] = (bytes[6] & 0x0f) | 0x40;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    const hex = [...bytes].map((byte) => byte.toString(16).padStart(2, '0')).join('');
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
  }

  function openDb() {
    if (dbPromise) return dbPromise;
    dbPromise = new Promise((resolve, reject) => {
      const request = indexedDB.open(DB_NAME, DB_VERSION);
      request.onupgradeneeded = () => {
        const db = request.result;
        if (!db.objectStoreNames.contains(STORE)) {
          const store = db.createObjectStore(STORE, { keyPath: 'id' });
          store.createIndex('status', 'status', { unique: false });
          store.createIndex('user_id', 'user_id', { unique: false });
        }
      };
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(request.error || new Error('Device storage could not be opened.'));
    });
    return dbPromise;
  }

  async function runStore(mode, operation) {
    const db = await openDb();
    return new Promise((resolve, reject) => {
      const transaction = db.transaction(STORE, mode);
      const store = transaction.objectStore(STORE);
      let result;
      try { result = operation(store); }
      catch (error) { reject(error); return; }
      transaction.oncomplete = () => resolve(result?.result);
      transaction.onerror = () => reject(transaction.error || result?.error || new Error('Device storage failed.'));
      transaction.onabort = () => reject(transaction.error || new Error('Device storage was interrupted.'));
    });
  }

  const put = (item) => runStore('readwrite', (store) => store.put(item));
  const remove = (id) => runStore('readwrite', (store) => store.delete(id));
  async function all() {
    const db = await openDb();
    return new Promise((resolve, reject) => {
      const request = db.transaction(STORE, 'readonly').objectStore(STORE).getAll();
      request.onsuccess = () => resolve(request.result || []);
      request.onerror = () => reject(request.error || new Error('Queued JSAs could not be read.'));
    });
  }

  async function ensureCapacity(bytes) {
    if (!navigator.storage?.estimate) return;
    const estimate = await navigator.storage.estimate();
    if (!Number.isFinite(estimate.quota) || !Number.isFinite(estimate.usage)) return;
    const remaining = estimate.quota - estimate.usage;
    if (remaining < bytes + 5 * 1024 * 1024) {
      throw new Error('This device does not have enough browser storage for every JSA photo. Free device space and try again.');
    }
  }

  function statusBox(formId, id) {
    let box = byId(id);
    if (box) return box;
    const form = byId(formId);
    if (!form) return null;
    box = document.createElement('div');
    box.id = id;
    box.style.cssText = 'display:none;margin:0 0 12px;padding:10px 12px;border-radius:10px;font-weight:800;font-size:13px';
    form.insertBefore(box, form.firstChild);
    return box;
  }

  function setStatus(text, type = 'pending', formId = 'safetyJsaForm', id = 'offlineJsaStatus') {
    const box = statusBox(formId, id);
    if (!box) return;
    box.style.display = 'block';
    box.textContent = text;
    box.style.background = type === 'synced' ? '#eaf7ef' : type === 'error' ? '#fff0f0' : '#fff4da';
    box.style.border = `1px solid ${type === 'synced' ? '#79bd91' : type === 'error' ? '#d99595' : '#e3b64c'}`;
    box.style.color = type === 'synced' ? '#155d2d' : type === 'error' ? '#7c1f1f' : '#6a4300';
  }

  function currentIdentityMatches(item) {
    const profile = getProfile();
    return Boolean(profile?.id && profile?.company_id && item.user_id === profile.id && item.company_id === profile.company_id);
  }

  async function renderQueueCount() {
    const profile = getProfile();
    const rows = await all().catch(() => []);
    const count = rows.filter((item) => item.status !== 'synced' && (!profile?.id || item.user_id === profile.id)).length;
    let pill = byId('offlineJsaQueuePill');
    const card = byId('safetyPage')?.querySelector('.section-header,.card');
    if (!pill && card) {
      pill = document.createElement('span');
      pill.id = 'offlineJsaQueuePill';
      pill.style.cssText = 'display:none;margin-left:8px;padding:4px 8px;border-radius:999px;background:#fff4da;border:1px solid #e3b64c;color:#6a4300;font-size:12px;font-weight:800';
      card.appendChild(pill);
    }
    if (pill) {
      pill.style.display = count ? 'inline-block' : 'none';
      pill.textContent = `${count} JSA${count === 1 ? '' : 's'} waiting to sync`;
    }
  }

  function collectTasks() {
    return [...document.querySelectorAll('#jsaTaskRows .lc-jsa-task')].map((row) => ({
      job_task: row.querySelector('.jsa-task-name')?.value.trim() || '',
      hazards: row.querySelector('.jsa-task-hazards')?.value.trim() || '',
      mitigation: row.querySelector('.jsa-task-mitigation')?.value.trim() || ''
    })).filter((row) => row.job_task || row.hazards || row.mitigation);
  }

  function collectCrew() {
    const names = [...document.querySelectorAll('.jsa-printed-name-input')];
    const signatures = [...document.querySelectorAll('.jsa-signature-input')];
    return names.map((name, index) => ({
      printed_name: name.value.trim(),
      signature: signatures[index]?.value.trim() || ''
    })).filter((row) => row.printed_name || row.signature);
  }

  function validateDigital() {
    const tasks = collectTasks();
    const crew = collectCrew();
    if (!value('safetyJsaJob') || !value('safetyJsaDate') || !value('safetyJsaTime') || !value('safetyJsaCrew') || !value('safetyJsaLeader')) return 'Complete Job, Date, Time, Crew, and JSA Leader.';
    if (!tasks.some((row) => row.job_task && row.hazards && row.mitigation)) return 'Complete at least one Job Task / Hazards / Mitigation row.';
    if (!crew.some((row) => row.printed_name && row.signature)) return 'Enter at least one crew member printed name and signature.';
    if (!value('jsaPersonInChargeName') || !value('jsaPersonInChargeSignature')) return 'Complete the JSA Leader / Person in Charge name and signature.';
    if (!byId('safetyJsaAcknowledged')?.checked) return 'Check the final JSA certification before saving.';
    return '';
  }

  function digitalPayload(clientId, attemptedAt) {
    const tasks = collectTasks();
    const crew = collectCrew();
    const details = window.LineCrewExpandedJsa?.detailsPayload?.() || {};
    details.offline_submission = { client_submission_id: clientId, attempted_at: attemptedAt, synced_at: null, device_recorded: true };
    const emergency = [
      value('jsaLocalEmergency') && `Local Emergency: ${value('jsaLocalEmergency')}`,
      value('jsaMedicalFacilityName') && `Medical Facility: ${value('jsaMedicalFacilityName')}`,
      value('jsaMedicalFacilityAddress') && `Address: ${value('jsaMedicalFacilityAddress')}`,
      value('jsaEmergencyMeetingPoint') && `Meeting Point: ${value('jsaEmergencyMeetingPoint')}`
    ].filter(Boolean).join(' | ') || 'See expanded JSA details.';
    return {
      p_client_submission_id: clientId,
      p_job_id: value('safetyJsaJob'),
      p_work_date: value('safetyJsaDate'),
      p_crew_name: value('safetyJsaCrew'),
      p_job_briefing: tasks.map((row, index) => `${index + 1}. ${row.job_task}`).join('\n') || 'See expanded JSA details.',
      p_hazards: tasks.map((row, index) => `${index + 1}. ${row.hazards}`).join('\n') || 'See expanded JSA details.',
      p_controls: tasks.map((row, index) => `${index + 1}. ${row.mitigation}`).join('\n') || 'See expanded JSA details.',
      p_ppe: checked('jsaPpeItem').join(', ') || 'See expanded JSA details.',
      p_emergency_plan: emergency,
      p_crew_members: crew.map((row) => `${row.printed_name}${row.signature ? ` | Signature: ${row.signature}` : ''}`).join('\n'),
      p_weather_conditions: value('safetyJsaWeather') || null,
      p_special_equipment: value('safetyJsaEquipment') || null,
      p_foreman_acknowledged: true,
      p_details: details
    };
  }

  function uploadFiles() {
    try {
      if (typeof getCompanyJsaUploadFiles === 'function') return [...getCompanyJsaUploadFiles()];
    } catch (_) {}
    return [...(byId('companyJsaUploadFiles')?.files || [])];
  }

  function allowedFile(file) {
    return ['application/pdf', 'image/jpeg', 'image/png', 'image/heic', 'image/heif'].includes(String(file?.type || '').toLowerCase()) && file.size > 0 && file.size <= MAX_FILE_BYTES;
  }

  function safeFilename(name) {
    return String(name || 'jsa-file').replace(/[^a-zA-Z0-9._-]+/g, '-').replace(/^-+|-+$/g, '').slice(-140) || 'jsa-file';
  }

  function validationMessage(targetId, message) {
    const target = byId(targetId);
    if (target) {
      target.textContent = message;
      target.className = 'message error';
    } else {
      alert(message);
    }
    toast(message, 'warning');
  }

  async function queueDigital() {
    console.info('[offline-jsa] Digital JSA save requested.', { online: navigator.onLine });
    const error = validateDigital();
    if (error) { validationMessage('safetyJsaMsg', error); return; }
    const profile = getProfile();
    if (!profile?.id || !profile?.company_id) { validationMessage('safetyJsaMsg', 'Your signed-in profile is not available. Reopen LineCrew Pro and try again.'); return; }
    const button = byId('saveSafetyJsaBtn');
    if (button?.dataset.lcOutboxBusy === '1') return;
    if (button) { button.dataset.lcOutboxBusy = '1'; button.disabled = true; button.textContent = 'Securing JSA...'; }
    try {
      const id = uuid();
      const attemptedAt = new Date().toISOString();
      const item = {
        id, type: 'digital', status: 'pending', company_id: profile.company_id, user_id: profile.id,
        attempted_at: attemptedAt, created_at: attemptedAt, attempt_count: 0, next_attempt_at: null,
        payload: digitalPayload(id, attemptedAt)
      };
      await ensureCapacity(JSON.stringify(item).length * 2);
      await put(item);
      navigator.storage?.persist?.().catch(() => false);
      await renderQueueCount();
      setStatus(`JSA secured on this device at ${new Date(attemptedAt).toLocaleString()}. Sending when service is available.`);
      const msg = byId('safetyJsaMsg');
      if (msg) { msg.textContent = 'Complete JSA and signatures saved safely on this device.'; msg.className = 'message success'; }
      byId('safetyJsaForm')?.classList.add('hidden');
      byId('createJsaBtn')?.classList.remove('hidden');
      toast('Complete JSA saved safely. LineCrew Pro will sync it automatically.', 'success');
      void syncQueue(true);
    } catch (saveError) {
      console.error('[offline-jsa] Device save failed.', saveError);
      validationMessage('safetyJsaMsg', saveError?.message || 'This JSA could not be secured on the device. Do not close the form.');
      setStatus('The JSA is still on screen but was not saved to device storage. Do not close it.', 'error');
    } finally {
      if (button) { button.dataset.lcOutboxBusy = '0'; button.disabled = false; button.textContent = 'Save JSA'; }
    }
  }

  async function queueUpload() {
    const jobId = value('companyJsaUploadJob');
    const workDate = value('companyJsaUploadDate');
    const crew = value('companyJsaUploadCrew');
    const notes = value('companyJsaUploadNotes');
    const files = uploadFiles();
    if (!jobId || !workDate || !crew) { alert('Job, work date and crew are required.'); return; }
    if (!files.length) { alert('Choose at least one PDF or JSA photo.'); return; }
    const invalid = files.find((file) => !allowedFile(file));
    if (invalid) { alert(`Unsupported or oversized file: ${invalid.name}. Use PDF/JPG/PNG/HEIC up to 15 MB each.`); return; }
    const profile = getProfile();
    if (!profile?.id || !profile?.company_id) { alert('Your signed-in profile is not available. Reopen LineCrew Pro and try again.'); return; }
    const button = byId('saveCompanyJsaUploadBtn');
    if (button?.dataset.lcOutboxBusy === '1') return;
    if (button) { button.dataset.lcOutboxBusy = '1'; button.disabled = true; button.textContent = 'Securing JSA Pages...'; }
    try {
      const totalBytes = files.reduce((sum, file) => sum + file.size, 0);
      await ensureCapacity(totalBytes);
      const id = uuid();
      const attemptedAt = new Date().toISOString();
      const attachments = files.map((file, index) => ({
        id: uuid(), name: file.name || `jsa-page-${index + 1}`, type: file.type,
        size: file.size, last_modified: file.lastModified || null, page_order: index + 1,
        blob: file, uploaded: false, registered: false
      }));
      await put({
        id, type: 'upload', status: 'pending', company_id: profile.company_id, user_id: profile.id,
        attempted_at: attemptedAt, created_at: attemptedAt, attempt_count: 0, next_attempt_at: null,
        payload: { p_client_submission_id: id, p_job_id: jobId, p_work_date: workDate, p_crew_name: crew, p_notes: notes || null },
        attachments
      });
      navigator.storage?.persist?.().catch(() => false);
      await renderQueueCount();
      setStatus(
        `${files.length} JSA page${files.length === 1 ? '' : 's'} secured on this device. Sending when service is available.`,
        'pending', 'companyJsaUploadForm', 'offlineJsaUploadStatus'
      );
      byId('companyJsaUploadForm')?.classList.add('hidden');
      try { if (typeof resetCompanyJsaCameraFiles === 'function') resetCompanyJsaCameraFiles(); } catch (_) {}
      if (byId('companyJsaUploadFiles')) byId('companyJsaUploadFiles').value = '';
      toast(`Complete uploaded JSA saved safely with ${files.length} page${files.length === 1 ? '' : 's'}.`, 'success');
      void syncQueue(true);
    } catch (saveError) {
      const status = byId('companyJsaUploadStatus');
      if (status) status.textContent = saveError?.message || 'The JSA pages could not be secured. Do not close the form.';
      setStatus('The JSA is still on screen but its pages were not saved to device storage. Do not close it.', 'error', 'companyJsaUploadForm', 'offlineJsaUploadStatus');
    } finally {
      if (button) { button.dataset.lcOutboxBusy = '0'; button.disabled = false; button.textContent = 'Save Uploaded JSA'; }
    }
  }

  function isDuplicateUpload(error) {
    const text = `${error?.error || ''} ${error?.message || ''}`.toLowerCase();
    return Number(error?.statusCode || error?.status) === 409 || text.includes('duplicate') || text.includes('already exists');
  }

  async function syncDigital(client, item) {
    const payload = JSON.parse(JSON.stringify(item.payload));
    payload.p_client_submission_id = item.id;
    payload.p_details = payload.p_details || {};
    payload.p_details.offline_submission = {
      ...(payload.p_details.offline_submission || {}),
      client_submission_id: item.id,
      attempted_at: item.attempted_at,
      synced_at: new Date().toISOString(),
      device_recorded: true
    };
    const result = await client.rpc('create_standalone_jsa_offline', payload);
    if (result.error) throw result.error;
    return result.data;
  }

  async function syncUpload(client, item) {
    let changed = false;
    if (!item.server_id) {
      const result = await client.rpc('create_uploaded_company_jsa_offline', item.payload);
      if (result.error) throw result.error;
      item.server_id = result.data;
      changed = true;
      await put(item);
    }
    for (const attachment of item.attachments || []) {
      const path = `${item.company_id}/${item.server_id}/${attachment.id}-${safeFilename(attachment.name)}`;
      attachment.storage_path = path;
      if (!attachment.uploaded) {
        const upload = await client.storage.from('jsa-uploads').upload(path, attachment.blob, {
          upsert: false,
          contentType: attachment.type
        });
        if (upload.error && !isDuplicateUpload(upload.error)) throw upload.error;
        attachment.uploaded = true;
        changed = true;
        await put(item);
      }
      if (!attachment.registered) {
        const registration = await client.rpc('register_jsa_upload_attachment', {
          p_jsa_id: item.server_id,
          p_storage_path: path,
          p_original_filename: attachment.name,
          p_mime_type: attachment.type,
          p_file_size_bytes: attachment.size,
          p_page_order: attachment.page_order
        });
        if (registration.error) throw registration.error;
        attachment.registered = true;
        changed = true;
        await put(item);
      }
    }
    if ((item.attachments || []).some((attachment) => !attachment.uploaded || !attachment.registered)) {
      throw new Error('One or more JSA pages have not been confirmed yet.');
    }
    return { serverId: item.server_id, changed };
  }

  function backoff(attemptCount) {
    return Math.min(MAX_BACKOFF_MS, 5000 * (2 ** Math.min(Math.max(attemptCount - 1, 0), 6)));
  }

  async function refreshSafetyViews() {
    try { if (typeof window.loadSafetyJsas === 'function') await window.loadSafetyJsas(); } catch (_) {}
    try { if (typeof window.loadUploadedCompanyJsas === 'function') await window.loadUploadedCompanyJsas(); } catch (_) {}
  }

  async function performSync(force = false) {
    if (!navigator.onLine) return;
    const client = getClient();
    const profile = getProfile();
    if (!client || !profile?.id || !profile?.company_id) return;
    const rows = (await all()).sort((a, b) => String(a.created_at).localeCompare(String(b.created_at)));
    for (const item of rows) {
      if (!currentIdentityMatches(item)) continue;
      if (!force && item.next_attempt_at && new Date(item.next_attempt_at).getTime() > Date.now()) continue;
      try {
        const serverId = item.type === 'upload'
          ? (await syncUpload(client, item)).serverId
          : await syncDigital(client, item);
        await remove(item.id);
        await renderQueueCount();
        if (item.type === 'upload') {
          setStatus(`Uploaded JSA and every page synced successfully.`, 'synced', 'companyJsaUploadForm', 'offlineJsaUploadStatus');
          toast('Uploaded JSA and every page synced to LineCrew Pro.', 'success');
        } else {
          setStatus(`Complete JSA synced successfully. Field submission time: ${new Date(item.attempted_at).toLocaleString()}.`, 'synced');
          toast('Complete JSA and signatures synced to LineCrew Pro.', 'success');
        }
        if (serverId) await refreshSafetyViews();
      } catch (error) {
        item.status = 'pending';
        item.attempt_count = Number(item.attempt_count || 0) + 1;
        item.last_error = error?.message || String(error);
        item.last_attempt_at = new Date().toISOString();
        item.next_attempt_at = new Date(Date.now() + backoff(item.attempt_count)).toISOString();
        await put(item);
        await renderQueueCount();
        break;
      }
    }
  }

  function syncQueue(force = false) {
    if (syncPromise) return syncPromise;
    syncPromise = performSync(force).finally(() => { syncPromise = null; });
    return syncPromise;
  }

  function cacheJobContext() {
    const profile = getProfile();
    if (!profile?.company_id) return;
    const options = [byId('safetyJsaJob'), byId('companyJsaUploadJob')]
      .flatMap((select) => select ? [...select.options] : [])
      .filter((option) => option.value)
      .map((option) => ({ id: option.value, label: option.textContent }));
    const jobs = [...new Map(options.map((job) => [job.id, job])).values()];
    if (!jobs.length) return;
    try {
      localStorage.setItem(CONTEXT_KEY, JSON.stringify({ company_id: profile.company_id, user_id: profile.id, jobs, cached_at: new Date().toISOString() }));
    } catch (_) {}
  }

  function restoreJobs(selectId) {
    const profile = getProfile();
    const select = byId(selectId);
    if (!select || [...select.options].some((option) => option.value)) return;
    try {
      const context = JSON.parse(localStorage.getItem(CONTEXT_KEY) || 'null');
      if (!context || context.company_id !== profile?.company_id || context.user_id !== profile?.id) return;
      (context.jobs || []).forEach((job) => {
        const option = document.createElement('option');
        option.value = job.id;
        option.textContent = job.label;
        select.appendChild(option);
      });
    } catch (_) {}
  }

  async function migrateLegacyQueue() {
    let legacy = [];
    try { legacy = JSON.parse(localStorage.getItem(LEGACY_QUEUE_KEY) || '[]'); }
    catch (_) { return; }
    if (!Array.isArray(legacy) || !legacy.length) return;
    for (const old of legacy) {
      const id = uuid();
      const attemptedAt = old.attempted_at || new Date().toISOString();
      const payload = { ...(old.payload || {}), p_client_submission_id: id };
      payload.p_details = payload.p_details || {};
      payload.p_details.offline_submission = {
        ...(payload.p_details.offline_submission || {}), client_submission_id: id,
        attempted_at: attemptedAt, synced_at: null, device_recorded: true
      };
      await put({
        id, type: 'digital', status: 'pending', company_id: old.company_id, user_id: old.user_id,
        attempted_at: attemptedAt, created_at: attemptedAt, attempt_count: 0, next_attempt_at: null, payload
      });
    }
    localStorage.removeItem(LEGACY_QUEUE_KEY);
  }

  function bindButton(id, handler) {
    const button = byId(id);
    if (!button || button.dataset.lcOutboxBound === '1') return;
    button.dataset.lcOutboxBound = '1';
    button.addEventListener('click', (event) => {
      event.preventDefault();
      event.stopImmediatePropagation();
      void handler();
    }, true);
  }

  function bind() {
    bindButton('saveSafetyJsaBtn', queueDigital);
    bindButton('saveCompanyJsaUploadBtn', queueUpload);
    byId('createJsaBtn')?.addEventListener('click', () => setTimeout(() => {
      restoreJobs('safetyJsaJob');
      cacheJobContext();
    }, 100));
    byId('uploadCompanyJsaBtn')?.addEventListener('click', () => setTimeout(() => {
      restoreJobs('companyJsaUploadJob');
      cacheJobContext();
    }, 100));
  }

  function markColdStartReady() {
    if (!window.LineCrewOfflineColdStart) return;
    ['createJsaBtn', 'uploadCompanyJsaBtn'].forEach((id) => {
      const button = byId(id);
      if (!button) return;
      button.disabled = false;
      button.textContent = button.dataset.offlineReadyLabel || (id === 'createJsaBtn' ? '+ Complete Digital JSA' : '+ Upload Company JSA');
    });
    const banner = byId('offlineColdStartJsaBanner');
    if (banner) {
      const ready = document.createElement('div');
      ready.style.cssText = 'margin-top:8px;font-weight:800;color:#155d2d';
      ready.textContent = 'Offline JSA form and device storage are ready.';
      banner.appendChild(ready);
    }
  }

  async function init() {
    statusBox('safetyJsaForm', 'offlineJsaStatus');
    statusBox('companyJsaUploadForm', 'offlineJsaUploadStatus');
    bind();
    await migrateLegacyQueue().catch((error) => console.warn('Unable to migrate an older offline JSA queue:', error));
    await renderQueueCount();
    restoreJobs('safetyJsaJob');
    restoreJobs('companyJsaUploadJob');
    cacheJobContext();
    markColdStartReady();
    window.addEventListener('online', () => setTimeout(() => void syncQueue(true), 250));
    document.addEventListener('visibilitychange', () => { if (!document.hidden) void syncQueue(); });
    setInterval(() => { bind(); cacheJobContext(); void syncQueue(); }, 30000);
    setTimeout(() => void syncQueue(true), 1200);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => void init());
  else void init();

  window.LineCrewOfflineJsa = {
    sync: () => syncQueue(true),
    queueCount: async () => (await all()).filter((item) => item.status !== 'synced').length
  };
})();
