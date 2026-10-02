// Passes what the streaming-site tabs report to the RichPresence app on this PC (127.0.0.1 only).
const APP = 'http://127.0.0.1:47610';

chrome.runtime.onMessage.addListener((msg) => {
  if (!msg || msg.type !== 'watching' || !msg.info) return;
  fetch(`${APP}/watching`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', 'X-RichPresence': '1' },
    body: JSON.stringify(msg.info)
  }).catch(() => {});      // RichPresence isn't running: nothing to do
});
