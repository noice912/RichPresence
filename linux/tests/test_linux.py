"""End-to-end checks for the Linux build, run in CI on a real Linux machine.

A fake home folder with a Steam library, a fake Discord (a Unix socket speaking the IPC protocol)
and a real running process named like the game. Checks the scanner finds and matches the game and
that the engine shows it on the right Discord app, then clears it when the game closes."""
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

TMP = Path(tempfile.mkdtemp(prefix='rp-test-'))
HOME = TMP / 'home'
RUN = TMP / 'run'
os.environ['HOME'] = str(HOME)
os.environ['RICHPRESENCE_DATA'] = str(TMP / 'data')
os.environ['XDG_RUNTIME_DIR'] = str(RUN)
os.environ.pop('DISPLAY', None)
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

bad = 0


def check(label, ok, detail=''):
    global bad
    print(('PASS' if ok else 'FAIL') + '  ' + label + ('  ' + str(detail) if detail and not ok else ''))
    if not ok:
        bad += 1
        print(f'::error title=test::{label} {str(detail)[:900]}'.replace(chr(10), ' '))


# ---- a fake Steam library with one game, whose binary is a real ELF (a copy of /bin/sleep)
steam = HOME / '.local/share/Steam'
game_dir = steam / 'steamapps/common/Duck Quest'
game_dir.mkdir(parents=True)
shutil.copy('/bin/sleep', game_dir / 'duckquest')
(game_dir / 'uninstall').write_bytes(open('/bin/sleep', 'rb').read())
os.chmod(game_dir / 'uninstall', 0o755)
(steam / 'steamapps/appmanifest_4242.acf').write_text('"AppState"\n{\n "appid" "4242"\n "name" "Duck Quest"\n "installdir" "Duck Quest"\n}\n')
(steam / 'steamapps/appmanifest_1.acf').write_text('"AppState"\n{\n "appid" "1"\n "name" "Proton 9.0"\n "installdir" "Proton 9.0"\n}\n')
# a Windows game run through Proton, and one in ~/Games
win_dir = steam / 'steamapps/common/Goose Game'
win_dir.mkdir(parents=True)
(win_dir / 'Goose.exe').write_bytes(b'MZ' + b'\0' * 5000)
(steam / 'steamapps/appmanifest_77.acf').write_text('"AppState"\n{\n "appid" "77"\n "name" "Goose Game"\n "installdir" "Goose Game"\n}\n')
(HOME / 'Games/Pond Racer').mkdir(parents=True)
shutil.copy('/bin/sleep', HOME / 'Games/Pond Racer/pondracer')

# Discord's detectable list (cached, so no network is needed)
data = Path(os.environ['RICHPRESENCE_DATA'])
data.mkdir(parents=True)
(data / 'detectable.json').write_text(json.dumps([
    {'id': '111111111111111111', 'name': 'Duck Quest', 'executables': [{'os': 'linux', 'name': 'duckquest'}]},
    {'id': '222222222222222222', 'name': 'Untitled Goose Game', 'executables': [{'os': 'win32', 'name': 'goose.exe'}]},
]))

import traceback  # noqa: E402


def _hook(tp, v, tb):
    print('::error title=crash::' + ' | '.join(traceback.format_exception(tp, v, tb)).replace(chr(10), ' ')[:3000])
    sys.__excepthook__(tp, v, tb)


sys.excepthook = _hook
from richpresence import discord_ipc, engine as E, scanner, settings as S, system  # noqa: E402

games = scanner.scan(S.load(), log=lambda m: None)
by = {g['name']: g for g in games}
check('finds the native Steam game', 'Duck Quest' in by, list(by))
check('skips Proton/runtime entries', not any('Proton' in n for n in by))
check('matches it to its official Discord app', by.get('Duck Quest', {}).get('discordId') == '111111111111111111')
check('uses the game binary, not the uninstaller', by.get('Duck Quest', {}).get('exes') == ['duckquest'], by.get('Duck Quest', {}).get('exes'))
check('Steam launch link', by.get('Duck Quest', {}).get('launch') == 'steam://rungameid/4242')
goose = next((g for g in games if g['id'] == 'steam:77'), {})
check('a Windows (Proton) game matches by its .exe', goose.get('discordId') == '222222222222222222' and goose.get('exes') == ['goose'], goose)
check('finds games in ~/Games', any(g['store'] == 'Folder' and 'pondracer' in g['exes'] for g in games))
check('writes the library file', len(S.read_library()) == len(games))

