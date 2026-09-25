"""The window: Games, Music & Apps, Settings and Log, plus a tray icon when the desktop has one."""
import os
import shutil
import subprocess
import sys
import threading
import time
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox

from . import engine as E
from . import scanner, system
from . import settings as S

BG, SIDE, CARD, CARD_HI, TEXT, DIM, ACCENT, GREEN, RUN_BG = (
    '#14161b', '#0f1115', '#1f232b', '#272c36', '#e8eaf0', '#8b91a1', '#5865f2', '#3ba55d', '#243a2e')


def self_command():
    appimage = os.environ.get('APPIMAGE')
    if appimage:
        return f'"{appimage}"'
    if getattr(sys, 'frozen', False):
        return f'"{sys.executable}"'
    return f'"{sys.executable}" -m richpresence'


def open_thing(target, cwd=None):
    if '://' in target or target.startswith('lutris:'):
        subprocess.Popen(['xdg-open', target], start_new_session=True)
    elif target.lower().endswith('.exe'):
        runner = shutil.which('wine') or shutil.which('umu-run')
        if not runner:
            raise OSError('This is a Windows game and Wine is not installed. Start it from Steam, Lutris or Heroic instead.')
        subprocess.Popen([runner, target], cwd=cwd, start_new_session=True)
    else:
        subprocess.Popen([target], cwd=cwd, start_new_session=True)


