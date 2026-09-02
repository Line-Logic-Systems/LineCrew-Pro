(() => {
  window.va = window.va || function () {
    (window.vaq = window.vaq || []).push(arguments);
  };

  function trackVideoEvent(eventName, video, index) {
    const label =
      video.getAttribute('aria-label') ||
      video.getAttribute('data-analytics-name') ||
      `Video ${index + 1}`;

    window.va('event', {
      name: eventName,
      data: {
        video: label,
        page: window.location.pathname,
      },
    });
  }

  function connectVideoTracking() {
    document.querySelectorAll('video').forEach((video, index) => {
      let started = false;
      let completed = false;

      video.addEventListener('play', () => {
        if (started) return;
        started = true;
        trackVideoEvent('Demo Video Started', video, index);
      });

      video.addEventListener('ended', () => {
        if (completed) return;
        completed = true;
        trackVideoEvent('Demo Video Completed', video, index);
      });
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', connectVideoTracking, { once: true });
  } else {
    connectVideoTracking();
  }
})();