# ---- process detection, including a Wine/Proton style command line
p = subprocess.Popen([str(game_dir / 'duckquest'), '60'])
w = subprocess.Popen(['/bin/bash', '-c', 'exec -a "Z:\\\\games\\\\Goose.exe" sleep 60'])
time.sleep(0.5)
procs = system.running_processes()
check('sees the running game process', procs.get('duckquest') == p.pid)
check('sees a Windows .exe name in a command line', 'goose' in procs, sorted(n for n in procs if 'oose' in n))
check('reads the process start time', abs(system.process_start_ms(p.pid) - time.time() * 1000) < 10000)
w.kill()

# ---- a fake Discord
RUN.mkdir(parents=True, exist_ok=True)
sock_path = RUN / 'discord-ipc-0'
srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(str(sock_path))
srv.listen(8)
received = []   # (client_id, activity or None)


def serve(conn):
    client = None
    try:
        while True:
            head = conn.recv(8)
            if len(head) < 8:
                return
            op, n = struct.unpack('<ii', head)
            body = b''
            while len(body) < n:
                body += conn.recv(n - len(body))
            msg = json.loads(body)
            if op == 0:
                client = msg['client_id']
                out = {'cmd': 'DISPATCH', 'evt': 'READY', 'data': {'v': 1}}
            else:
                received.append((client, msg['args'].get('activity')))
                out = {'cmd': 'SET_ACTIVITY', 'evt': None, 'nonce': msg['nonce'], 'data': msg['args'].get('activity')}
            b = json.dumps(out).encode()
            conn.sendall(struct.pack('<ii', 1, len(b)) + b)
    except OSError:
        pass


def accept():
    while True:
        try:
            c, _ = srv.accept()
        except OSError:
            return
        threading.Thread(target=serve, args=(c,), daemon=True).start()


threading.Thread(target=accept, daemon=True).start()
check('finds the Discord socket', discord_ipc.find_sockets() == [str(sock_path)], discord_ipc.find_sockets())

# a game Discord knows is held back for 2 minutes so Discord's own detection (and streaks) counts first
held = E.Engine(dict(S.load(), official_to_discord=True, official_delay_minutes=2), E.State())
before = len(received)
held.update_games([(dict(by['Duck Quest'], enabled=True), p.pid)])
check('an official game is left to Discord for the first 2 minutes', len(received) == before and not held.game_conns)
held.s['official_delay_minutes'] = 0
held.update_games([(dict(by['Duck Quest'], enabled=True), p.pid)])
check('...and then gets our own card', len(received) > before and received[-1][1] and received[-1][1].get('name') == 'Duck Quest')
held.close_all()

s = dict(S.load(), show_music=False, show_current_app=False, official_to_discord=False)
st = E.State()
st.games = E.engine_games(games, s)
eng = E.Engine(s, st)
eng.start()
deadline = time.time() + 15
while time.time() < deadline and not any(a and a.get('name') == 'Duck Quest' for _, a in received):
    time.sleep(0.2)
hit = next(((c, a) for c, a in received if a and a.get('name') == 'Duck Quest'), None)
check('shows "Playing Duck Quest" on Discord', hit is not None, received)
check('...on the game\'s own Discord app', hit and hit[0] == '111111111111111111')
check('...with the real start time', hit and abs(hit[1]['timestamps']['start'] - system.process_start_ms(p.pid)) < 2000)
check('the status line says so', 'Playing Duck Quest' in st.status, st.status)

p.kill()
p.wait()
deadline = time.time() + 15
while time.time() < deadline and st.running_ids:
    time.sleep(0.2)
check('notices the game closed', st.running_ids == [], st.running_ids)
st.stop.set()
eng.join(10)
check('the engine stops cleanly', not eng.is_alive())

# ---- music card from an MPRIS-shaped track (no D-Bus in CI, so feed it directly)
st2 = E.State()
eng2 = E.Engine(dict(S.load(), show_lyrics=False, show_album_art=False), st2)
system.now_playing = lambda music_only=False: {'player': 'spotify', 'title': 'Quack Song', 'artist': 'The Ducks', 'album': 'Pond',
                                               'art': 'https://example.com/a.jpg', 'length': 200.0, 'position': 50.0}
E.system.now_playing = system.now_playing
title = eng2.update_music()
music = [a for c, a in received if c == S.MUSIC_ID and a]
check('music card is sent on the music app', title == 'Quack Song' and music, received[-3:])
if music:
    m = music[-1]
    check('...as "Listening to" with artist, title, art and timing', m['type'] == 2 and m['name'] == 'The Ducks' and m['details'] == 'Quack Song'
          and m['assets']['large_image'] == 'https://example.com/a.jpg' and m['timestamps']['end'] - m['timestamps']['start'] == 200000)
eng2.close_all()

srv.close()
shutil.rmtree(TMP, ignore_errors=True)
print(f'\n{bad} FAILURE(S)' if bad else '\nALL CHECKS PASSED')
sys.exit(1 if bad else 0)
