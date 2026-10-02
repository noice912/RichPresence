// Shows whether the RichPresence app is running and what it last heard from Netflix/Hulu.
const conn = document.getElementById('conn');
const connText = document.getElementById('connText');
const now = document.getElementById('now');

function line(cls, text) { const d = document.createElement('div'); d.className = cls; d.textContent = text; return d; }

fetch('http://127.0.0.1:47610/status', { headers: { 'X-RichPresence': '1' } })
  .then(r => r.json())
  .then(s => {
    conn.className = 'on';
    connText.textContent = `Connected to RichPresence ${s.version || ''}`.trim();
    const list = (s.watching || []).filter(w => w.title || w.playing);
    if (!list.length) { now.appendChild(line('dim card', 'Play something on Netflix or Hulu.')); return; }
    for (const w of list) {
      const c = line('card', '');
      c.appendChild(line('svc', `${w.service} - ${w.playing ? 'playing' : 'paused'}`));
      c.appendChild(line('title', w.title || "Couldn't read the title yet"));
      if (w.episode) c.appendChild(line('dim', w.episode));
      now.appendChild(c);
    }
  })
  .catch(() => {
    conn.className = 'off';
    connText.textContent = "RichPresence isn't running on this PC.";
    now.appendChild(line('dim card', 'Open RichPresence (version 1.5.0 or newer) and start the presence.'));
  });