class App:
    def __init__(self, play='', minimized=False):
        self.s = S.load()
        self.state = E.State()
        self.job = None
        self.scan_thread = None
        self.library = S.read_library()
        self.tiles = {}
        self.pending_play = play
        self.really_quit = False
        self.tray = None

        self.root = tk.Tk()
        self.root.title('RichPresence')
        self.root.configure(bg=BG)
        self.root.geometry('1000x660')
        self.root.minsize(820, 520)
        self._set_icon()
        self.root.protocol('WM_DELETE_WINDOW', self.on_close)
        self._build()
        self._apply_to_ui()
        self.show_page('Games')
        self.rebuild_tiles()
        self._start_tray()
        if minimized and self.tray:
            self.root.withdraw()
        self.root.after(300, self._first_show)
        self.root.after(500, self._tick)

    # ------------------------------------------------ building
    def _set_icon(self):
        for p in (Path(__file__).parent / 'icon.png', Path(sys.executable).parent / 'icon.png'):
            if p.is_file():
                try:
                    self._icon_img = tk.PhotoImage(file=str(p))
                    self.root.iconphoto(True, self._icon_img)
                except tk.TclError:
                    pass
                return

    def _btn(self, parent, text, cmd, primary=False, **kw):
        return tk.Button(parent, text=text, command=cmd, bg=ACCENT if primary else CARD_HI, fg='white' if primary else TEXT,
                         activebackground=ACCENT, activeforeground='white', relief='flat', bd=0, padx=12, pady=6,
                         font=('Sans', 10, 'bold'), cursor='hand2', highlightthickness=0, **kw)

    def _check(self, parent, text, var):
        return tk.Checkbutton(parent, text=text, variable=var, bg=BG, fg=TEXT, selectcolor=CARD, activebackground=BG,
                              activeforeground=TEXT, highlightthickness=0, anchor='w', font=('Sans', 10))

    def _build(self):
        side = tk.Frame(self.root, bg=SIDE, width=190)
        side.pack(side='left', fill='y')
        side.pack_propagate(False)
        tk.Label(side, text='RichPresence', bg=SIDE, fg=TEXT, font=('Sans', 16, 'bold')).pack(anchor='w', padx=16, pady=(16, 0))
        tk.Label(side, text='your games on Discord', bg=SIDE, fg=DIM, font=('Sans', 8)).pack(anchor='w', padx=18, pady=(0, 18))
        self.nav = {}
        for n in ('Games', 'Music & Apps', 'Settings', 'Log'):
            b = tk.Button(side, text='   ' + n, anchor='w', relief='flat', bd=0, bg=SIDE, fg=DIM, activebackground=CARD_HI,
                          activeforeground=TEXT, font=('Sans', 10, 'bold'), highlightthickness=0, cursor='hand2',
                          command=lambda n=n: self.show_page(n))
            b.pack(fill='x', ipady=9)
            self.nav[n] = b
        self.btn_toggle = self._btn(side, 'Start presence', self.toggle, primary=True)
        self.btn_toggle.pack(side='bottom', fill='x', padx=12, pady=12)
        self.status_lbl = tk.Label(side, text='Presence off', bg=SIDE, fg=DIM, font=('Sans', 8), justify='left', wraplength=166, anchor='w')
        self.status_lbl.pack(side='bottom', fill='x', padx=16)

        content = tk.Frame(self.root, bg=BG)
        content.pack(side='left', fill='both', expand=True)
        self.pages = {n: tk.Frame(content, bg=BG, padx=20, pady=20) for n in self.nav}

        # ---- Games
        g = self.pages['Games']
        head = tk.Frame(g, bg=BG)
        head.pack(fill='x')
        tk.Label(head, text='My games', bg=BG, fg=TEXT, font=('Sans', 17, 'bold')).pack(side='left')
        self.btn_add = self._btn(head, '+ Add game', self.add_game)
        self.btn_add.pack(side='right', padx=(8, 0))
        self.btn_rescan = self._btn(head, 'Rescan', lambda: (self._read_from_ui(), self.start_scan()))
        self.btn_rescan.pack(side='right', padx=(8, 0))
        self.search = tk.StringVar()
        self.search.trace_add('write', lambda *_: self.rebuild_tiles())
        tk.Entry(head, textvariable=self.search, bg=CARD, fg=TEXT, insertbackground=TEXT, relief='flat', width=22).pack(side='right', ipady=4)
        self.count_lbl = tk.Label(g, text='', bg=BG, fg=DIM, anchor='w')
        self.count_lbl.pack(fill='x', pady=(2, 8))
        wrap = tk.Frame(g, bg=BG)
        wrap.pack(fill='both', expand=True)
        self.canvas = tk.Canvas(wrap, bg=BG, highlightthickness=0)
        sb = tk.Scrollbar(wrap, orient='vertical', command=self.canvas.yview)
        self.grid = tk.Frame(self.canvas, bg=BG)
        self.grid.bind('<Configure>', lambda e: self.canvas.configure(scrollregion=self.canvas.bbox('all')))
        self.canvas.create_window((0, 0), window=self.grid, anchor='nw')
        self.canvas.configure(yscrollcommand=sb.set)
        self.canvas.pack(side='left', fill='both', expand=True)
        sb.pack(side='right', fill='y')
        self.canvas.bind('<Configure>', lambda e: self._reflow())
        for ev in ('<Button-4>', '<Button-5>', '<MouseWheel>'):
            self.canvas.bind_all(ev, self._wheel)

        # ---- Music & Apps
        m = self.pages['Music & Apps']
        tk.Label(m, text='Music & apps', bg=BG, fg=TEXT, font=('Sans', 17, 'bold')).pack(anchor='w')
        tk.Label(m, text='These show as their own Discord cards next to your game (up to three at once).\n'
                         'Music works with any player that shows up in your desktop\'s media controls (Spotify, browsers, Rhythmbox, Cider, ...).',
                 bg=BG, fg=DIM, justify='left').pack(anchor='w', pady=(4, 14))
        self.v = {k: tk.BooleanVar() for k in ('show_music', 'show_lyrics', 'show_album_art', 'show_current_app',
                                                'music_only', 'start_presence_on_open', 'exit_when_game_closes', 'close_to_tray', 'start_on_login')}
        for k, t in (('show_music', "Show what I'm listening to"), ('music_only', 'Only music apps (skip browsers and video players)'),
                     ('show_lyrics', 'Show the current lyric line'), ('show_album_art', 'Show album art'),
                     ('show_current_app', "Show the app I'm using when nothing else is showing")):
            self._check(m, t, self.v[k]).pack(anchor='w', pady=2)
        if not system.foreground_supported():
            tk.Label(m, text='The app card needs an X11 session (on Wayland only XWayland apps are visible).', bg=BG, fg=DIM).pack(anchor='w', padx=24)
        self._btn(m, 'Apply', self._apply_music, primary=True).pack(anchor='w', pady=16)

        # ---- Settings
        st = self.pages['Settings']
        tk.Label(st, text='Settings', bg=BG, fg=TEXT, font=('Sans', 17, 'bold')).pack(anchor='w')
        tk.Label(st, text='Genshin UID (optional - shows your name, AR and World Level on your Genshin card)', bg=BG, fg=DIM).pack(anchor='w', pady=(14, 4))
        self.uid = tk.StringVar()
        tk.Entry(st, textvariable=self.uid, bg=CARD, fg=TEXT, insertbackground=TEXT, relief='flat', width=24).pack(anchor='w', ipady=4)
        tk.Label(st, text='Extra game folders - one per line. Every sub-folder in them counts as a game.', bg=BG, fg=DIM).pack(anchor='w', pady=(14, 4))
        row = tk.Frame(st, bg=BG)
        row.pack(anchor='w', fill='x')
        self.folders = tk.Text(row, height=4, width=60, bg=CARD, fg=TEXT, insertbackground=TEXT, relief='flat')
        self.folders.pack(side='left')
        self._btn(row, 'Add folder...', self.add_folder).pack(side='left', padx=10, anchor='n')
        for k, t in (('start_presence_on_open', 'Start the presence when RichPresence opens'),
                     ('exit_when_game_closes', 'Quit RichPresence when the game I launched closes'),
                     ('close_to_tray', 'Closing the window keeps it running in the tray'),
                     ('start_on_login', 'Start when I log in')):
            self._check(st, t, self.v[k]).pack(anchor='w', pady=2)
        self._btn(st, 'Save & rescan', self._save_all, primary=True).pack(anchor='w', pady=16)
        link = tk.Label(st, text='Help & source on GitHub', bg=BG, fg=ACCENT, cursor='hand2')
        link.pack(anchor='w')
        link.bind('<Button-1>', lambda e: open_thing(S.REPO_URL))

        # ---- Log
        self.log = tk.Text(self.pages['Log'], bg=CARD, fg=TEXT, relief='flat', font=('Monospace', 9), state='disabled')
        self.log.pack(fill='both', expand=True)

    def _wheel(self, e):
        if not self.pages['Games'].winfo_ismapped():
            return
        d = -1 if getattr(e, 'num', 0) == 4 or getattr(e, 'delta', 0) > 0 else 1
        self.canvas.yview_scroll(d * 3, 'units')

    def show_page(self, name):
        for n, p in self.pages.items():
            if n == name:
                p.pack(fill='both', expand=True)
            else:
                p.pack_forget()
            self.nav[n].configure(bg=CARD_HI if n == name else SIDE, fg=TEXT if n == name else DIM)

    # ------------------------------------------------ settings <-> ui
    def _apply_to_ui(self):
        self.uid.set(self.s.get('genshin_uid', ''))
        self.folders.delete('1.0', 'end')
        self.folders.insert('1.0', '\n'.join(self.s.get('extra_folders', [])))
        for k in self.v:
            if k == 'music_only':
                self.v[k].set(self.s.get('music_players') == 'music-only')
            else:
                self.v[k].set(bool(self.s.get(k)))

    def _read_from_ui(self):
        self.s['genshin_uid'] = self.uid.get().strip()
        self.s['extra_folders'] = [l.strip().strip('"') for l in self.folders.get('1.0', 'end').splitlines() if l.strip()]
        for k, var in self.v.items():
            if k == 'music_only':
                self.s['music_players'] = 'music-only' if var.get() else 'any'
            else:
                self.s[k] = bool(var.get())
        S.save(self.s)
        try:
            S.set_autostart(self.s['start_on_login'], self_command())
        except OSError as e:
            self.append_log(f'Could not change start-on-login: {e}')

    def _apply_music(self):
        self._read_from_ui()
        if self.job:
            self.stop_presence()
            self.start_presence()

    def _save_all(self):
        self._apply_music()
        self.start_scan()
        self.show_page('Games')

    def append_log(self, line):
        self.log.configure(state='normal')
        self.log.insert('end', line + '\n')
        if int(self.log.index('end').split('.')[0]) > 800:
            self.log.delete('1.0', '300.0')
        self.log.see('end')
        self.log.configure(state='disabled')

    # ------------------------------------------------ presence control
    def push_games(self):
        self.state.games = E.engine_games(self.library, self.s)

    def start_presence(self):
        if self.job:
            return
        self._read_from_ui()
        self.state.stop.clear()
        self.state.game_exited = False
        self.state.status = 'Starting...'
        self.push_games()
        self.job = E.Engine(dict(self.s), self.state)
        self.job.start()
        self.btn_toggle.configure(text='Stop presence')

    def stop_presence(self):
        if not self.job:
            return
        self.state.stop.set()
        self.job.join(8)
        self.job = None
        self.state.status, self.state.running_ids = 'Stopped', []
        self.btn_toggle.configure(text='Start presence')

    def toggle(self):
        self.stop_presence() if self.job else self.start_presence()

    def start_scan(self):
        if self.scan_thread and self.scan_thread.is_alive():
            return
        self.btn_rescan.configure(text='Scanning...', state='disabled')
        self._scan_done = False
        copy = {'extra_folders': list(self.s['extra_folders']), 'custom_games': list(self.s['custom_games'])}

        def work():
            try:
                scanner.scan(copy, self.state.say)
            except Exception as e:
                self.state.say(f'Scan failed: {e}')
            self._scan_done = True

        self.scan_thread = threading.Thread(target=work, daemon=True)
        self.scan_thread.start()

    def play(self, g):
        if not g.get('launch'):
            return
        try:
            open_thing(str(g['launch']), cwd=str(Path(g['launch']).parent) if '://' not in str(g['launch']) else None)
        except OSError as e:
            messagebox.showerror('RichPresence', f"Couldn't start {g['name']}: {e}")
            return
        self.append_log(time.strftime('[%H:%M:%S] ') + f"Launching {g['name']}")
        if self.s.get('exit_when_game_closes'):
            self.state.watch_id = g['id']
        if not self.job:
            self.start_presence()

    def make_shortcut(self, g):
        desktop = Path(subprocess.run(['xdg-user-dir', 'DESKTOP'], capture_output=True, text=True).stdout.strip() or Path.home() / 'Desktop') \
            if shutil.which('xdg-user-dir') else Path.home() / 'Desktop'
        apps = Path(os.environ.get('XDG_DATA_HOME') or Path.home() / '.local/share') / 'applications'
        safe = ''.join(c for c in g['name'] if c not in '\\/:*?"<>|')
        body = (f"[Desktop Entry]\nType=Application\nName={safe}\nExec={self_command()} --play \"{g['id']}\"\n"
                f"Icon=richpresence\nTerminal=false\nCategories=Game;\n")
        written = []
        for d in (apps, desktop):
            try:
                d.mkdir(parents=True, exist_ok=True)
                f = d / f"richpresence-{''.join(ch for ch in safe if ch.isalnum()) or 'game'}.desktop"
                f.write_text(body, encoding='utf-8')
                f.chmod(0o755)
                written.append(str(d))
            except OSError:
                pass
        messagebox.showinfo('RichPresence', f'Added "{safe}" to your app menu' + (' and desktop.' if len(written) > 1 else '.'))

    def add_game(self):
        f = filedialog.askopenfilename(title="Pick the game's program (a Linux binary or a Windows .exe)")
        if f:
            self.s['custom_games'] = self.s['custom_games'] + [{'name': Path(f).stem, 'exe': f}]
            S.save(self.s)
            self.start_scan()

    def add_folder(self):
        d = filedialog.askdirectory(title='Pick a folder that contains your games (each sub-folder is one game)')
        if d:
            cur = self.folders.get('1.0', 'end').strip()
            self.folders.insert('end', ('\n' if cur else '') + d)

    # ------------------------------------------------ tiles
    def rebuild_tiles(self):
        for w in self.grid.winfo_children():
            w.destroy()
        self.tiles = {}
        q = self.search.get().strip().lower()
        for g in self.library:
            if q and q not in g['name'].lower():
                continue
            self.tiles[g['id']] = self._tile(g)
        self._reflow()
        n = len(self.library)
        if n:
            self.count_lbl.configure(text=f'{n} games found')
        elif self.scan_thread and not self.scan_thread.is_alive():
            self.count_lbl.configure(text="No games found. Use '+ Add game', or add folders in Settings.")
        else:
            self.count_lbl.configure(text='Looking for your games...')

    def _reflow(self):
        width = max(self.canvas.winfo_width(), 400)
        cols = max(1, width // 224)
        for i, t in enumerate(self.tiles.values()):
            t['frame'].grid(row=i // cols, column=i % cols, padx=(0, 14), pady=(0, 14), sticky='n')

    def _tile(self, g):
        f = tk.Frame(self.grid, bg=CARD, width=210, height=210)
        f.grid_propagate(False)
        f.pack_propagate(False)
        img_lbl = tk.Label(f, bg=CARD_HI, height=4)
        if g.get('art') and Path(g['art']).is_file():
            try:
                from PIL import Image, ImageTk   # Steam art is JPEG, which Tk can't read on its own
                im = Image.open(g['art'])
                im.thumbnail((210, 100))
                img = ImageTk.PhotoImage(im)
                img_lbl.configure(image=img, height=100)
                img_lbl.image = img
            except Exception:
                pass
        img_lbl.pack(fill='x')
        tk.Label(f, text=g['name'], bg=CARD, fg=TEXT, font=('Sans', 10, 'bold'), anchor='w').pack(fill='x', padx=10, pady=(6, 0))
        sub = tk.Label(f, text=g['store'], bg=CARD, fg=DIM, font=('Sans', 8), anchor='w')
        sub.pack(fill='x', padx=10)
        tk.Label(f, text='Official Discord game' if g.get('discordId') else 'Shows as a generic game', bg=CARD,
                 fg=GREEN if g.get('discordId') else DIM, font=('Sans', 8), anchor='w').pack(fill='x', padx=10)
        var = tk.BooleanVar(value=g['id'] not in self.s['disabled_games'])

        def changed():
            dis = [x for x in self.s['disabled_games'] if x != g['id']]
            if not var.get():
                dis.append(g['id'])
            self.s['disabled_games'] = dis
            S.save(self.s)
            self.push_games()

        tk.Checkbutton(f, text='Show on Discord', variable=var, command=changed, bg=CARD, fg=TEXT, selectcolor=CARD_HI,
                       activebackground=CARD, activeforeground=TEXT, highlightthickness=0).pack(anchor='w', padx=6)
        self._btn(f, 'Play', lambda: self.play(g), primary=True).pack(fill='x', padx=10, pady=(2, 8), side='bottom')

        menu = tk.Menu(self.root, tearoff=0)
        menu.add_command(label='Add to app menu / desktop', command=lambda: self.make_shortcut(g))
        menu.add_command(label='Open install folder', command=lambda: open_thing('file://' + g['install']))
        if g['store'] == 'Added':
            def remove():
                self.s['custom_games'] = [c for c in self.s['custom_games'] if f"custom:{str(c.get('exe', '')).lower()}" != g['id']]
                S.save(self.s)
                self.start_scan()
            menu.add_command(label='Remove from list', command=remove)
        for w in (f, img_lbl):
            w.bind('<Button-3>', lambda e: menu.tk_popup(e.x_root, e.y_root))
        return {'frame': f, 'sub': sub, 'game': g, 'widgets': [f, sub]}

    # ------------------------------------------------ tray
    def _start_tray(self):
        try:
            import pystray
            from PIL import Image
        except Exception:
            return
        icon_path = Path(__file__).parent / 'icon.png'
        try:
            image = Image.open(icon_path) if icon_path.is_file() else Image.new('RGB', (64, 64), ACCENT)
            menu = pystray.Menu(
                pystray.MenuItem('Open', lambda: self.root.after(0, self.show_window), default=True),
                pystray.MenuItem('Start / Stop presence', lambda: self.root.after(0, self.toggle)),
                pystray.MenuItem('Quit', lambda: self.root.after(0, self.quit)),
            )
            self.tray = pystray.Icon('richpresence', image, 'RichPresence', menu)
            threading.Thread(target=self.tray.run, daemon=True).start()
        except Exception as e:
            self.tray = None
            self.append_log(f'No tray icon on this desktop ({e}); closing the window will quit.')

    def show_window(self):
        self.root.deiconify()
        self.root.lift()

    def on_close(self):
        if self.s.get('close_to_tray') and self.tray and not self.really_quit:
            self._read_from_ui()
            self.root.withdraw()
            return
        self.quit()

    def quit(self):
        self.really_quit = True
        try:
            self._read_from_ui()
        except Exception:
            pass
        self.stop_presence()
        if self.tray:
            try:
                self.tray.stop()
            except Exception:
                pass
        self.root.destroy()

    # ------------------------------------------------ loop
    def _first_show(self):
        self.start_scan()
        if self.s.get('start_presence_on_open') or self.pending_play:
            self.start_presence()
        self._try_pending_play()

    def _try_pending_play(self):
        if self.pending_play:
            g = next((x for x in self.library if x['id'] == self.pending_play), None)
            if g:
                self.pending_play = ''
                self.play(g)

    def _tick(self):
        while not self.state.log.empty():
            self.append_log(self.state.log.get_nowait())
        if getattr(self, '_scan_done', False):
            self._scan_done = False
            self.library = S.read_library()
            self.btn_rescan.configure(text='Rescan', state='normal')
            self.rebuild_tiles()
            self.push_games()
            self._try_pending_play()
        if self.job:
            self.status_lbl.configure(text=f'Presence on\n{self.state.status}', fg=GREEN)
            if not self.job.is_alive():
                self.stop_presence()
            if self.s.get('exit_when_game_closes') and self.state.game_exited:
                self.quit()
                return
        else:
            self.status_lbl.configure(text='Presence off', fg=DIM)
        running = set(self.state.running_ids)
        for gid, t in self.tiles.items():
            on = gid in running
            t['frame'].configure(bg=RUN_BG if on else CARD)
            t['sub'].configure(text=f"{t['game']['store']}  -  Running" if on else t['game']['store'])
        self.root.after(500, self._tick)

    def run(self):
        self.root.mainloop()
