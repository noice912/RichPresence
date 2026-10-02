// Netflix: the player page is /watch/<id>. The title overlay ([data-uia="video-title"]) shows the show
// (<h4>) and the episode (<span>s) while the controls are visible; for the rest of the time the title is
// remembered, and Netflix's own metadata endpoint (the one its website uses, with your existing session)
// fills it in if the overlay hasn't appeared yet.
const NF = { byId: {}, asked: {} };

function nfFromOverlay() {
  const box = document.querySelector('[data-uia="video-title"]');
  if (!box) return null;
  const h = box.querySelector('h4');
  if (h) {
    const parts = [...box.querySelectorAll('span')].map(s => s.textContent.replace(/\s+/g, ' ').trim()).filter(Boolean);
    return { title: h.textContent.trim(), episode: parts.join(' ') };
  }
  const t = box.textContent.replace(/\s+/g, ' ').trim();     // movies: just the title
  return t ? { title: t, episode: '' } : null;
}

async function nfLookup(id) {
  if (NF.asked[id]) return;
  NF.asked[id] = true;
  try {
    const r = await fetch(`/nq/website/memberapi/release/metadata?movieid=${id}`, { credentials: 'include' });
    if (!r.ok) return;
    const v = (await r.json()).video;
    if (!v || !v.title) return;
    let episode = '';
    if (v.type === 'show') {
      for (const s of v.seasons || []) {
        for (const e of s.episodes || []) {
          if (String(e.id) === id || String(e.episodeId) === id) episode = `S${s.seq}:E${e.seq} ${e.title || ''}`.trim();
        }
      }
    }
    if (!NF.byId[id]) NF.byId[id] = { title: v.title, episode };
  } catch (e) {}
}

RP.every(2000, async () => {
  const m = location.pathname.match(/^\/watch\/(\d+)/);
  const video = RP.video();
  if (!m || !video) return RP.stop('Netflix');
  const id = m[1];
  const seen = nfFromOverlay();
  if (seen && seen.title) NF.byId[id] = seen;
  if (!NF.byId[id]) await nfLookup(id);
  const got = NF.byId[id] || { title: RP.session().title, episode: '' };
  RP.report('Netflix', got.title, got.episode, video);
});
