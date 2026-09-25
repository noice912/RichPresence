"""Discord's local IPC: a Unix socket named discord-ipc-N that the desktop app opens.
Frames are <int32 op><int32 length><json>, little-endian. One connection per Discord app id."""
import json
import os
import socket
import struct
import uuid
from pathlib import Path


def socket_dirs():
    bases = [os.environ.get(k) for k in ('XDG_RUNTIME_DIR', 'TMPDIR', 'TMP', 'TEMP')] + ['/tmp', f'/run/user/{os.getuid()}']
    subs = ['', 'app/com.discordapp.Discord', 'app/com.discordapp.DiscordCanary', 'app/dev.vencord.Vesktop',
            '.flatpak/com.discordapp.Discord/xdg-run', '.flatpak/dev.vencord.Vesktop/xdg-run', 'snap.discord', 'snap.discord-canary']
    out = []
    for b in bases:
        if not b:
            continue
        for s in subs:
            p = Path(b) / s
            if p not in out and p.is_dir():
                out.append(p)
    return out


def find_sockets():
    found = []
    for d in socket_dirs():
        for i in range(10):
            p = d / f'discord-ipc-{i}'
            if p.exists():
                found.append(str(p))
    return found


def discord_running():
    return bool(find_sockets())


class Conn:
    def __init__(self, client_id, name):
        self.client_id = client_id
        self.name = name
        self.sock = None
        self.card_id = None      # what this card currently shows (to skip resending)
        self.sent_at = 0.0

    def _send(self, op, payload):
        data = json.dumps(payload, separators=(',', ':')).encode()
        self.sock.sendall(struct.pack('<ii', op, len(data)) + data)

    def _read(self):
        head = self._recv_exact(8)
        if not head:
            return None
        _, n = struct.unpack('<ii', head)
        body = self._recv_exact(n) if n > 0 else b''
        try:
            return json.loads(body or b'null')
        except ValueError:
            return None

    def _recv_exact(self, n):
        buf = b''
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                return None
            buf += chunk
        return buf

    def connect(self):
        if self.sock:
            return True
        for path in find_sockets():
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(3)
            try:
                s.connect(path)
                self.sock = s
                self._send(0, {'v': 1, 'client_id': self.client_id})
                reply = self._read()
                if reply and reply.get('evt') == 'READY':
                    return True
            except OSError:
                pass
            try:
                s.close()
            except OSError:
                pass
            self.sock = None
        return False

    def set_activity(self, activity):
        args = {'pid': os.getpid()}
        if activity is not None:
            args['activity'] = activity
        self._send(1, {'cmd': 'SET_ACTIVITY', 'nonce': str(uuid.uuid4()), 'args': args})
        reply = self._read()
        if reply is None:
            raise OSError('Discord closed the connection')
        if reply.get('evt') == 'ERROR':
            raise OSError((reply.get('data') or {}).get('message', 'Discord refused the activity'))
        return reply

    def clear(self):
        if self.sock and self.card_id:
            try:
                self.set_activity(None)
            except OSError:
                pass
        self.card_id = None

    def close(self):
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass
        self.sock = None
