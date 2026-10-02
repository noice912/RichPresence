// Shared by the Netflix and Hulu scripts. Every 2 seconds the site script looks at the player page and
// calls RP.report(); a change (or every 10 s while it stays the same) is handed to background.js, which
// passes it to the RichPresence app on this PC. Nothing is sent anywhere else.
const RP = {
  lastKey: '',
  lastSent: 0,
  stopped: true,

  // the biggest <video> on the page is the one being watched
  video() {
    const vids = [...document.querySelectorAll('video')].filter(v => v.duration > 0 || v.readyState > 0);
    vids.sort((a, b) => (b.videoWidth * b.videoHeight) - (a.videoWidth * a.videoHeight));
    return vids[0] || null;
  },

  // text of the first element that matches one of the selectors, tidied up
  text(...selectors) {
    for (const sel of selectors) {
      const el = document.querySelector(sel);
      const t = el && el.textContent.replace(/\s+/g, ' ').trim();
      if (t) return t;
    }
    return '';
  },

  // what the page told the browser about the video (empty on most streaming sites, but cheap to check)
  session() {
    try {
      const m = navigator.mediaSession && navigator.mediaSession.metadata;
      if (m) return { title: (m.title || '').trim(), artist: (m.artist || '').trim() };
    } catch (e) {}
    return { title: '', artist: '' };
  },

  report(service, title, episode, video) {
    const info = {
      service,
      title: (title || '').slice(0, 128),
      episode: (episode || '').slice(0, 128),
      playing: !!video && !video.paused && !video.ended,
      position: video && isFinite(video.currentTime) ? video.currentTime : 0,
      duration: video && isFinite(video.duration) ? video.duration : 0
    };
    const key = JSON.stringify([info.service, info.title, info.episode, info.playing]);
    const now = Date.now();
    this.stopped = false;
    if (key === this.lastKey && now - this.lastSent < 10000) return;
    this.lastKey = key; this.lastSent = now;
    this.post(info);
  },

  // left the player page or closed the video: say so once
  stop(service) {
    if (this.stopped) return;
    this.stopped = true; this.lastKey = '';
    this.post({ service, title: '', episode: '', playing: false, position: 0, duration: 0 });
  },

  post(info) {
    try { chrome.runtime.sendMessage({ type: 'watching', info }); } catch (e) {}
  },

  every(ms, fn) {
    const run = async () => { try { await fn(); } catch (e) {} };
    run();
    setInterval(run, ms);
  }
};
