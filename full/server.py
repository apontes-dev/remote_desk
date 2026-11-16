#!/usr/bin/env python3
"""
Remote Desktop - full server (host side).

A more complete counterpart to the portable PowerShell host, for a machine where
you have full control (can install Python and, optionally, add a firewall rule).

Extra features over the portable version:
  * Fast capture with `mss`, input with `pynput` (cross-platform: Windows/macOS/Linux)
  * Token login with signed session cookies + brute-force throttling
  * Optional TLS (self-signed cert generated on first run) for encrypted transport
  * Multi-monitor: pick which display to stream, live
  * Clipboard sync (pull/push) between viewer and host
  * File transfer: upload to and download from a shared folder
  * Adjustable fps / quality / scale at runtime from the viewer toolbar

Viewer is a browser (served at `/`), so nothing needs to be installed to connect.

Dependencies:  pip install -r requirements.txt
Run:           python server.py --password SECRET
"""

import argparse
import base64
import hashlib
import hmac
import io
import json
import mimetypes
import os
import secrets
import socket
import ssl
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, unquote

try:
    import mss
    from PIL import Image
except ImportError:
    sys.exit("Missing deps. Run:  pip install -r requirements.txt")

try:
    from pynput.mouse import Controller as MouseController, Button
    from pynput.keyboard import Controller as KeyboardController, Key
    _HAVE_INPUT = True
except ImportError:
    _HAVE_INPUT = False

try:
    import pyperclip
    _HAVE_CLIP = True
except ImportError:
    _HAVE_CLIP = False

HERE = os.path.dirname(os.path.abspath(__file__))
VIEWER_HTML_PATH = os.path.join(HERE, "viewer.html")


# --------------------------------------------------------------------------
# Shared, thread-safe capture state
# --------------------------------------------------------------------------
class Capturer(threading.Thread):
    def __init__(self, cfg):
        super().__init__(daemon=True)
        self.cfg = cfg
        self.lock = threading.Lock()
        self.frame = None          # latest JPEG bytes
        self.seq = 0
        self.running = True
        self.monitors = []         # list of {left,top,width,height}
        self.region = None         # geometry of the monitor being captured

    def run(self):
        with mss.mss() as sct:
            # sct.monitors[0] is the full virtual screen, [1..] individual displays
            self.monitors = [dict(left=m["left"], top=m["top"],
                                  width=m["width"], height=m["height"])
                             for m in sct.monitors]
            while self.running:
                t0 = time.time()
                try:
                    idx = self.cfg["monitor"]
                    if idx < 0 or idx >= len(sct.monitors):
                        idx = 0
                    mon = sct.monitors[idx]
                    self.region = dict(left=mon["left"], top=mon["top"],
                                       width=mon["width"], height=mon["height"])
                    raw = sct.grab(mon)
                    img = Image.frombytes("RGB", raw.size, raw.bgra, "raw", "BGRX")

                    scale = self.cfg["scale"]
                    if scale < 1.0:
                        img = img.resize((max(1, int(img.width * scale)),
                                          max(1, int(img.height * scale))),
                                         Image.BILINEAR)
                    buf = io.BytesIO()
                    img.save(buf, format="JPEG", quality=self.cfg["quality"])
                    with self.lock:
                        self.frame = buf.getvalue()
                        self.seq += 1
                except Exception:
                    time.sleep(0.2)

                target = 1.0 / max(1, self.cfg["fps"])
                dt = time.time() - t0
                if dt < target:
                    time.sleep(target - dt)

    def latest(self):
        with self.lock:
            return self.seq, self.frame


