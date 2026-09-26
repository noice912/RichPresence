"""Updates from GitHub releases. The AppImage replaces itself (after checking the file against the
SHA-256 GitHub publishes for it); the .deb and source installs only say a new version is out."""
import hashlib
import json
import os
import urllib.request
from pathlib import Path

from . import __version__

API = 'https://api.github.com/repos/noice912/RichPresence/releases/latest'
UA = {'User-Agent': 'RichPresence updater'}


def version_tuple(v):
    out = []
    for part in str(v).lstrip('v').split('.'):
        digits = ''.join(ch for ch in part if ch.isdigit())
        out.append(int(digits or 0))
    return tuple(out + [0] * (3 - len(out)))


def latest_release(url=API):
    req = urllib.request.Request(url, headers=UA)
    with urllib.request.urlopen(req, timeout=20) as r:
        return json.loads(r.read().decode('utf-8'))


def check(current=__version__, appimage=None, release=None, log=print):
    """Returns (state, latest_version, path): state is 'current', 'available' (can't self-install),
    'ready' (a verified new AppImage is at path) or 'failed'."""
    appimage = appimage if appimage is not None else os.environ.get('APPIMAGE')
    try:
        rel = release or latest_release()
        latest = str(rel.get('tag_name', '')).lstrip('v')
        if version_tuple(latest) <= version_tuple(current):
            return 'current', latest, None
        if not appimage:
            return 'available', latest, None
        asset = next((a for a in rel.get('assets', []) if a.get('name') == 'RichPresence-x86_64.AppImage'), None)
        want = str((asset or {}).get('digest') or '').replace('sha256:', '').lower()
        if not asset or not want:
            log(f'Update {latest} has no AppImage with a published checksum, so it was not installed.')
            return 'failed', latest, None
        target = Path(appimage)
        tmp = target.with_name(target.name + '.download')
        log(f'Downloading update {latest}...')
        h = hashlib.sha256()
        req = urllib.request.Request(asset['browser_download_url'], headers=UA)
        with urllib.request.urlopen(req, timeout=120) as r, open(tmp, 'wb') as f:
            while True:
                chunk = r.read(1 << 20)
                if not chunk:
                    break
                h.update(chunk)
                f.write(chunk)
        if h.hexdigest() != want:
            tmp.unlink(missing_ok=True)
            log(f"Update {latest} didn't match its checksum and was deleted.")
            return 'failed', latest, None
        tmp.chmod(0o755)
        log(f'Update {latest} downloaded and verified.')
        return 'ready', latest, str(tmp)
    except Exception as e:
        log(f"Couldn't check for updates: {e}")
        return 'failed', None, None


def install(downloaded, appimage=None):
    """Puts the new AppImage in place of the running one (Linux keeps the old file open for the
    running copy) and returns the path to start."""
    appimage = appimage or os.environ.get('APPIMAGE')
    os.replace(downloaded, appimage)
    return appimage
