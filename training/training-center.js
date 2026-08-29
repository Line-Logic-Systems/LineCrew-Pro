(function () {
  const ROLE_RANK = { foreman: 1, gf: 2, superintendent: 3, admin: 4, owner: 5 };
  const CATEGORIES = [
    ['welcome', 'Welcome & Overview'],
    ['foreman', 'Foreman Training'],
    ['gf', 'General Foreman Training'],
    ['superintendent', 'Superintendent Training'],
    ['admin', 'Admin Training'],
    ['owner', 'Owner Training']
  ];

  async function getAccess() {
    const sb = window.supabaseClient;
    if (!sb) throw new Error('Supabase client is not available.');
    const { data, error } = await sb.rpc('current_training_access');
    if (error) throw error;
    const row = Array.isArray(data) ? data[0] : data;
    if (!row || !row.can_train) {
      throw new Error('Training is available to active LineCrew Pro subscribers.');
    }
    return row;
  }

  async function loadVideos() {
    const sb = window.supabaseClient;
    const { data, error } = await sb
      .from('training_videos')
      .select('id,slug,title,description,category,sort_order,storage_path,duration_seconds,minimum_role')
      .eq('active', true)
      .order('category')
      .order('sort_order');
    if (error) throw error;
    return data || [];
  }

  async function loadProgress() {
    const sb = window.supabaseClient;
    const { data: { user } } = await sb.auth.getUser();
    if (!user) return new Map();
    const { data } = await sb
      .from('training_progress')
      .select('video_id,completed_at,last_position_seconds')
      .eq('user_id', user.id);
    return new Map((data || []).map((item) => [item.video_id, item]));
  }

  async function signedVideoUrl(path) {
    const sb = window.supabaseClient;
    const { data, error } = await sb.storage.from('training-videos').createSignedUrl(path, 900);
    if (error) throw error;
    return data.signedUrl;
  }

  async function saveProgress(videoId, seconds, completed) {
    const sb = window.supabaseClient;
    const access = await getAccess();
    const { data: { user } } = await sb.auth.getUser();
    if (!user) return;
    const now = new Date().toISOString();
    await sb.from('training_progress').upsert({
      company_id: access.company_id,
      user_id: user.id,
      video_id: videoId,
      started_at: now,
      completed_at: completed ? now : null,
      last_position_seconds: Math.max(0, Math.floor(seconds || 0)),
      updated_at: now
    }, { onConflict: 'user_id,video_id' });
  }

  function esc(value) {
    return String(value ?? '').replace(/[&<>'"]/g, (character) => ({
      '&': '&amp;',
      '<': '&lt;',
      '>': '&gt;',
      "'": '&#39;',
      '"': '&quot;'
    })[character]);
  }

  function duration(seconds) {
    if (!seconds) return '';
    return `${Math.max(1, Math.round(seconds / 60))} min`;
  }

  function roleLabel(role) {
    return role === 'gf'
      ? 'General Foreman'
      : role.charAt(0).toUpperCase() + role.slice(1);
  }

  function hero(role) {
    return `<div class="training-center-hero">
      <div>
        <div class="training-eyebrow">Subscriber Training</div>
        <h2>LineCrew Pro Training Center</h2>
        <p>Role-based training for your company. Access follows your LineCrew Pro role and subscription.</p>
      </div>
      <div class="training-access-pill">${esc(roleLabel(role))}</div>
    </div>`;
  }

  function renderEmpty(root, role) {
    root.innerHTML = `<section class="training-center-shell">
      ${hero(role)}
      <div class="training-empty" role="status">
        <span class="training-empty-icon" aria-hidden="true">▶</span>
        <div>
          <h3>New training videos are being added</h3>
          <p>The previous videos were retired after recent LineCrew Pro updates. Fresh role-based training will appear here as each new video is published.</p>
        </div>
      </div>
    </section>`;
  }

  async function render(root) {
    root.innerHTML = '<div class="training-loading">Loading Training Center…</div>';
    try {
      const access = await getAccess();
      const [videos, progress] = await Promise.all([loadVideos(), loadProgress()]);
      const role = String(access.role || '').toLowerCase();
      const rank = ROLE_RANK[role] || 0;
      const groups = CATEGORIES
        .map(([key, label]) => ({
          key,
          label,
          videos: videos.filter((video) => (
            video.category === key && rank >= (ROLE_RANK[video.minimum_role] || 1)
          ))
        }))
        .filter((group) => group.videos.length);

      if (!groups.length) {
        renderEmpty(root, role);
        return;
      }

      root.innerHTML = `<section class="training-center-shell">
        ${hero(role)}
        <div class="training-groups">${groups.map((group) => `
          <section class="training-group">
            <h3>${esc(group.label)}</h3>
            <div class="training-grid">${group.videos.map((video) => {
              const saved = progress.get(video.id);
              return `<button class="training-card" data-training-video="${esc(video.id)}" data-path="${esc(video.storage_path)}" data-title="${esc(video.title)}">
                <span class="training-play">▶</span>
                <span class="training-card-copy">
                  <strong>${esc(video.title)}</strong>
                  <small>${esc(video.description || '')}</small>
                  <em>${duration(video.duration_seconds)}${saved?.completed_at ? ' • Completed' : ''}</em>
                </span>
              </button>`;
            }).join('')}</div>
          </section>`).join('')}</div>
        <div class="training-player-wrap" hidden>
          <button class="training-close" type="button">Close</button>
          <h3 class="training-player-title"></h3>
          <video class="training-player" controls playsinline preload="metadata"></video>
        </div>
      </section>`;

      const wrap = root.querySelector('.training-player-wrap');
      const player = root.querySelector('.training-player');
      const title = root.querySelector('.training-player-title');
      let currentVideoId = null;

      root.querySelectorAll('[data-training-video]').forEach((button) => button.addEventListener('click', async () => {
        currentVideoId = button.dataset.trainingVideo;
        title.textContent = button.dataset.title || 'Training Video';
        player.src = await signedVideoUrl(button.dataset.path);
        wrap.hidden = false;
        wrap.scrollIntoView({ behavior: 'smooth', block: 'start' });
        player.play().catch(() => {});
      }));

      player.addEventListener('timeupdate', () => {
        if (currentVideoId && Math.floor(player.currentTime) % 15 === 0) {
          saveProgress(currentVideoId, player.currentTime, false).catch(() => {});
        }
      });
      player.addEventListener('ended', () => {
        if (currentVideoId) saveProgress(currentVideoId, player.duration || player.currentTime, true);
      });
      root.querySelector('.training-close').addEventListener('click', () => {
        player.pause();
        player.removeAttribute('src');
        player.load();
        wrap.hidden = true;
      });
    } catch (error) {
      root.innerHTML = `<div class="training-denied"><h3>Training Center</h3><p>${esc(error.message || 'Training is not available for this account.')}</p></div>`;
    }
  }

  window.LineCrewTrainingCenter = { render };
}());
