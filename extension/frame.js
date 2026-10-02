// Runs inside an embedded player frame (Crunchyroll's video plays in one). It can't see the show's name,
// so it only tells the page around it whether the video is playing; sites.js does the rest.
const PARENTS = { 'static.crunchyroll.com': 'https://www.crunchyroll.com' };
const parentOrigin = PARENTS[location.hostname];
if (parentOrigin && window.top !== window) {
  setInterval(() => {
    const v = [...document.querySelectorAll('video')].sort((a, b) => (b.videoWidth * b.videoHeight) - (a.videoWidth * a.videoHeight))[0];
    if (!v) return;
    window.parent.postMessage({ __richpresence: 1, paused: v.paused, ended: v.ended, currentTime: v.currentTime, duration: isFinite(v.duration) ? v.duration : 0 }, parentOrigin);
  }, 2000);
}
