"""Finds installed games on Linux: Steam (native and Proton), Heroic (Epic/GOG), Lutris,
~/Games, your own folders and games you added by hand. Then matches each one to its official
Discord app using Discord's public list of detectable games."""
import json
import os
import re
import sqlite3
import time
import urllib.request
from pathlib import Path

from . import settings as S

HOME = Path.home()
EXCLUDE = re.compile(
    r'^(unins.*|.*setup.*|vc_?redist.*|vcredist.*|dxwebsetup|dotnet.*|.*crash.*|.*report.*|.*prereq.*|.*install.*|'
    r'.*updater?|.*helper|.*cefsubprocess.*|.*bootstrap.*|.*anticheat.*|beservice.*|.*benchmark.*|.*launcher.*|'
    r'elevate|.*browser|.*editor.*|.*redist.*|.*webview.*|.*service|.*\.so.*|steam_appid|.*\.sh)$')
GENERIC = {'game', 'launcher', 'client', 'main', 'start', 'play', 'app', 'shipping', 'win64', 'editor', 'server'}


def norm(n):
    return re.sub(r'[^a-z0-9]', '', str(n or '').lower())


def exe_base(path):
    """'Game_x64.exe' / 'bin/game.x86_64' -> 'game_x64' / 'game.x86_64' (lowercase, no .exe)."""
    b = re.split(r'[\\/]', str(path))[-1].lower().lstrip('>')
    return b[:-4] if b.endswith('.exe') else b


def _is_game_binary(p):
    name = p.name.lower()
    if name.endswith('.exe'):
        return True
    try:
        if not os.access(p, os.X_OK):
            return False
        with open(p, 'rb') as f:
            return f.read(4) == b'\x7fELF'
    except OSError:
        return False


def get_exes(root, max_depth=6):
    found = []
    root = Path(root)
    base_depth = len(root.parts)
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        depth = len(Path(dirpath).parts) - base_depth
        if depth >= max_depth:
            dirnames[:] = []
        for fn in filenames:
            p = Path(dirpath) / fn
            if p.is_file() and _is_game_binary(p):
                found.append(p)
        if len(found) > 400:
            break
    good = [p for p in found if not EXCLUDE.match(exe_base(p.name))]
    if not good:
        good = found
    good.sort(key=lambda p: p.stat().st_size if p.exists() else 0, reverse=True)
    return good[:8]


class Library:
    def __init__(self, log):
        self.games = []
        self.seen = set()
        self.log = log

    def add(self, gid, name, store, install, launch, exe_files=None, art=None):
        if not name or not install or not Path(install).is_dir():
            return
        key = str(Path(install).resolve()).lower().rstrip('/')
        if key in self.seen:
            return
        exe_files = list(exe_files) if exe_files else get_exes(install)
        if not exe_files:
            return
        self.seen.add(key)
        exes = []
        for e in exe_files:
            b = exe_base(Path(e).name)
            if b not in exes:
                exes.append(b)
        self.games.append({
            'id': gid, 'name': name, 'store': store, 'install': str(install), 'launch': launch,
            'exes': exes, 'icon': str(exe_files[0]), 'art': art, 'discordId': None, 'matched': False,
        })


# ---------------------------------------------------------------- Steam
def steam_roots():
    cands = [HOME / '.steam/steam', HOME / '.steam/root', HOME / '.local/share/Steam',
             HOME / '.var/app/com.valve.Steam/.local/share/Steam', HOME / 'snap/steam/common/.local/share/Steam']
    out = []
    for c in cands:
        try:
            r = c.resolve()
        except OSError:
            continue
        if (r / 'steamapps').is_dir() and r not in out:
            out.append(r)
    return out


def scan_steam(lib):
    skip = re.compile(r'Steamworks|Proton|Steam Linux|Redistributable|Runtime|Wallpaper Engine|Dedicated Server|SDK')
    for steam in steam_roots():
        libs = [steam]
        vdf = steam / 'steamapps/libraryfolders.vdf'
        if vdf.is_file():
            for m in re.finditer(r'"path"\s+"([^"]+)"', vdf.read_text(errors='ignore')):
                libs.append(Path(m.group(1)))
        for l in dict.fromkeys(libs):
            apps = l / 'steamapps'
            if not apps.is_dir():
                continue
            for acf in apps.glob('appmanifest_*.acf'):
                t = acf.read_text(errors='ignore')
                g = lambda k: (re.search(rf'"{k}"\s+"([^"]+)"', t) or [None, None])[1]
                appid, name, d = g('appid'), g('name'), g('installdir')
                if not appid or not name or not d or skip.search(name):
                    continue
                art = None
                cache = steam / 'appcache/librarycache'
                for f in (cache / appid / 'header.jpg', cache / f'{appid}_header.jpg', cache / appid / 'library_600x900.jpg'):
                    if f.is_file():
                        art = str(f)
                        break
                lib.add(f'steam:{appid}', name, 'Steam', apps / 'common' / d, f'steam://rungameid/{appid}', None, art)


# ---------------------------------------------------------------- Heroic (Epic + GOG)
def scan_heroic(lib):
    for base in (HOME / '.config/heroic', HOME / '.var/app/com.heroicgameslauncher.hgl/config/heroic'):
        epic = base / 'legendaryConfig/legendary/installed.json'
        try:
            for app, info in json.loads(epic.read_text()).items():
                lib.add(f'epic:{app}', info.get('title') or app, 'Epic', info.get('install_path'),
                        f'heroic://launch/legendary/{app}')
        except Exception:
            pass
        gog = base / 'gog_store/installed.json'
        try:
            for info in json.loads(gog.read_text()).get('installed', []):
                p = info.get('install_path')
                app = info.get('appName')
                lib.add(f'gog:{app}', Path(p).name if p else app, 'GOG', p, f'heroic://launch/gog/{app}')
        except Exception:
            pass


