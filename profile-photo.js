/* LineCrew Pro — private, self-managed profile photos. */
(() => {
  'use strict';

  const BUCKET = 'profile-photos';
  const MAX_SOURCE_BYTES = 10 * 1024 * 1024;
  const OUTPUT_SIZE = 512;
  let objectUrl = '';
  let signedPath = '';
  let signedUrl = '';
  let signedAt = 0;
  let refreshPromise = null;
  let retryAfter = 0;
  let selectedFile = null;

  const byId = id => document.getElementById(id);

  function profile() {
    try { return currentProfile || window.currentProfile || null; }
    catch (_) { return window.currentProfile || null; }
  }

  function initials(name) {
    return String(name || 'LC').split(/\s+/).filter(Boolean)
      .map(part => part[0]).slice(0, 2).join('').toUpperCase() || 'LC';
  }

  function ensureMobileAvatar() {
    const name = byId('userName');
    if (!name || byId('lcMobileProfileAvatar')) return;
    const avatar = document.createElement('span');
    avatar.id = 'lcMobileProfileAvatar';
    avatar.className = 'lc-mobile-profile-avatar';
    avatar.setAttribute('aria-hidden', 'true');
    name.before(avatar);
  }

  function setOneAvatar(avatar, url = '') {
    let image = avatar.querySelector('img');
    let fallback = avatar.querySelector('span');
    if (!image) {
      const existing = avatar.textContent;
      avatar.textContent = '';
      image = document.createElement('img');
      image.alt = '';
      fallback = document.createElement('span');
      fallback.textContent = existing || initials(profile()?.full_name);
      avatar.append(image, fallback);
    }
    const fallbackText = initials(byId('userName')?.textContent || profile()?.full_name);
    if (fallback.textContent !== fallbackText) fallback.textContent = fallbackText;
    image.onerror = () => {
      image.classList.add('hidden');
      fallback.classList.remove('hidden');
    };
    if (url && image.src !== url) image.src = url;
    if (!url) image.removeAttribute('src');
    image.classList.toggle('hidden', !url);
    fallback.classList.toggle('hidden', Boolean(url));
  }

  function setAvatar(url = '') {
    ensureMobileAvatar();
    document.querySelectorAll('.lc-shell-account__avatar, .lc-mobile-profile-avatar')
      .forEach(avatar => setOneAvatar(avatar, url));
  }

  async function refreshAvatar(force = false) {
    const path = String(profile()?.avatar_path || '').trim();
    if (!path) {
      signedPath = '';
      signedUrl = '';
      signedAt = 0;
      retryAfter = 0;
      setAvatar();
      return;
    }
    const now = Date.now();
    if (!force && path === signedPath && signedUrl && now - signedAt < 50 * 60 * 1000) {
      setAvatar(signedUrl);
      return;
    }
    if (!force && now < retryAfter) return;
    if (refreshPromise) return refreshPromise;
    refreshPromise = (async () => {
      const { data, error } = await sb.storage.from(BUCKET).createSignedUrl(path, 3600);
      if (error) {
        console.warn('Unable to load profile photo.', error);
        signedPath = path;
        signedUrl = '';
        signedAt = 0;
        retryAfter = Date.now() + 60 * 1000;
        setAvatar();
        return;
      }
      signedPath = path;
      signedUrl = data?.signedUrl || '';
      signedAt = Date.now();
      retryAfter = 0;
      setAvatar(signedUrl);
    })().finally(() => { refreshPromise = null; });
    return refreshPromise;
  }

  function loadImage(file) {
    return new Promise((resolve, reject) => {
      const url = URL.createObjectURL(file);
      const image = new Image();
      image.onload = () => { URL.revokeObjectURL(url); resolve(image); };
      image.onerror = () => { URL.revokeObjectURL(url); reject(new Error('The selected image could not be opened.')); };
      image.src = url;
    });
  }

  async function cropPhoto(file) {
    if (!file?.type?.startsWith('image/')) throw new Error('Choose a JPG, PNG, or WebP image.');
    if (file.size > MAX_SOURCE_BYTES) throw new Error('Choose an image smaller than 10 MB.');
    const image = await loadImage(file);
    const side = Math.min(image.naturalWidth, image.naturalHeight);
    const sx = (image.naturalWidth - side) / 2;
    const sy = (image.naturalHeight - side) / 2;
    const canvas = document.createElement('canvas');
    canvas.width = OUTPUT_SIZE;
    canvas.height = OUTPUT_SIZE;
    canvas.getContext('2d').drawImage(image, sx, sy, side, side, 0, 0, OUTPUT_SIZE, OUTPUT_SIZE);
    return new Promise((resolve, reject) => canvas.toBlob(
      blob => blob ? resolve(blob) : reject(new Error('The image could not be prepared.')),
      'image/jpeg', .86
    ));
  }

  function showPreview(file) {
    if (objectUrl) URL.revokeObjectURL(objectUrl);
    objectUrl = file ? URL.createObjectURL(file) : '';
    const preview = byId('myProfilePhotoPreview');
    if (!preview) return;
    preview.src = objectUrl;
    preview.classList.toggle('hidden', !objectUrl);
    const selection = byId('myProfilePhotoSelection');
    if (selection) selection.textContent = file ? `Selected: ${file.name || 'camera photo'}` : 'No new photo selected.';
    const upload = byId('uploadMyProfilePhoto');
    if (upload) upload.disabled = !file;
  }

  function selectPhoto(file) {
    selectedFile = file || null;
    showPreview(selectedFile);
  }

  async function uploadPhoto() {
    const button = byId('uploadMyProfilePhoto');
    const file = selectedFile;
    const current = profile();
    if (!file || !current?.id || !current?.company_id) return;
    const previousPath = String(current.avatar_path || '').trim();
    button.disabled = true;
    button.textContent = 'Uploading...';
    try {
      const blob = await cropPhoto(file);
      const path = `${current.company_id}/${current.id}/avatar.jpg`;
      const { error: uploadError } = await sb.storage.from(BUCKET).upload(path, blob, {
        contentType: 'image/jpeg', cacheControl: '3600', upsert: true
      });
      if (uploadError) throw uploadError;
      const { error: profileError } = await sb.rpc('update_my_profile_avatar', { p_avatar_path: path });
      if (profileError) {
        if (previousPath !== path) await sb.storage.from(BUCKET).remove([path]);
        throw profileError;
      }
      current.avatar_path = path;
      document.dispatchEvent(new CustomEvent('linecrew:profile-updated'));
      byId('myProfilePhoto').value = '';
      byId('myProfileCamera').value = '';
      selectedFile = null;
      showPreview(null);
      await refreshAvatar(true);
      alert('Your profile photo was updated.');
    } catch (error) {
      alert('Unable to update your profile photo: ' + (error?.message || error));
    } finally {
      button.disabled = !selectedFile;
      button.textContent = 'Use This Photo';
    }
  }

  async function removePhoto() {
    const current = profile();
    const path = String(current?.avatar_path || '').trim();
    if (!path || !confirm('Remove your profile photo?')) return;
    const button = byId('removeMyProfilePhoto');
    button.disabled = true;
    try {
      const { error: removeError } = await sb.storage.from(BUCKET).remove([path]);
      if (removeError) throw removeError;
      const { error: profileError } = await sb.rpc('update_my_profile_avatar', { p_avatar_path: null });
      if (profileError) throw profileError;
      current.avatar_path = null;
      signedPath = '';
      signedUrl = '';
      signedAt = 0;
      document.dispatchEvent(new CustomEvent('linecrew:profile-updated'));
      setAvatar();
    } catch (error) {
      alert('Unable to remove your profile photo: ' + (error?.message || error));
    } finally {
      button.disabled = false;
    }
  }

  function init() {
    byId('takeMyProfilePhoto')?.addEventListener('click', () => byId('myProfileCamera')?.click());
    byId('chooseMyProfilePhoto')?.addEventListener('click', () => byId('myProfilePhoto')?.click());
    byId('myProfileCamera')?.addEventListener('change', event => selectPhoto(event.target.files?.[0]));
    byId('myProfilePhoto')?.addEventListener('change', event => selectPhoto(event.target.files?.[0]));
    byId('uploadMyProfilePhoto')?.addEventListener('click', uploadPhoto);
    byId('removeMyProfilePhoto')?.addEventListener('click', removePhoto);
    window.addEventListener('focus', () => refreshAvatar());
    document.addEventListener('visibilitychange', () => { if (!document.hidden) refreshAvatar(); });
    document.addEventListener('linecrew:profile-updated', () => refreshAvatar(true));
    [300, 900, 1800].forEach(delay => setTimeout(refreshAvatar, delay));
    setInterval(refreshAvatar, 10 * 60 * 1000);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
