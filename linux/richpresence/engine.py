"""The presence engine: a background thread that watches for games, music and the focused app
and keeps up to three Discord cards in sync. It never touches the window; it reports through
a small shared state object."""
import json
import queue
import re
import threading
import time
import urllib.parse
import urllib.request

from . import discord_ipc, system
from . import settings as S

MUSIC_FALLBACK = 'https://upload.wikimedia.org/wikipedia/commons/thumb/3/3c/Musical_notes.svg/240px-Musical_notes.svg.png'
GENERIC_APP_ICON = 'https://upload.wikimedia.org/wikipedia/commons/thumb/3/35/Tux.svg/240px-Tux.svg.png'
UA = {'User-Agent': 'RichPresence (personal use)'}


def get_json(url, timeout=8):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.loads(r.read().decode('utf-8'))


class State:
    def __init__(self):
        self.stop = threading.Event()
        self.log = queue.Queue()
        self.status = 'Stopped'
        self.games = []           # [{id, name, exes, discordId, enabled}]
        self.running_ids = []
        self.watch_id = None      # "quit when this game closes"
        self.game_exited = False

    def say(self, m):
        self.log.put(time.strftime('[%H:%M:%S] ') + m)


def engine_games(library, s):
    dis = set(s.get('disabled_games', []))
    return [{'id': g['id'], 'name': g['name'], 'exes': list(g.get('exes', [])), 'discordId': g.get('discordId'),
             'enabled': g['id'] not in dis} for g in library]