# --------------------------------------------------------------------------
# Input injection
# --------------------------------------------------------------------------
class Injector:
    # JS event.key -> pynput Key
    SPECIAL = {}

    def __init__(self):
        self.ok = _HAVE_INPUT
        if self.ok:
            self.mouse = MouseController()
            self.kbd = KeyboardController()
            self.SPECIAL = {
                "Enter": Key.enter, "Tab": Key.tab, "Backspace": Key.backspace,
                "Escape": Key.esc, "Delete": Key.delete, "Insert": Key.insert,
                "Home": Key.home, "End": Key.end, "PageUp": Key.page_up,
                "PageDown": Key.page_down, "ArrowLeft": Key.left,
                "ArrowRight": Key.right, "ArrowUp": Key.up, "ArrowDown": Key.down,
                "Shift": Key.shift, "Control": Key.ctrl, "Alt": Key.alt,
                "Meta": Key.cmd, "CapsLock": Key.caps_lock, " ": Key.space,
                "F1": Key.f1, "F2": Key.f2, "F3": Key.f3, "F4": Key.f4,
                "F5": Key.f5, "F6": Key.f6, "F7": Key.f7, "F8": Key.f8,
                "F9": Key.f9, "F10": Key.f10, "F11": Key.f11, "F12": Key.f12,
            }

    def _abs(self, region, nx, ny):
        return (region["left"] + nx * region["width"],
                region["top"] + ny * region["height"])

    def handle(self, ev, region):
        if not self.ok or region is None:
            return
        t = ev.get("t")
        try:
            if t == "move":
                self.mouse.position = self._abs(region, ev["x"], ev["y"])
            elif t in ("down", "up"):
                self.mouse.position = self._abs(region, ev["x"], ev["y"])
                btn = {0: Button.left, 1: Button.middle, 2: Button.right}.get(ev.get("b", 0), Button.left)
                if t == "down":
                    self.mouse.press(btn)
                else:
                    self.mouse.release(btn)
            elif t == "wheel":
                self.mouse.scroll(int(ev.get("dx", 0) / 100), int(ev.get("dy", 0) / 100))
            elif t == "char":
                self.kbd.type(ev["c"])
            elif t == "key":
                k = self._key(ev)
                if k is not None:
                    if ev.get("down"):
                        self.kbd.press(k)
                    else:
                        self.kbd.release(k)
        except Exception:
            pass

    def _key(self, ev):
        name = ev.get("k", "")
        if name in self.SPECIAL:
            return self.SPECIAL[name]
        if len(name) == 1:
            return name
        return None


