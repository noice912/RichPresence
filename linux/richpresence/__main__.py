"""RichPresence for Linux.

    richpresence                 open the window
    richpresence --play <id>     launch that game right away (the menu shortcuts use this)
    richpresence --minimized     start in the tray (used by start-on-login)
    richpresence --headless      no window; run the presence engine in the terminal
    richpresence --scan-only     print the detected games and exit
"""
import argparse
import fcntl
import os
import sys
import time

from . import __version__
from . import settings as S


def single_instance():
    S.DATA_DIR.mkdir(parents=True, exist_ok=True)
    f = open(S.DATA_DIR / '.lock', 'w')
    try:
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return None
    return f


def main(argv=None):
    p = argparse.ArgumentParser(prog='richpresence', description='Shows the games you play on Discord.')
    p.add_argument('--play', default='')
    p.add_argument('--minimized', action='store_true')
    p.add_argument('--headless', action='store_true')
    p.add_argument('--scan-only', action='store_true')
    p.add_argument('--version', action='version', version=f'RichPresence {__version__}')
    a = p.parse_args(argv)

    if a.scan_only:
        from . import scanner
        for g in scanner.scan(S.load()):
            print(f"{g['name'][:34]:<34} {g['store']:<7} discord={g['discordId'] or '-':<20} exes={','.join(g['exes'][:3])}")
        return 0

    if a.headless:
        from . import engine as E, scanner
        s = S.load()
        st = E.State()
        lib = S.read_library() or scanner.scan(s, st.say)
        st.games = E.engine_games(lib, s)
        eng = E.Engine(s, st)
        eng.start()
        print('RichPresence (headless) - Ctrl+C to stop')
        try:
            while eng.is_alive():
                while not st.log.empty():
                    print(st.log.get_nowait(), flush=True)
                time.sleep(0.3)
        except KeyboardInterrupt:
            st.stop.set()
            eng.join(8)
            while not st.log.empty():
                print(st.log.get_nowait())
        return 0

    lock = single_instance()
    if lock is None:
        print('RichPresence is already running - check your system tray.', file=sys.stderr)
        try:
            import tkinter.messagebox as mb
            import tkinter as tk
            r = tk.Tk()
            r.withdraw()
            mb.showinfo('RichPresence', 'RichPresence is already running - check your system tray.')
        except Exception:
            pass
        return 1
    if not os.environ.get('DISPLAY') and not os.environ.get('WAYLAND_DISPLAY'):
        print('No desktop session found. Use --headless to run without a window.', file=sys.stderr)
        return 1
    from .gui import App
    App(play=a.play, minimized=a.minimized).run()
    return 0


if __name__ == '__main__':
    sys.exit(main())