class Engine(threading.Thread):
    def __init__(self, s, state):
        super().__init__(daemon=True)
        self.s, st = s, state
        self.st = st
        self.music = discord_ipc.Conn(S.MUSIC_ID, 'music')
        self.app = discord_ipc.Conn(S.APP_ID, 'app')
        self.game_conns = {}
        self.first_seen = {}
        self.art_cache, self.lyrics_cache = {}, {}
        self.genshin, self.genshin_at = None, 0
        self.last_lyric = None
        self.app_start = None
        self.app_pending, self.app_pending_since = None, 0
        self.last_valid_app = 0
        self.watch = {'id': None, 'seen': False, 'gone': None, 'started': 0}

    # ------------------------------------------------ helpers
    def nap(self, sec):
        self.st.stop.wait(sec)

    def close_all(self):
        self.music.close()
        self.app.close()
        for c in self.game_conns.values():
            c.close()
        self.game_conns = {}

    def push(self, c, activity, cid, critical):
        since = time.time() - c.sent_at
        if not critical and since < 5:
            return False
        if critical and since < 2:
            time.sleep(0.8)
        c.set_activity(activity)
        c.sent_at, c.card_id = time.time(), cid
        return True

    def album_art(self, artist, title, album):
        if not self.s.get('show_album_art'):
            return None
        key = f'{artist}|{album}|{title}'
        if key not in self.art_cache:
            url = None
            try:
                q = urllib.parse.quote(f'{artist} {album} {title}')
                r = get_json(f'https://itunes.apple.com/search?term={q}&entity=song&limit=1')
                if r.get('resultCount') and r['results'][0].get('artworkUrl100'):
                    url = r['results'][0]['artworkUrl100'].replace('100x100bb', '512x512bb')
            except Exception:
                pass
            self.art_cache[key] = url
        return self.art_cache[key]

    def lyrics(self, artist, title, album, duration):
        if not self.s.get('show_lyrics'):
            return None
        key = f'{artist}|{title}|{album}'
        if key not in self.lyrics_cache:
            parsed = None
            try:
                q = {'artist_name': artist, 'track_name': title}
                if album:
                    q['album_name'] = album
                if duration:
                    q['duration'] = int(duration)
                r = get_json('https://lrclib.net/api/get?' + urllib.parse.urlencode(q))
                lines = []
                for line in (r.get('syncedLyrics') or '').split('\n'):
                    m = re.match(r'^\[(\d+):(\d+(?:\.\d+)?)\](.*)$', line)
                    if m:
                        lines.append((int(m.group(1)) * 60 + float(m.group(2)), m.group(3).strip()))
                parsed = sorted(lines) or None
            except Exception:
                pass
            self.lyrics_cache[key] = parsed
        return self.lyrics_cache[key]

    @staticmethod
    def lyric_at(lyrics, pos):
        line = None
        for t, text in lyrics or []:
            if t <= pos + 0.3:
                line = text
            else:
                break
        if not line:
            return None
        return line if len(line) <= 128 else line[:125] + '...'

    def genshin_info(self):
        uid = str(self.s.get('genshin_uid') or '').strip()
        if not re.fullmatch(r'\d{9,10}', uid):
            return None
        if self.genshin and time.time() - self.genshin_at < 600:
            return self.genshin
        self.genshin_at = time.time()
        try:
            pi = get_json(f'https://enka.network/api/uid/{uid}?info', 10).get('playerInfo')
            if pi:
                self.genshin = {'nickname': pi.get('nickname', ''), 'level': int(pi.get('level', 0)), 'wl': int(pi.get('worldLevel', 0))}
                self.st.say(f"Genshin profile: {self.genshin['nickname']}  AR {self.genshin['level']}  WL {self.genshin['wl']}")
        except Exception:
            self.st.say("Couldn't load your Genshin profile (is Character Showcase public in-game?)")
        return self.genshin

    def game_activity(self, g, pid):
        start = system.process_start_ms(pid) or self.first_seen.setdefault(g['id'], int(time.time() * 1000))
        a = {'type': 0, 'name': g['name'], 'timestamps': {'start': start}}
        if {'genshinimpact', 'yuanshen'} & set(g['exes']):
            gi = self.genshin_info()
            if gi:
                uid = str(self.s.get('genshin_uid')).strip()
                a['details'] = f"{gi['nickname']} - AR {gi['level']}"
                a['state'] = f"UID {uid} - WL {gi['wl']}"
                a['assets'] = {'large_image': 'https://www.google.com/s2/favicons?sz=128&domain=genshin.hoyoverse.com', 'large_text': 'Genshin Impact'}
        return a

    # ------------------------------------------------ the three cards
    def update_games(self, running):
        wanted = {}
        delay = float(self.s.get('official_delay_minutes') or 0) * 60
        for g, pid in running:
            # Discord detects its official games itself: give it a head start so the session counts for
            # Recent Activity and streaks, then show our own card
            if self.s.get('official_to_discord') and g.get('discordId'):
                start = system.process_start_ms(pid) or self.first_seen.setdefault(g['id'], int(time.time() * 1000))
                if time.time() * 1000 - start < delay * 1000:
                    continue
            cid = str(g['discordId']) if g.get('discordId') else S.GAME_ID
            wanted.setdefault(cid, (g, pid))
        for cid, (g, pid) in wanted.items():
            c = self.game_conns.setdefault(cid, discord_ipc.Conn(cid, 'game'))
            try:
                if not c.connect():
                    continue
                gi = self.genshin or {}
                sig = f"{g['id']}|{gi.get('level')}|{gi.get('wl')}"
                if c.card_id != sig or time.time() - c.sent_at >= 20:
                    c.set_activity(self.game_activity(g, pid))
                    if c.card_id != sig:
                        self.st.say(f"Playing: {g['name']}")
                    c.card_id, c.sent_at = sig, time.time()
            except OSError as e:
                self.st.say(f'Game card error: {e}')
                c.close()
                self.game_conns.pop(cid, None)
        for cid in list(self.game_conns):
            if cid not in wanted:
                self.game_conns.pop(cid).close()
                self.st.say('Game closed - card removed')

    def update_music(self):
        np = system.now_playing(self.s.get('music_players') == 'music-only') if self.s.get('show_music') else None
        if not np:
            self.music.clear()
            self.music.close()
            return None
        if not self.music.connect():
            return None
        artist, title, album = np['artist'], np['title'], np['album']
        lyr = self.lyrics(artist, title, album, np['length'])
        line = self.lyric_at(lyr, np['position'])
        cid = f'music|{artist}|{title}|{album}'
        changed = self.music.card_id != cid
        lyric_changed = bool(self.s.get('show_lyrics') and line and line != self.last_lyric)
        if changed or lyric_changed or time.time() - self.music.sent_at >= 15:
            art = np['art'] or self.album_art(artist, title, album) or MUSIC_FALLBACK
            start = int(time.time() * 1000 - np['position'] * 1000)
            act = {
                'type': 2, 'details': title[:128],
                'state': (line if self.s.get('show_lyrics') and line else f'by {artist}' if artist else np['player'])[:128],
                'assets': {'large_image': art, 'large_text': (f'{title} - {album}' if album else title)[:128]},
                'timestamps': {'start': start},
            }
            if artist:
                act['name'] = artist[:128]
            if np['length'] > 0:
                act['timestamps']['end'] = start + int(np['length'] * 1000)
            if self.push(self.music, act, cid, changed):
                if changed:
                    self.st.say(f'Music: {artist} - {title}')
                    self.last_lyric = None
                if lyric_changed:
                    self.last_lyric = line
        return title

    def update_app(self, game_exes):
        if not self.s.get('show_current_app'):
            self.app.clear()
            self.app.close()
            return None
        if not self.app.connect():
            return None
        fg = system.foreground(game_exes)
        shown = None
        if fg:
            now = time.time()
            self.last_valid_app = now
            if fg['proc'] != self.app_pending:
                self.app_pending, self.app_pending_since = fg['proc'], now
            cid = f"app|{fg['label']}"
            is_new = self.app.card_id != cid and now - self.app_pending_since >= 3
            if is_new or self.app.card_id == cid or now - self.app.sent_at >= 20:
                if is_new or not self.app_start:
                    self.app_start = int(now * 1000)
                act = {'type': 0, 'name': fg['label'][:128], 'timestamps': {'start': self.app_start},
                       'assets': {'large_image': fg['icon'] or GENERIC_APP_ICON, 'large_text': fg['label'][:128]}}
                title = fg['title'][:125] + '...' if len(fg['title']) > 128 else fg['title']
                if title and title != fg['label']:
                    act['details'] = title
                if self.push(self.app, act, cid, is_new) and is_new:
                    self.st.say(f"App: {fg['label']}")
            shown = fg['label']
        elif self.app.card_id and time.time() - self.last_valid_app < 300:
            shown = self.app.card_id.split('|', 1)[1]
        if not shown:
            self.app.clear()
        return shown

    def check_watch(self):
        w, st = self.watch, self.st
        if not st.watch_id:
            return
        if w['id'] != st.watch_id:
            w.update(id=st.watch_id, seen=False, gone=None, started=time.time())
        if st.watch_id in st.running_ids:
            w['seen'], w['gone'] = True, None
        elif w['seen']:
            if not w['gone']:
                w['gone'] = time.time()
            elif time.time() - w['gone'] > 8:
                st.game_exited, st.watch_id = True, None
        elif time.time() - w['started'] > 600:
            st.watch_id = None

    # ------------------------------------------------ main loop
    def run(self):
        st = self.st
        st.say('Presence started.')
        while not st.stop.is_set():
            try:
                if not discord_ipc.discord_running():
                    st.status = 'Waiting for Discord...'
                    self.close_all()
                    self.nap(8)
                    continue
                procs = system.running_processes()
                game_exes, running = set(), []
                for g in list(st.games):
                    game_exes.update(g['exes'])
                    if not g['enabled']:
                        continue
                    for e in g['exes']:
                        if e in procs:
                            running.append((g, procs[e]))
                            break
                st.running_ids = [g['id'] for g, _ in running]
                self.check_watch()

                self.update_games(running)
                music = self.update_music()
                app = self.update_app(game_exes)

                parts = []
                if running:
                    parts.append(f"Playing {running[0][0]['name']}")
                if music:
                    parts.append(f'Listening: {music}')
                if app and not running:
                    parts.append(f'App: {app}')
                st.status = '  |  '.join(parts) or 'Watching for games'
                self.nap(3)
            except Exception as e:
                st.say(f'Error: {e}')
                self.close_all()
                self.nap(5)
        for c in [self.music, self.app, *self.game_conns.values()]:
            c.clear()
        self.close_all()
        st.say('Presence stopped.')
