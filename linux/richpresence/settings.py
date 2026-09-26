"""Settings and paths. Everything lives in ~/.config/RichPresence (or $RICHPRESENCE_DATA)."""
import json
import os
from pathlib import Path

DATA_DIR = Path(os.environ.get('RICHPRESENCE_DATA') or Path(os.environ.get('XDG_CONFIG_HOME') or Path.home() / '.config') / 'RichPresence')
SETTINGS_PATH = DATA_DIR / 'settings.json'
LIBRARY_PATH = DATA_DIR / 'library.json'
REPO_URL = 'https://github.com/noice912/RichPresence'

# Discord app IDs are public (not secrets) and presence is set by each user's own Discord client,
# so everyone can share these without overlapping. Three apps = three cards at once.
GAME_ID = '1552433095335215165'    # card for games that have no official Discord app of their own
MUSIC_ID = '1552437427828818050'   # music card
APP_ID = '1544831111128154213'     # current-app card

DEFAULTS = {
    'genshin_uid': '',
    'show_music': True,
    'show_lyrics': True,
    'show_album_art': True,
    'show_current_app': True,
    'music_players': 'any',          # 'any' or 'music-only' (skip browsers and video players)
    'disabled_games': [],
    'extra_folders': [],
    'custom_games': [],              # [{name, exe}]
    'start_presence_on_open': True,
    'exit_when_game_closes': False,
    'start_on_login': False,
    'close_to_tray': True,
    'official_to_discord': True,     # let Discord detect games it knows first (keeps streaks)...
    'official_delay_minutes': 2,     # ...then show our own card after this long
}


def load():
    s = dict(DEFAULTS)
    try:
        j = json.loads(SETTINGS_PATH.read_text(encoding='utf-8'))
        for k in DEFAULTS:
            if k in j and j[k] is not None:
                s[k] = j[k]
    except Exception:
        pass
    for k in ('disabled_games', 'extra_folders', 'custom_games'):
        if not isinstance(s[k], list):
            s[k] = []
    return s


def save(s):
    DATA_DIR.mkdir(parents=True, exist_ok=True)
    tmp = SETTINGS_PATH.with_suffix('.tmp')
    tmp.write_text(json.dumps(s, indent=2), encoding='utf-8')
    tmp.replace(SETTINGS_PATH)


def read_library():
    try:
        j = json.loads(LIBRARY_PATH.read_text(encoding='utf-8'))
        return j if isinstance(j, list) else []
    except Exception:
        return []


def set_autostart(enable, command):
    """Start on login through the freedesktop autostart folder."""
    d = Path(os.environ.get('XDG_CONFIG_HOME') or Path.home() / '.config') / 'autostart'
    f = d / 'richpresence.desktop'
    if not enable:
        f.unlink(missing_ok=True)
        return
    d.mkdir(parents=True, exist_ok=True)
    f.write_text(
        '[Desktop Entry]\nType=Application\nName=RichPresence\n'
        f'Exec={command} --minimized\nIcon=richpresence\nX-GNOME-Autostart-enabled=true\nTerminal=false\n',
        encoding='utf-8',
    )
