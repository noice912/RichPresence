// One entry per streaming site. For each site:
//   service  - the name RichPresence knows it by
//   player() - true on the page where a video is being watched
//   read()   - { title, episode, image } from the player (any of them may be empty)
//   marks    - how the site names itself in its tab title (for the fallback below)
// When read() finds no title, the page's media info (navigator.mediaSession) and then the tab title are used.
const path = () => location.pathname;
const remember = {};          // per page: the last title seen, for when the player overlay hides

const SITES = [
  {
    hosts: /(^|\.)netflix\.com$/, service: 'Netflix', marks: ['Netflix'],
    player: () => /^\/watch\/\d+/.test(path()),
    async read() {
      // the title overlay: <h4>show</h4><span>S4:E1</span><span>episode</span>, or just the movie title
      const box = document.querySelector('[data-uia="video-title"]');
      if (box) {
        const h = box.querySelector('h4');
        if (h) return { title: h.textContent.trim(), episode: [...box.querySelectorAll('span')].map(s => s.textContent.replace(/\s+/g, ' ').trim()).filter(Boolean).join(' ') };
        const t = box.textContent.replace(/\s+/g, ' ').trim();
        if (t) return { title: t, episode: '' };
      }
      return netflixLookup(path().match(/^\/watch\/(\d+)/)[1]);
    }
  },
  {
    hosts: /(^|\.)hulu\.com$/, service: 'Hulu', marks: ['Hulu'],
    player: () => path().startsWith('/watch'),
    read: () => ({
      title: RP.text('[class*="PlayerMetadata__titleText"]', '[data-automationid="player-metadata-title"]', '[class*="PlayerMetadata__title"]'),
      episode: RP.text('[class*="PlayerMetadata__subTitle"]', '[data-automationid="player-metadata-subtitle"]', '[class*="PlayerMetadata__secondaryText"]')
    })
  },
  {
    hosts: /(^|\.)disneyplus\.com$/, service: 'Disney+', marks: ['Disney+'],
    player: () => /^\/(.*\/)?(play|video)\//.test(path()),
    read: () => ({
      title: RP.text('[data-testid="title-field"]', '.title-field'),
      episode: RP.text('[data-testid="subtitle-field"]', '.subtitle-field')
    })
  },
  {
    hosts: /(^|\.)(primevideo\.com|amazon\.(com|ca|co\.uk|de|fr|it|es|co\.jp|in|com\.au|com\.br|com\.mx))$/, service: 'Prime Video', marks: ['Prime Video', 'Amazon.com'],
    // on amazon.* only the Prime Video player counts, never product videos
    player: () => !!document.querySelector('[class*="atvwebplayersdk"]'),
    read: () => ({
      title: RP.text('.atvwebplayersdk-title-text'),
      episode: RP.text('.atvwebplayersdk-subtitle-text')
    })
  },
  {
    hosts: /(^|\.)(max\.com|hbomax\.com)$/, service: 'Max', marks: ['Max', 'HBO Max'],
    player: () => path().includes('/video/watch/') || path().startsWith('/player'),
    read: () => ({
      title: RP.text('[data-testid="player-ux-asset-title"]', '[class*="AssetTitle"]'),
      episode: RP.text('[data-testid="player-ux-asset-subtitle"]', '[class*="AssetSubtitle"]')
    })
  },
  {
    hosts: /(^|\.)crunchyroll\.com$/, service: 'Crunchyroll', marks: ['Crunchyroll'],
    player: () => path().includes('/watch/'),
    frames: ['https://static.crunchyroll.com'],     // the video plays in this embedded frame (see frame.js)
    read: () => ({
      title: RP.text('.show-title-link h4', 'a.show-title-link', '[data-t="show-title-link"]'),
      episode: RP.text('h1.title', '[data-t="episode-title"]')
    })
  },
  {
    hosts: /(^|\.)paramountplus\.com$/, service: 'Paramount+', marks: ['Paramount+'],
    player: () => /\/video\//.test(path()),
    read: () => ({ title: RP.text('[class*="header__title"]', '[class*="video-title"]'), episode: RP.text('[class*="header__subtitle"]') })
  },
  {
    hosts: /(^|\.)peacocktv\.com$/, service: 'Peacock', marks: ['Peacock'],
    player: () => path().includes('/watch/playback') || path().includes('/watch/'),
    read: () => ({ title: RP.text('[data-testid="playback-title"]', '[class*="playback-title"]'), episode: RP.text('[data-testid="playback-subtitle"]', '[class*="playback-subtitle"]') })
  },
  {
    hosts: /^tv\.apple\.com$/, service: 'Apple TV+', marks: ['Apple TV+', 'Apple TV'], deep: true,
    player: () => !!RP.video(true),
    read: () => ({ title: '', episode: '' })            // Apple sets the page's media info; the fallback reads it
  },
  {
    hosts: /^app\.plex\.tv$/, service: 'Plex', marks: ['Plex'],
    player: () => !!document.querySelector('[class*="Player"]'),
    read: () => {
      const links = [...document.querySelectorAll('[class*="PlayerControlsMetadata"] a')].map(a => a.textContent.trim()).filter(Boolean);
      return { title: links[0] || '', episode: links[1] || '' };
    }
  },
  {
    hosts: /^(www|m)\.youtube\.com$/, service: 'YouTube', marks: ['YouTube'],
    player: () => path() === '/watch' || path().startsWith('/live/'),
    read: () => {
      const id = new URLSearchParams(location.search).get('v');
      return {
        title: RP.text('h1.ytd-watch-metadata yt-formatted-string', 'h1.ytd-watch-metadata', '#title h1'),
        episode: RP.text('ytd-watch-metadata #channel-name a', '#owner #channel-name a', 'ytd-channel-name a'),
        image: id && /^[\w-]{6,20}$/.test(id) ? `https://i.ytimg.com/vi/${id}/hqdefault.jpg` : ''
      };
    }
  },
  {
    hosts: /^(www|m)\.twitch\.tv$/, service: 'Twitch', marks: ['Twitch'],
    // a channel page (/name) or one of its videos, not Twitch's own pages
    player: () => (/^\/[\w]{3,25}\/?$/.test(path()) && !/^\/(directory|settings|subscriptions|inventory|drops|wallet|downloads|search|following|turbo|jobs|prime|store)\/?$/i.test(path())) || path().startsWith('/videos/'),
    read: () => {
      const login = (path().match(/^\/([\w]{3,25})\/?$/) || [])[1];
      return {
        title: RP.text('[data-a-target="stream-info-card-component-channel-name"] h1', '.channel-info-content h1', 'h1.tw-title') || login || '',
        episode: RP.text('[data-a-target="stream-title"]'),
        image: login ? `https://static-cdn.jtvnw.net/previews-ttv/live_user_${login.toLowerCase()}-640x360.jpg` : ''
      };
    }
  }
];

