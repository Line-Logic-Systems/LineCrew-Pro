(() => {
  const measurementId = 'G-ZEMV5NWG5';

  window.dataLayer = window.dataLayer || [];
  window.gtag = window.gtag || function () {
    window.dataLayer.push(arguments);
  };

  window.gtag('js', new Date());
  window.gtag('config', measurementId);

  const googleTag = document.createElement('script');
  googleTag.async = true;
  googleTag.src = `https://www.googletagmanager.com/gtag/js?id=${encodeURIComponent(measurementId)}`;
  document.head.appendChild(googleTag);

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
