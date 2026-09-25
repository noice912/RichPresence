"""What is running: processes (from /proc), the focused window (X11 via xprop) and media
players (MPRIS over D-Bus, which Spotify, browsers, VLC, Rhythmbox, Cider etc. all speak)."""
import os
import re
import shutil
import subprocess
import time

from .scanner import exe_base

_CLK = os.sysconf('SC_CLK_TCK') if hasattr(os, 'sysconf') else 100


def _boot_time():
    try:
        for line in open('/proc/stat'):
            if line.startswith('btime'):
                return int(line.split()[1])
    except OSError:
        pass
    return int(time.time())


BOOT = _boot_time()


def process_start_ms(pid):
    try:
        stat = open(f'/proc/{pid}/stat').read()
        fields = stat[stat.rfind(')') + 2:].split()
        return int((BOOT + int(fields[19]) / _CLK) * 1000)
    except (OSError, ValueError, IndexError):
        return None


def process_names(pid):
    """Every name a process could be known by: its binary, and for Wine/Proton the .exe it runs."""
    names = set()
    try:
        comm = open(f'/proc/{pid}/comm').read().strip().lower()
        if comm:
            names.add(exe_base(comm))
    except OSError:
        pass
    try:
        argv = open(f'/proc/{pid}/cmdline', 'rb').read().split(b'\0')
        for i, a in enumerate(argv[:6]):
            s = a.decode('utf-8', 'ignore')
            if not s:
                continue
            if i == 0 or s.lower().endswith('.exe'):
                names.add(exe_base(s))
    except OSError:
        pass
    return names


def running_processes():
    """{name: pid} for every process we can see."""
    out = {}
    for d in os.listdir('/proc'):
        if not d.isdigit():
            continue
        for n in process_names(d):
            out.setdefault(n, int(d))
    return out


# ---------------------------------------------------------------- focused window (X11 / XWayland)
IGNORE = {'discord', 'vesktop', 'webcord', 'richpresence', 'gnome-shell', 'plasmashell', 'kwin_x11', 'kwin_wayland', 'xfdesktop'}
FRIENDLY = {
    'code': 'Visual Studio Code', 'firefox': 'Firefox', 'chrome': 'Google Chrome', 'google-chrome': 'Google Chrome',
    'chromium': 'Chromium', 'brave': 'Brave', 'spotify': 'Spotify', 'steam': 'Steam', 'obs': 'OBS Studio',
    'blender': 'Blender', 'slack': 'Slack', 'obsidian': 'Obsidian', 'gimp': 'GIMP', 'konsole': 'Konsole',
    'gnome-terminal-server': 'Terminal', 'kitty': 'kitty', 'alacritty': 'Alacritty', 'nautilus': 'Files',
    'dolphin': 'Dolphin', 'libreoffice': 'LibreOffice', 'thunderbird': 'Thunderbird', 'krita': 'Krita',
}
ICON_DOMAIN = {
    'code': 'code.visualstudio.com', 'firefox': 'mozilla.org', 'chrome': 'google.com', 'google-chrome': 'google.com',
    'spotify': 'spotify.com', 'steam': 'store.steampowered.com', 'slack': 'slack.com', 'obsidian': 'obsidian.md',
    'obs': 'obsproject.com', 'blender': 'blender.org', 'brave': 'brave.com', 'gimp': 'gimp.org', 'krita': 'krita.org',
}
_HAS_XPROP = shutil.which('xprop') is not None


def _xprop(*args):
    try:
        return subprocess.run(['xprop', *args], capture_output=True, text=True, timeout=2).stdout
    except (OSError, subprocess.SubprocessError):
        return ''


def foreground_supported():
    return _HAS_XPROP and bool(os.environ.get('DISPLAY'))


def foreground(game_exes):
    """The focused app as {proc, label, title, icon}, or None (unsupported, ignored or a game)."""
    if not foreground_supported():
        return None
    m = re.search(r'window id # (0x[0-9a-f]+)', _xprop('-root', '_NET_ACTIVE_WINDOW'))
    if not m or m.group(1) == '0x0':
        return None
    info = _xprop('-id', m.group(1), '_NET_WM_PID', 'WM_CLASS', '_NET_WM_NAME')
    pid = re.search(r'_NET_WM_PID\(CARDINAL\) = (\d+)', info)
    cls = re.findall(r'"([^"]*)"', (re.search(r'WM_CLASS\(STRING\) = (.*)', info) or [None, ''])[1])
    title = (re.search(r'_NET_WM_NAME\(UTF8_STRING\) = "(.*)"', info) or [None, ''])[1]
    names = process_names(pid.group(1)) if pid else set()
    proc = (cls[0].lower() if cls else '') or (sorted(names)[0] if names else '')
    if not proc:
        return None
    if proc in IGNORE or names & IGNORE or names & game_exes or proc in game_exes:
        return None
    label = FRIENDLY.get(proc) or (cls[-1] if cls else proc)
    icon = f'https://www.google.com/s2/favicons?sz=128&domain={ICON_DOMAIN[proc]}' if proc in ICON_DOMAIN else None
    return {'proc': proc, 'label': label, 'title': title, 'icon': icon}


# ---------------------------------------------------------------- media players (MPRIS)
NOT_MUSIC = ('firefox', 'chrom', 'brave', 'edge', 'vivaldi', 'opera', 'vlc', 'mpv', 'totem', 'celluloid', 'kdeconnect', 'plasma-browser')


def now_playing(music_only=False):
    """The playing track as {player, title, artist, album, art, length, position}, or None."""
    try:
        from jeepney import DBusAddress, new_method_call
        from jeepney.io.blocking import open_dbus_connection
    except ImportError:
        return None
    try:
        conn = open_dbus_connection(bus='SESSION')
    except Exception:
        return None
    try:
        bus = DBusAddress('/org/freedesktop/DBus', bus_name='org.freedesktop.DBus', interface='org.freedesktop.DBus')
        names = conn.send_and_get_reply(new_method_call(bus, 'ListNames')).body[0]
        best = None
        for n in sorted(x for x in names if x.startswith('org.mpris.MediaPlayer2.')):
            short = n.split('.', 3)[3].lower()
            if music_only and any(b in short for b in NOT_MUSIC):
                continue
            player = DBusAddress('/org/mpris/MediaPlayer2', bus_name=n, interface='org.freedesktop.DBus.Properties')
            try:
                props = conn.send_and_get_reply(new_method_call(player, 'GetAll', 's', ('org.mpris.MediaPlayer2.Player',)), timeout=2).body[0]
            except Exception:
                continue
            if props.get('PlaybackStatus', ('s', ''))[1] != 'Playing':
                continue
            md = dict((k, v[1]) for k, v in props.get('Metadata', ('a{sv}', {}))[1].items())
            title = str(md.get('xesam:title') or '').strip()
            if not title:
                continue
            artist = md.get('xesam:artist') or []
            artist = ', '.join(artist) if isinstance(artist, list) else str(artist)
            best = {
                'player': short.split('.')[0], 'title': title, 'artist': artist.strip(), 'album': str(md.get('xesam:album') or '').strip(),
                'art': md.get('mpris:artUrl') if str(md.get('mpris:artUrl') or '').startswith('http') else None,
                'length': (md.get('mpris:length') or 0) / 1e6, 'position': (props.get('Position', ('x', 0))[1] or 0) / 1e6,
            }
            if not any(b in short for b in NOT_MUSIC):
                break          # a real music player wins over a browser tab
        return best
    finally:
        conn.close()
