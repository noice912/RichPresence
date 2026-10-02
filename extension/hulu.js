// Hulu: the player page is /watch/<id>. Its metadata overlay names the show and the episode
// ("S1 E3 - Episode name"); class names carry build suffixes, so they're matched by prefix.
const HU = { byPath: {} };

function huFromOverlay() {
  const title = RP.text(
    '[class*="PlayerMetadata__titleText"]',
    '[data-automationid="player-metadata-title"]',
    '[class*="PlayerMetadata__title"]'
  );
  const episode = RP.text(
    '[class*="PlayerMetadata__subTitle"]',
    '[data-automationid="player-metadata-subtitle"]',
    '[class*="PlayerMetadata__secondaryText"]'
  );
  return title ? { title, episode } : null;
}

RP.every(2000, () => {
  const video = RP.video();
  if (!location.pathname.startsWith('/watch') || !video) return RP.stop('Hulu');
  const seen = huFromOverlay();
  if (seen) HU.byPath[location.pathname] = seen;
  const s = RP.session();
  const got = HU.byPath[location.pathname] || { title: s.title, episode: s.artist };
  RP.report('Hulu', got.title, got.episode, video);
});