# --------------------------------------------------------------------------
# HTTP handler
# --------------------------------------------------------------------------
def make_handler(state):
    cfg = state["cfg"]
    cap = state["cap"]
    inj = state["inj"]
    secret = state["secret"]
    password = state["password"]
    share_dir = state["share_dir"]
    throttle = state["throttle"]

    def sign(val):
        mac = hmac.new(secret, val.encode(), hashlib.sha256).hexdigest()[:24]
        return f"{val}.{mac}"

    def valid_token(tok):
        if not tok or "." not in tok:
            return False
        val, mac = tok.rsplit(".", 1)
        good = hmac.new(secret, val.encode(), hashlib.sha256).hexdigest()[:24]
        return hmac.compare_digest(mac, good)

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *a):
            pass

        # -- helpers --
        def _cookies(self):
            raw = self.headers.get("Cookie", "")
            out = {}
            for part in raw.split(";"):
                if "=" in part:
                    k, v = part.strip().split("=", 1)
                    out[k] = v
            return out

        def _authed(self):
            q = parse_qs(urlparse(self.path).query)
            tok = (q.get("token", [None])[0]) or self._cookies().get("rd")
            return valid_token(tok)

        def _send(self, code, ctype, body, extra=None):
            if isinstance(body, str):
                body = body.encode()
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            if extra:
                for k, v in extra.items():
                    self.send_header(k, v)
            self.end_headers()
            self.wfile.write(body)

        # -- GET --
        def do_GET(self):
            p = urlparse(self.path)
            path = p.path

            if path == "/":
                try:
                    with open(VIEWER_HTML_PATH, "rb") as f:
                        html = f.read()
                except FileNotFoundError:
                    html = b"viewer.html not found next to server.py"
                return self._send(200, "text/html; charset=utf-8", html)

            if path == "/info":
                if not self._authed():
                    return self._send(403, "text/plain", "no")
                info = {
                    "monitors": cap.monitors,
                    "monitor": cfg["monitor"],
                    "fps": cfg["fps"], "quality": cfg["quality"],
                    "scale": cfg["scale"], "viewOnly": cfg["viewOnly"],
                    "input": inj.ok, "clipboard": _HAVE_CLIP,
                }
                return self._send(200, "application/json", json.dumps(info))

            if path == "/clipboard":
                if not self._authed():
                    return self._send(403, "text/plain", "no")
                text = ""
                if _HAVE_CLIP:
                    try:
                        text = pyperclip.paste()
                    except Exception:
                        text = ""
                return self._send(200, "application/json", json.dumps({"text": text}))

            if path == "/files":
                if not self._authed():
                    return self._send(403, "text/plain", "no")
                try:
                    names = sorted(os.listdir(share_dir))
                    items = [{"name": n,
                              "size": os.path.getsize(os.path.join(share_dir, n))}
                             for n in names if os.path.isfile(os.path.join(share_dir, n))]
                except Exception:
                    items = []
                return self._send(200, "application/json", json.dumps({"files": items}))

            if path == "/download":
                if not self._authed():
                    return self._send(403, "text/plain", "no")
                q = parse_qs(p.query)
                name = os.path.basename(unquote(q.get("name", [""])[0]))
                fp = os.path.join(share_dir, name)
                if not name or not os.path.isfile(fp):
                    return self._send(404, "text/plain", "not found")
                with open(fp, "rb") as f:
                    data = f.read()
                ctype = mimetypes.guess_type(name)[0] or "application/octet-stream"
                return self._send(200, ctype, data,
                                  {"Content-Disposition": f'attachment; filename="{name}"'})

            if path == "/stream":
                return self._stream()

            return self._send(404, "text/plain", "not found")

        # -- POST --
        def do_POST(self):
            p = urlparse(self.path)
            path = p.path
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length) if length else b""

            if path == "/auth":
                ip = self.client_address[0]
                now = time.time()
                tries = [t for t in throttle.get(ip, []) if now - t < 60]
                if len(tries) >= 8:
                    return self._send(429, "text/plain", "too many attempts")
                if hmac.compare_digest(body.decode("utf-8", "ignore"), password):
                    throttle[ip] = []
                    tok = sign(secrets.token_hex(8))
                    return self._send(200, "text/plain", "ok", {
                        "Set-Cookie": f"rd={tok}; Path=/; SameSite=Strict; HttpOnly"
                    })
                tries.append(now)
                throttle[ip] = tries
                return self._send(403, "text/plain", "no")

            if not self._authed():
                return self._send(403, "text/plain", "no")

            if path == "/input":
                if not cfg["viewOnly"]:
                    try:
                        events = json.loads(body or b"[]")
                        region = cap.region
                        for ev in events:
                            inj.handle(ev, region)
                    except Exception:
                        pass
                return self._send(200, "text/plain", "ok")

            if path == "/config":
                try:
                    c = json.loads(body or b"{}")
                    if "monitor" in c:  cfg["monitor"] = int(c["monitor"])
                    if "fps" in c:      cfg["fps"] = max(1, min(60, int(c["fps"])))
                    if "quality" in c:  cfg["quality"] = max(1, min(100, int(c["quality"])))
                    if "scale" in c:    cfg["scale"] = max(0.1, min(1.0, float(c["scale"])))
                    if "viewOnly" in c: cfg["viewOnly"] = bool(c["viewOnly"])
                except Exception:
                    pass
                return self._send(200, "text/plain", "ok")

            if path == "/clipboard":
                if _HAVE_CLIP:
                    try:
                        pyperclip.copy(json.loads(body or b'{}').get("text", ""))
                    except Exception:
                        pass
                return self._send(200, "text/plain", "ok")

            if path == "/upload":
                q = parse_qs(p.query)
                name = os.path.basename(unquote(q.get("name", ["upload.bin"])[0]))
                try:
                    with open(os.path.join(share_dir, name), "wb") as f:
                        f.write(body)
                    return self._send(200, "text/plain", "ok")
                except Exception as e:
                    return self._send(500, "text/plain", str(e))

            return self._send(404, "text/plain", "not found")

        # -- MJPEG stream --
        def _stream(self):
            if not self._authed():
                return self._send(403, "text/plain", "no")
            self.send_response(200)
            self.send_header("Content-Type",
                             "multipart/x-mixed-replace; boundary=rdframe")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            last = -1
            try:
                while True:
                    seq, frame = cap.latest()
                    if frame is not None and seq != last:
                        last = seq
                        self.wfile.write(b"\r\n--rdframe\r\n")
                        self.wfile.write(b"Content-Type: image/jpeg\r\n")
                        self.wfile.write(f"Content-Length: {len(frame)}\r\n\r\n".encode())
                        self.wfile.write(frame)
                    time.sleep(1.0 / (cfg["fps"] + 2))
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass

    return Handler


