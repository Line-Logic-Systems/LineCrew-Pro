(() => {
  function trackVideoEvent(eventName, video, index) {
    const label =
      video.getAttribute('aria-label') ||
      video.getAttribute('data-analytics-name') ||
      `Video ${index + 1}`;

    window.gtag('event', eventName, {
      video_name: label,
      page_path: window.location.pathname,
    });
  }

  function connectVideoTracking() {
    document.querySelectorAll('video').forEach((video, index) => {
      let started = false;
      let completed = false;

      video.addEventListener('play', () => {
        if (started) return;
        started = true;
        trackVideoEvent('demo_video_started', video, index);
      });

      video.addEventListener('ended', () => {
        if (completed) return;
        completed = true;
        trackVideoEvent('demo_video_completed', video, index);
      });
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', connectVideoTracking, { once: true });
  } else {
    connectVideoTracking();
  }
})();