# ---------------------------------------------------------------- Lutris
def scan_lutris(lib):
    for db in (HOME / '.local/share/lutris/pga.db', HOME / '.var/app/net.lutris.Lutris/data/lutris/pga.db'):
        if not db.is_file():
            continue
        try:
            con = sqlite3.connect(f'file:{db}?mode=ro', uri=True)
            for name, slug, directory in con.execute('SELECT name, slug, directory FROM games WHERE installed = 1'):
                if directory:
                    lib.add(f'lutris:{slug}', name, 'Lutris', directory, f'lutris:rungame/{slug}')
            con.close()
        except Exception as e:
            lib.log(f'Lutris scan problem: {e}')


# ---------------------------------------------------------------- folders
GROUP = {'epic', 'hoyoplay', 'rockstar', 'steam', 'riot games', 'origin', 'ea', 'ubisoft', 'gog galaxy', 'games', 'epic games', 'battle.net', 'heroic'}
SKIP = {'steamlibrary', 'steamapps', 'launcher', 'gamesave', 'common', 'downloading', 'temp', 'prefix', 'pfx', 'drive_c', 'windows'}


def scan_folder(lib, d, depth=0):
    try:
        children = [c for c in Path(d).iterdir() if c.is_dir()]
    except OSError:
        return
    for c in children:
        n = c.name.lower()
        if n in SKIP or n.startswith('.'):
            continue
        if n in GROUP and depth < 2:
            scan_folder(lib, c, depth + 1)
            continue
        exes = get_exes(c)
        if not exes:
            continue
        name = re.sub(r'\s+[Gg]ames?$', '', c.name)
        lib.add(f'folder:{str(c).lower()}', name, 'Folder', c, str(exes[0]), exes)


# ---------------------------------------------------------------- Discord matching
def load_detectable(log):
    cache = S.DATA_DIR / 'detectable.json'
    if not cache.is_file() or time.time() - cache.stat().st_mtime > 7 * 86400:
        log("Downloading Discord's list of known games...")
        req = urllib.request.Request('https://discord.com/api/v9/applications/detectable',
                                     headers={'User-Agent': 'RichPresence (personal use)'})
        with urllib.request.urlopen(req, timeout=30) as r:
            cache.write_bytes(r.read())
    return json.loads(cache.read_text(encoding='utf-8'))


def match_discord(games, apps):
    idx, by_name = {}, {}
    for a in apps:
        an = norm(a.get('name'))
        if an and an not in by_name:
            by_name[an] = a
        for e in a.get('executables') or []:
            # Linux games and Windows games run through Proton/Wine both count
            if e.get('os') not in ('win32', 'linux') or e.get('is_launcher'):
                continue
            b = exe_base(e.get('name', ''))
            if b:
                idx.setdefault(b, []).append(a)
    for g in games:
        gn = norm(g['name'])
        score, by_id = {}, {}
        for e in g['exes']:
            for a in idx.get(e, []):
                i, an = str(a['id']), norm(a.get('name'))
                by_id[i] = a
                pts = 1
                if an == gn:
                    pts += 10
                elif len(gn) >= 4 and len(an) >= 4 and (gn in an or an in gn):
                    pts += 5
                elif len(e) >= 8 and e not in GENERIC:
                    pts += 3
                score[i] = score.get(i, 0) + pts
        best = max(score, key=score.get) if score else None
        hit = None
        if best and score[best] >= 4:
            g['discordId'], g['matched'], hit = best, True, by_id[best]
            official = [e for e in g['exes'] if any(str(a['id']) == best for a in idx.get(e, []))]
            if official:
                g['exes'] = official
        elif gn in by_name:
            hit = by_name[gn]
            g['discordId'], g['matched'] = str(hit['id']), True
        if hit and g['store'] in ('Folder', 'Added'):
            g['name'] = hit['name']


def scan(s, log=print):
    lib = Library(log)
    for fn, label in ((scan_steam, 'Steam'), (scan_heroic, 'Heroic'), (scan_lutris, 'Lutris')):
        try:
            fn(lib)
        except Exception as e:
            log(f'{label} scan problem: {e}')
    roots = [HOME / 'Games', HOME / 'games'] + [Path(os.path.expanduser(f)) for f in s.get('extra_folders', [])]
    for r in dict.fromkeys(roots):
        if r.is_dir():
            scan_folder(lib, r)
    for cg in s.get('custom_games', []):
        p = Path(cg.get('exe', ''))
        if p.is_file():
            lib.add(f'custom:{str(p).lower()}', cg.get('name') or p.stem, 'Added', p.parent, str(p), [p])

    # an exe shared by several games can't identify any one of them
    count = {}
    for g in lib.games:
        for e in g['exes']:
            count[e] = count.get(e, 0) + 1
    for g in lib.games:
        uniq = [e for e in g['exes'] if count[e] == 1]
        if uniq:
            g['exes'] = uniq

    try:
        match_discord(lib.games, load_detectable(log))
    except Exception as e:
        log(f"Couldn't match games to Discord ({e}). They will still be listed.")

    games = sorted(lib.games, key=lambda g: g['name'].lower())
    S.DATA_DIR.mkdir(parents=True, exist_ok=True)
    S.LIBRARY_PATH.write_text(json.dumps(games, indent=1), encoding='utf-8')
    log(f"Found {len(games)} games ({sum(1 for g in games if g['matched'])} matched to Discord).")
    return games