// Netflix's own website loads this with your session; used before the title overlay first appears
const nfAsked = {};
async function netflixLookup(id) {
  if (remember['nf' + id]) return remember['nf' + id];
  if (nfAsked[id]) return null;
  nfAsked[id] = true;
  try {
    const r = await fetch(`/nq/website/memberapi/release/metadata?movieid=${id}`, { credentials: 'include' });
    if (!r.ok) return null;
    const v = (await r.json()).video;
    if (!v || !v.title) return null;
    let episode = '';
    for (const s of (v.type === 'show' && v.seasons) || []) {
      for (const e of s.episodes || []) {
        if (String(e.id) === id || String(e.episodeId) === id) episode = `S${s.seq}:E${e.seq} ${e.title || ''}`.trim();
      }
    }
    return (remember['nf' + id] = { title: v.title, episode });
  } catch (e) { return null; }
}

const SITE = SITES.find(s => s.hosts.test(location.hostname));
if (SITE) {
  // an embedded player frame can tell us whether its video is playing
  if (SITE.frames) {
    window.addEventListener('message', (e) => {
      if (SITE.frames.includes(e.origin) && e.data && e.data.__richpresence) {
        RP.remote = { paused: !!e.data.paused, ended: !!e.data.ended, currentTime: +e.data.currentTime || 0, duration: +e.data.duration || 0, at: Date.now() };
      }
    });
  }
  RP.every(2000, async () => {
    const video = SITE.player() ? RP.video(SITE.deep) : null;
    if (!video) return RP.stop(SITE.service);
    let got = (await SITE.read()) || {};
    const key = location.pathname + location.search;
    if (got.title) remember[key] = got;
    else if (remember[key]) got = remember[key];
    else {
      // fallbacks: the page's media info, then the tab title
      const s = RP.session();
      got = { title: RP.cleanTitle(s.title, SITE.marks) || RP.cleanTitle(document.title, SITE.marks), episode: s.title ? s.artist : '', image: got.image };
    }
    RP.report(SITE.service, got.title, got.episode, video, got.image);
  });
}
