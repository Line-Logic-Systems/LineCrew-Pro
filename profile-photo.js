/* LineCrew Pro — private, self-managed profile photos. */
(() => {
  'use strict';

  const BUCKET = 'profile-photos';
  const MAX_SOURCE_BYTES = 10 * 1024 * 1024;
  const OUTPUT_SIZE = 512;
  let objectUrl = '';
  let signedPath = '';
  let signedUrl = '';

  const byId = id => document.getElementById(id);

  function profile() {
    try { return currentProfile || window.currentProfile || null; }
    catch (_) { return window.currentProfile || null; }
  }

  function initials(name) {
    return String(name || 'LC').split(/\s+/).filter(Boolean)
      .map(part => part[0]).slice(0, 2).join('').toUpperCase() || 'LC';
  }

  function setAvatar(url = '') {
    const avatar = document.querySelector('.lc-shell-account__avatar');
    if (!avatar) return;
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
    fallback.textContent = initials(byId('userName')?.textContent || profile()?.full_name);
    image.src = url;
    image.classList.toggle('hidden', !url);
    fallback.classList.toggle('hidden', Boolean(url));
  }

  async function refreshAvatar(force = false) {
    const path = String(profile()?.avatar_path || '').trim();
    if (!path) {
      signedPath = '';
      signedUrl = '';
      setAvatar();
      return;
    }
    if (!force && path === signedPath && signedUrl) {
      setAvatar(signedUrl);
      return;
    }
    const { data, error } = await sb.storage.from(BUCKET).createSignedUrl(path, 3600);
    if (error) {
      console.warn('Unable to load profile photo.', error);
      setAvatar();
      return;
    }
    signedPath = path;
    signedUrl = data?.signedUrl || '';
    setAvatar(signedUrl);
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
  }

  async function uploadPhoto() {
    const input = byId('myProfilePhoto');
    const button = byId('uploadMyProfilePhoto');
    const file = input?.files?.[0];
    const current = profile();
    if (!file || !current?.id || !current?.company_id) return;
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
      if (profileError) throw profileError;
      current.avatar_path = path;
      input.value = '';
      showPreview();
      await refreshAvatar(true);
      alert('Your profile photo was updated.');
    } catch (error) {
      alert('Unable to update your profile photo: ' + (error?.message || error));
    } finally {
      button.disabled = false;
      button.textContent = 'Upload Photo';
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
      setAvatar();
    } catch (error) {
      alert('Unable to remove your profile photo: ' + (error?.message || error));
    } finally {
      button.disabled = false;
    }
  }

  function init() {
    byId('myProfilePhoto')?.addEventListener('change', event => showPreview(event.target.files?.[0]));
    byId('uploadMyProfilePhoto')?.addEventListener('click', uploadPhoto);
    byId('removeMyProfilePhoto')?.addEventListener('click', removePhoto);
    document.addEventListener('click', () => setTimeout(refreshAvatar, 0));
    [300, 900, 1800].forEach(delay => setTimeout(refreshAvatar, delay));
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();
})();