def local_ips():
    ips = set()
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None):
            addr = info[4][0]
            if "." in addr and not addr.startswith("127."):
                ips.add(addr)
    except Exception:
        pass
    return sorted(ips)


def ensure_cert(certfile, keyfile):
    if os.path.exists(certfile) and os.path.exists(keyfile):
        return
    try:
        from cryptography import x509
        from cryptography.x509.oid import NameOID
        from cryptography.hazmat.primitives import hashes, serialization
        from cryptography.hazmat.primitives.asymmetric import rsa
        import datetime
    except ImportError:
        sys.exit("TLS requested but 'cryptography' is not installed.\n"
                 "  pip install cryptography   (or omit --tls)")
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "remote-desktop")])
    cert = (x509.CertificateBuilder()
            .subject_name(name).issuer_name(name)
            .public_key(key.public_key())
            .serial_number(x509.random_serial_number())
            .not_valid_before(datetime.datetime.utcnow())
            .not_valid_after(datetime.datetime.utcnow() + datetime.timedelta(days=3650))
            .sign(key, hashes.SHA256()))
    with open(keyfile, "wb") as f:
        f.write(key.private_bytes(serialization.Encoding.PEM,
                                  serialization.PrivateFormat.TraditionalOpenSSL,
                                  serialization.NoEncryption()))
    with open(certfile, "wb") as f:
        f.write(cert.public_bytes(serialization.Encoding.PEM))


def main():
    ap = argparse.ArgumentParser(description="Remote Desktop full server")
    ap.add_argument("--port", type=int, default=8766)
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--password", default="")
    ap.add_argument("--fps", type=int, default=15)
    ap.add_argument("--quality", type=int, default=60)
    ap.add_argument("--scale", type=float, default=1.0)
    ap.add_argument("--monitor", type=int, default=0,
                    help="0 = all displays, 1 = first, 2 = second, ...")
    ap.add_argument("--view-only", action="store_true")
    ap.add_argument("--share", default=os.path.join(HERE, "shared"),
                    help="folder for file transfer")
    ap.add_argument("--tls", action="store_true", help="serve over HTTPS (self-signed)")
    args = ap.parse_args()

    password = args.password or "".join(
        secrets.choice("23456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz")
        for _ in range(10))

    os.makedirs(args.share, exist_ok=True)

    cfg = dict(fps=args.fps, quality=args.quality, scale=args.scale,
               monitor=args.monitor, viewOnly=args.view_only)
    cap = Capturer(cfg)
    cap.start()
    time.sleep(0.3)  # let it enumerate monitors + grab a first frame

    state = dict(cfg=cfg, cap=cap, inj=Injector(), secret=secrets.token_bytes(32),
                 password=password, share_dir=args.share, throttle={})

    httpd = ThreadingHTTPServer((args.bind, args.port), make_handler(state))

    scheme = "http"
    if args.tls:
        certfile = os.path.join(HERE, "cert.pem")
        keyfile = os.path.join(HERE, "key.pem")
        ensure_cert(certfile, keyfile)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        ctx.load_cert_chain(certfile, keyfile)
        httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
        scheme = "https"

    print("\n  " + "=" * 56)
    print("   Remote Desktop (full) server is running")
    print("  " + "=" * 56 + "\n")
    print("   Open a browser on the viewing machine:")
    for ip in local_ips():
        print(f"       {scheme}://{ip}:{args.port}/")
    print(f"       {scheme}://localhost:{args.port}/   (this machine)\n")
    print(f"   Password : {password}")
    print(f"   Input: {state['inj'].ok}   Clipboard: {_HAVE_CLIP}   "
          f"TLS: {args.tls}   View-only: {args.view_only}")
    if args.tls:
        print("   (self-signed cert: your browser will warn once - accept it)")
    print("\n   Press Ctrl+C to stop.\n")

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        cap.running = False
        httpd.shutdown()
        print("Stopped.")


if __name__ == "__main__":
    main()
