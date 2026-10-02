// Shared helpers. Every 2 seconds sites.js looks at the player page and calls RP.report(); a change
// (or every 10 s while it stays the same) is handed to background.js, which passes it to the RichPresence
// app on this PC. Nothing is sent anywhere else.
const RP = {
  lastKey: '',
  lastSent: 0,
  stopped: true,
  remote: null,          // video state relayed from an embedded player frame (Crunchyroll)

  // the biggest <video> on the page is the one being watched; "deep" also looks inside shadow roots
  video(deep) {
    let vids = [...document.querySelectorAll('video')];
    if (deep && !vids.length) vids = RP.deepVideos(document, 0);
    vids = vids.filter(v => v.duration > 0 || v.readyState > 0);
    vids.sort((a, b) => (b.videoWidth * b.videoHeight) - (a.videoWidth * a.videoHeight));
    if (vids[0]) return vids[0];
    // a player in an embedded frame told us its state recently
    if (RP.remote && Date.now() - RP.remote.at < 6000) return RP.remote;
    return null;
  },
  deepVideos(root, depth) {
    if (depth > 6) return [];
    let out = [...root.querySelectorAll('video')];
    for (const el of root.querySelectorAll('*')) {
      if (el.shadowRoot) out = out.concat(RP.deepVideos(el.shadowRoot, depth + 1));
    }
    return out;
  },

  // text of the first element that matches one of the selectors, tidied up
  text(...selectors) {
    for (const sel of selectors) {
      let el = null;
      try { el = document.querySelector(sel); } catch (e) {}
      const t = el && el.textContent.replace(/\s+/g, ' ').trim();
      if (t) return t;
    }
    return '';
  },

  // what the page told the browser about the video
  session() {
    try {
      const m = navigator.mediaSession && navigator.mediaSession.metadata;
      if (m) return { title: (m.title || '').trim(), artist: (m.artist || '').trim() };
    } catch (e) {}
    return { title: '', artist: '' };
  },

  // "Watch Andor | Disney+" -> "Andor"; words that only name the page ("Watch", "Home") -> ''
  cleanTitle(t, marks) {
    t = (t || '').replace(/\s+/g, ' ').trim();
    const m = marks.map(x => x.replace(/[+.]/g, '\\$&')).join('|');
    t = t.replace(new RegExp(`^(${m})\\s*[:|\\-\\u2013\\u2014\\u2022]\\s*`, 'i'), '')
         .replace(new RegExp(`\\s*[:|\\-\\u2013\\u2014\\u2022]\\s*(${m})\\s*$`, 'i'), '')
         .replace(/^(watch|stream)\s+/i, '').replace(/\s+online$/i, '').trim();
    if (new RegExp(`^(${m})$`, 'i').test(t)) return '';
    if (/^(watch|watching|home|browse|player|play|video|videos|movies?|tv|series|shows?|search|details|stream)$/i.test(t)) return '';
    return t;
  },

  report(service, title, episode, video, image) {
    const info = {
      service,
      title: (title || '').slice(0, 128),
      episode: (episode || '').slice(0, 128),
      image: image || '',
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
    this.post({ service, title: '', episode: '', image: '', playing: false, position: 0, duration: 0 });
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
