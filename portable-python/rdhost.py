#!/usr/bin/env python3
r"""
Portable Remote Desktop host - Python edition, pure standard library.

No installation, no administrator rights, not scanned by AMSI. Uses only the
Python standard library + ctypes into DLLs that ship with Windows (gdi32,
gdiplus, user32). Runs unmodified on the official *embeddable* Python.

Features
--------
  * Browser-based control panel (the GUI) that auto-opens for the operator:
    random password with one-click regenerate, LAN <-> Internet toggle,
    trusted-computer management, live quality/fps settings.
  * Random auto-generated access password.
  * Trusted computers: approve a computer once and it reconnects automatically
    (no password), via a signed device cookie. Optional auto-approve.
  * Internet access with no router/admin changes, through a Cloudflare quick
    tunnel (cloudflared) - a single portable binary, outbound only.
  * MJPEG screen stream + mouse/keyboard injection, same as before.

Usage
-----
    python rdhost.py                 # opens the control panel in your browser
    python rdhost.py --selftest      # verify the engine, no capture/server/input
"""

import argparse
import ctypes
import hashlib
import hmac
import json
import os
import re
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
import uuid
import webbrowser
from ctypes import wintypes
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

if sys.platform != "win32":
    sys.exit("rdhost.py targets Windows (uses gdi32/gdiplus/user32).")

HERE = os.path.dirname(os.path.abspath(__file__))
STATE_PATH = os.path.join(HERE, "rd_state.json")

# ---------------------------------------------------------------------------
# DLLs
# ---------------------------------------------------------------------------
user32 = ctypes.WinDLL("user32", use_last_error=True)
gdi32 = ctypes.WinDLL("gdi32", use_last_error=True)
gdiplus = ctypes.WinDLL("gdiplus", use_last_error=True)

try:
    user32.SetProcessDPIAware()
except Exception:
    pass

# ---------------------------------------------------------------------------
# GUID helper (for GDI+ encoder CLSIDs)
# ---------------------------------------------------------------------------
class GUID(ctypes.Structure):
    _fields_ = [("Data1", ctypes.c_uint32), ("Data2", ctypes.c_uint16),
                ("Data3", ctypes.c_uint16), ("Data4", ctypes.c_ubyte * 8)]

    def __init__(self, text=None):
        super().__init__()
        if text:
            u = uuid.UUID(text)
            self.Data1, self.Data2, self.Data3 = u.fields[0], u.fields[1], u.fields[2]
            for i, b in enumerate(u.bytes[8:16]):
                self.Data4[i] = b

JPEG_ENCODER = GUID("{557CF401-1A04-11D3-9A73-0000F81EF32E}")
ENCODER_QUALITY = GUID("{1D5BE4B5-FA4A-452D-9CDD-5DB35105E7EB}")

class EncoderParameter(ctypes.Structure):
    _fields_ = [("Guid", GUID), ("NumberOfValues", ctypes.c_uint32),
                ("Type", ctypes.c_uint32), ("Value", ctypes.c_void_p)]

class EncoderParameters(ctypes.Structure):
    _fields_ = [("Count", ctypes.c_uint32), ("Parameter", EncoderParameter * 1)]

# ---------------------------------------------------------------------------
# Win32 prototypes (restype/argtypes mandatory on 64-bit)
# ---------------------------------------------------------------------------
ULONG_PTR = ctypes.c_size_t

user32.GetDC.restype = wintypes.HDC
user32.GetDC.argtypes = [wintypes.HWND]
user32.ReleaseDC.argtypes = [wintypes.HWND, wintypes.HDC]
user32.GetSystemMetrics.restype = ctypes.c_int
user32.GetSystemMetrics.argtypes = [ctypes.c_int]

gdi32.CreateCompatibleDC.restype = wintypes.HDC
gdi32.CreateCompatibleDC.argtypes = [wintypes.HDC]
gdi32.CreateCompatibleBitmap.restype = wintypes.HBITMAP
gdi32.CreateCompatibleBitmap.argtypes = [wintypes.HDC, ctypes.c_int, ctypes.c_int]
gdi32.SelectObject.restype = wintypes.HGDIOBJ
gdi32.SelectObject.argtypes = [wintypes.HDC, wintypes.HGDIOBJ]
gdi32.DeleteObject.argtypes = [wintypes.HGDIOBJ]
gdi32.DeleteDC.argtypes = [wintypes.HDC]
gdi32.BitBlt.argtypes = [wintypes.HDC, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                         ctypes.c_int, wintypes.HDC, ctypes.c_int, ctypes.c_int,
                         wintypes.DWORD]
gdi32.StretchBlt.argtypes = [wintypes.HDC, ctypes.c_int, ctypes.c_int, ctypes.c_int,
                             ctypes.c_int, wintypes.HDC, ctypes.c_int, ctypes.c_int,
                             ctypes.c_int, ctypes.c_int, wintypes.DWORD]
gdi32.SetStretchBltMode.argtypes = [wintypes.HDC, ctypes.c_int]

gdiplus.GdipCreateBitmapFromHBITMAP.argtypes = [
    wintypes.HBITMAP, wintypes.HPALETTE, ctypes.POINTER(ctypes.c_void_p)]
gdiplus.GdipSaveImageToFile.argtypes = [
    ctypes.c_void_p, ctypes.c_wchar_p, ctypes.POINTER(GUID),
    ctypes.POINTER(EncoderParameters)]
gdiplus.GdipDisposeImage.argtypes = [ctypes.c_void_p]

class POINT(ctypes.Structure):
    _fields_ = [("x", ctypes.c_long), ("y", ctypes.c_long)]

class CURSORINFO(ctypes.Structure):
    _fields_ = [("cbSize", wintypes.DWORD), ("flags", wintypes.DWORD),
                ("hCursor", ctypes.c_void_p), ("ptScreenPos", POINT)]

user32.GetCursorInfo.argtypes = [ctypes.POINTER(CURSORINFO)]
user32.DrawIconEx.argtypes = [wintypes.HDC, ctypes.c_int, ctypes.c_int,
                              ctypes.c_void_p, ctypes.c_int, ctypes.c_int,
                              ctypes.c_uint, ctypes.c_void_p, ctypes.c_uint]

SRCCOPY = 0x00CC0020
CAPTUREBLT = 0x40000000
HALFTONE = 4
DI_NORMAL = 0x0003
CURSOR_SHOWING = 0x0001
SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN = 76, 77
SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN = 78, 79

class GdiplusStartupInput(ctypes.Structure):
    _fields_ = [("GdiplusVersion", ctypes.c_uint32),
                ("DebugEventCallback", ctypes.c_void_p),
                ("SuppressBackgroundThread", ctypes.c_int),
                ("SuppressExternalCodecs", ctypes.c_int)]

_gdip_token = ctypes.c_void_p()
_si = GdiplusStartupInput(1, None, 0, 0)
gdiplus.GdiplusStartup(ctypes.byref(_gdip_token), ctypes.byref(_si), None)


# ===========================================================================
# Persistent state (password, secret, trusted computers, settings, mode)
# ===========================================================================
_state_lock = threading.Lock()

def gen_password(n=10):
    alphabet = "23456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz"
    return "".join(secrets.choice(alphabet) for _ in range(n))

def default_state():
    return {
        "secret": secrets.token_hex(32),
        "password": gen_password(),
        "mode": "lan",                       # "lan" | "internet"
        "autoApprove": False,
        "settings": {"fps": 12, "quality": 55, "scale": 1.0, "viewOnly": False},
        "trusted": {},                       # id -> {label, ip, added}
        "pending": {},                       # id -> {label, ip, added}
    }

def load_state():
    try:
        with open(STATE_PATH, "r", encoding="utf-8") as f:
            s = json.load(f)
        base = default_state()
        base.update({k: s.get(k, base[k]) for k in base})
        base["settings"].update(s.get("settings", {}))
        return base
    except Exception:
        return default_state()

def save_state(state):
    with _state_lock:
        try:
            tmp = STATE_PATH + ".tmp"
            with open(tmp, "w", encoding="utf-8") as f:
                json.dump(state, f, indent=2)
            os.replace(tmp, STATE_PATH)
        except Exception:
            pass

# signed tokens for cookies -------------------------------------------------
def sign(secret_hex, value):
    mac = hmac.new(bytes.fromhex(secret_hex), value.encode(), hashlib.sha256).hexdigest()[:24]
    return value + "." + mac

def verify(secret_hex, token):
    if not token or "." not in token:
        return None
    value, mac = token.rsplit(".", 1)
    good = hmac.new(bytes.fromhex(secret_hex), value.encode(), hashlib.sha256).hexdigest()[:24]
    return value if hmac.compare_digest(mac, good) else None


# ===========================================================================
# Cloudflare quick-tunnel manager (Internet access, no admin / no port-forward)
# ===========================================================================
TUNNEL_RE = re.compile(r"https://[a-z0-9-]+\.trycloudflare\.com")

def find_cloudflared():
    local = os.path.join(HERE, "cloudflared.exe")
    if os.path.isfile(local):
        return local
    return shutil.which("cloudflared") or shutil.which("cloudflared.exe")

class TunnelManager:
    def __init__(self, port):
        self.port = port
        self.proc = None
        self.url = None
        self.status = "stopped"      # stopped|starting|running|missing|error
        self._lock = threading.Lock()

    def start(self):
        with self._lock:
            if self.status in ("starting", "running"):
                return
            exe = find_cloudflared()
            if not exe:
                self.status = "missing"
                return
            self.url = None
            self.status = "starting"
            try:
                self.proc = subprocess.Popen(
                    [exe, "tunnel", "--no-autoupdate", "--url",
                     "http://localhost:%d" % self.port],
                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                    text=True, encoding="utf-8", errors="replace",
                    creationflags=0x08000000)  # CREATE_NO_WINDOW
            except Exception:
                self.status = "error"
                return
            threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self):
        try:
            for line in self.proc.stdout:
                m = TUNNEL_RE.search(line)
                if m:
                    self.url = m.group(0)
                    self.status = "running"
        except Exception:
            pass
        if self.status != "stopped":
            self.status = "error" if self.url is None else "stopped"

    def stop(self):
        with self._lock:
            if self.proc:
                try:
                    self.proc.terminate()
                except Exception:
                    pass
                self.proc = None
            self.url = None
            self.status = "stopped"


# ===========================================================================
# Screen capture thread
# ===========================================================================
class Capturer(threading.Thread):
    def __init__(self, cfg):
        super().__init__(daemon=True)
        self.cfg = cfg
        self.lock = threading.Lock()
        self.frame = None
        self.seq = 0
        self.running = True
        self.vx = self.vy = 0
        self.vw = self.vh = 0
        self._hscr = None
        self._hdc_full = None
        self._bmp_full = None
        self._hdc_scaled = None
        self._bmp_scaled = None
        self._cur_w = self._cur_h = 0
        self._cur_sw = self._cur_sh = 0
        self._tmp = os.path.join(tempfile.gettempdir(), "rdhost_%d.jpg" % os.getpid())

    def _virtual_screen(self):
        gsm = user32.GetSystemMetrics
        return (gsm(SM_XVIRTUALSCREEN), gsm(SM_YVIRTUALSCREEN),
                gsm(SM_CXVIRTUALSCREEN), gsm(SM_CYVIRTUALSCREEN))

    def _ensure_buffers(self, w, h, sw, sh):
        if self._hscr is None:
            self._hscr = user32.GetDC(None)
        if self._bmp_full is None or self._cur_w != w or self._cur_h != h:
            if self._bmp_full:
                gdi32.DeleteObject(self._bmp_full)
            if self._hdc_full:
                gdi32.DeleteDC(self._hdc_full)
            self._hdc_full = gdi32.CreateCompatibleDC(self._hscr)
            self._bmp_full = gdi32.CreateCompatibleBitmap(self._hscr, w, h)
            gdi32.SelectObject(self._hdc_full, self._bmp_full)
            self._cur_w, self._cur_h = w, h
        if (sw, sh) != (w, h):
            if self._bmp_scaled is None or self._cur_sw != sw or self._cur_sh != sh:
                if self._bmp_scaled:
                    gdi32.DeleteObject(self._bmp_scaled)
                if self._hdc_scaled:
                    gdi32.DeleteDC(self._hdc_scaled)
                self._hdc_scaled = gdi32.CreateCompatibleDC(self._hscr)
                self._bmp_scaled = gdi32.CreateCompatibleBitmap(self._hscr, sw, sh)
                gdi32.SelectObject(self._hdc_scaled, self._bmp_scaled)
                gdi32.SetStretchBltMode(self._hdc_scaled, HALFTONE)
                self._cur_sw, self._cur_sh = sw, sh

    def _encode(self, hbmp, quality):
        img = ctypes.c_void_p()
        if gdiplus.GdipCreateBitmapFromHBITMAP(hbmp, None, ctypes.byref(img)) != 0:
            return None
        try:
            q = ctypes.c_long(int(quality))
            ep = EncoderParameters()
            ep.Count = 1
            ep.Parameter[0].Guid = ENCODER_QUALITY
            ep.Parameter[0].Type = 4
            ep.Parameter[0].NumberOfValues = 1
            ep.Parameter[0].Value = ctypes.cast(ctypes.byref(q), ctypes.c_void_p)
            if gdiplus.GdipSaveImageToFile(img, self._tmp, ctypes.byref(JPEG_ENCODER),
                                           ctypes.byref(ep)) != 0:
                return None
        finally:
            gdiplus.GdipDisposeImage(img)
        try:
            with open(self._tmp, "rb") as f:
                return f.read()
        except OSError:
            return None

    def _draw_cursor(self, hdc, ox, oy):
        try:
            ci = CURSORINFO()
            ci.cbSize = ctypes.sizeof(CURSORINFO)
            if user32.GetCursorInfo(ctypes.byref(ci)) and (ci.flags & CURSOR_SHOWING):
                user32.DrawIconEx(hdc, ci.ptScreenPos.x - ox, ci.ptScreenPos.y - oy,
                                  ci.hCursor, 0, 0, 0, None, DI_NORMAL)
        except Exception:
            pass

    def run(self):
        while self.running:
            t0 = time.time()
            try:
                vx, vy, vw, vh = self._virtual_screen()
                if vw <= 0 or vh <= 0:
                    time.sleep(0.2)
                    continue
                scale = self.cfg["scale"]
                sw = max(1, int(vw * scale)) if scale < 1.0 else vw
                sh = max(1, int(vh * scale)) if scale < 1.0 else vh
                self.vx, self.vy, self.vw, self.vh = vx, vy, vw, vh
                self._ensure_buffers(vw, vh, sw, sh)
                gdi32.BitBlt(self._hdc_full, 0, 0, vw, vh,
                             self._hscr, vx, vy, SRCCOPY | CAPTUREBLT)
                self._draw_cursor(self._hdc_full, vx, vy)
                if (sw, sh) != (vw, vh):
                    gdi32.StretchBlt(self._hdc_scaled, 0, 0, sw, sh,
                                     self._hdc_full, 0, 0, vw, vh, SRCCOPY)
                    out_bmp = self._bmp_scaled
                else:
                    out_bmp = self._bmp_full
                data = self._encode(out_bmp, self.cfg["quality"])
                if data:
                    with self.lock:
                        self.frame = data
                        self.seq += 1
            except Exception:
                time.sleep(0.2)
            target = 1.0 / max(1, self.cfg["fps"])
            dt = time.time() - t0
            if dt < target:
                time.sleep(target - dt)
        for h in (self._bmp_full, self._bmp_scaled):
            if h:
                gdi32.DeleteObject(h)
        for h in (self._hdc_full, self._hdc_scaled):
            if h:
                gdi32.DeleteDC(h)
        if self._hscr:
            user32.ReleaseDC(None, self._hscr)
        try:
            os.remove(self._tmp)
        except OSError:
            pass

    def latest(self):
        with self.lock:
            return self.seq, self.frame


# ===========================================================================
# Input injection (user32 SendInput)
# ===========================================================================
class MOUSEINPUT(ctypes.Structure):
    _fields_ = [("dx", ctypes.c_long), ("dy", ctypes.c_long),
                ("mouseData", wintypes.DWORD), ("dwFlags", wintypes.DWORD),
                ("time", wintypes.DWORD), ("dwExtraInfo", ULONG_PTR)]

class KEYBDINPUT(ctypes.Structure):
    _fields_ = [("wVk", wintypes.WORD), ("wScan", wintypes.WORD),
                ("dwFlags", wintypes.DWORD), ("time", wintypes.DWORD),
                ("dwExtraInfo", ULONG_PTR)]

class _INPUTUNION(ctypes.Union):
    _fields_ = [("mi", MOUSEINPUT), ("ki", KEYBDINPUT)]

class INPUT(ctypes.Structure):
    _fields_ = [("type", wintypes.DWORD), ("u", _INPUTUNION)]

user32.SendInput.argtypes = [ctypes.c_uint, ctypes.POINTER(INPUT), ctypes.c_int]

INPUT_MOUSE, INPUT_KEYBOARD = 0, 1
ME_MOVE, ME_ABSOLUTE, ME_VIRTUALDESK = 0x0001, 0x8000, 0x4000
ME_LEFTDOWN, ME_LEFTUP = 0x0002, 0x0004
ME_RIGHTDOWN, ME_RIGHTUP = 0x0008, 0x0010
ME_MIDDLEDOWN, ME_MIDDLEUP = 0x0020, 0x0040
ME_WHEEL, ME_HWHEEL = 0x0800, 0x1000
KE_KEYUP, KE_UNICODE = 0x0002, 0x0004

VK = {
    "Enter": 0x0D, "Tab": 0x09, "Backspace": 0x08, "Escape": 0x1B, "Delete": 0x2E,
    "Insert": 0x2D, "Home": 0x24, "End": 0x23, "PageUp": 0x21, "PageDown": 0x22,
    "ArrowLeft": 0x25, "ArrowUp": 0x26, "ArrowRight": 0x27, "ArrowDown": 0x28,
    "Shift": 0x10, "Control": 0x11, "Alt": 0x12, "Meta": 0x5B, "CapsLock": 0x14,
    " ": 0x20, "PrintScreen": 0x2C,
    "F1": 0x70, "F2": 0x71, "F3": 0x72, "F4": 0x73, "F5": 0x74, "F6": 0x75,
    "F7": 0x76, "F8": 0x77, "F9": 0x78, "F10": 0x79, "F11": 0x7A, "F12": 0x7B,
}


class Injector:
    def __init__(self):
        self.ok = True

    def _send(self, inp):
        user32.SendInput(1, ctypes.byref(inp), ctypes.sizeof(INPUT))

    def _move_abs(self, region, nx, ny):
        vx, vy, vw, vh = region
        ax = min(65535, max(0, int(nx * vw * 65535 / max(1, vw - 1))))
        ay = min(65535, max(0, int(ny * vh * 65535 / max(1, vh - 1))))
        inp = INPUT(type=INPUT_MOUSE)
        inp.u.mi = MOUSEINPUT(ax, ay, 0, ME_MOVE | ME_ABSOLUTE | ME_VIRTUALDESK, 0, 0)
        self._send(inp)

    def _button(self, b, down):
        flags = {(0, True): ME_LEFTDOWN, (0, False): ME_LEFTUP,
                 (1, True): ME_MIDDLEDOWN, (1, False): ME_MIDDLEUP,
                 (2, True): ME_RIGHTDOWN, (2, False): ME_RIGHTUP}.get((b, down))
        if flags is None:
            return
        inp = INPUT(type=INPUT_MOUSE)
        inp.u.mi = MOUSEINPUT(0, 0, 0, flags, 0, 0)
        self._send(inp)

    def _wheel(self, delta, horizontal):
        inp = INPUT(type=INPUT_MOUSE)
        inp.u.mi = MOUSEINPUT(0, 0, ctypes.c_long(int(delta)).value & 0xFFFFFFFF,
                              ME_HWHEEL if horizontal else ME_WHEEL, 0, 0)
        self._send(inp)

    def _char(self, ch):
        for c in ch:
            code = ord(c)
            d = INPUT(type=INPUT_KEYBOARD); d.u.ki = KEYBDINPUT(0, code, KE_UNICODE, 0, 0)
            u = INPUT(type=INPUT_KEYBOARD); u.u.ki = KEYBDINPUT(0, code, KE_UNICODE | KE_KEYUP, 0, 0)
            self._send(d); self._send(u)

    def _vk(self, ev):
        name = ev.get("k", "")
        if name in VK:
            return VK[name]
        if len(name) == 1:
            o = ord(name.upper())
            if (0x30 <= o <= 0x39) or (0x41 <= o <= 0x5A):
                return o
        return 0

    def _key(self, vk, down):
        inp = INPUT(type=INPUT_KEYBOARD)
        inp.u.ki = KEYBDINPUT(vk, 0, 0 if down else KE_KEYUP, 0, 0)
        self._send(inp)

    def handle(self, ev, region):
        try:
            t = ev.get("t")
            if t == "move":
                self._move_abs(region, ev["x"], ev["y"])
            elif t == "down":
                self._move_abs(region, ev["x"], ev["y"]); self._button(int(ev.get("b", 0)), True)
            elif t == "up":
                self._button(int(ev.get("b", 0)), False)
            elif t == "wheel":
                if ev.get("dy"): self._wheel(ev["dy"], False)
                if ev.get("dx"): self._wheel(ev["dx"], True)
            elif t == "char":
                self._char(ev.get("c", ""))
            elif t == "key":
                vk = self._vk(ev)
                if vk: self._key(vk, bool(ev.get("down")))
        except Exception:
            pass


# ===========================================================================
# HTML: viewer (remote users) and control panel (operator)
# ===========================================================================
VIEWER_HTML = r"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Remote Desktop</title>
<style>
 :root{--bg:#0b0d10;--fg:#e8eaed;--accent:#3b82f6;--bar:#15181d}
 *{box-sizing:border-box}html,body{margin:0;height:100%;background:var(--bg);color:var(--fg);
  font-family:system-ui,Segoe UI,sans-serif;overflow:hidden}
 #login{display:flex;align-items:center;justify-content:center;height:100%}
 .card{background:var(--bar);padding:28px 32px;border-radius:14px;box-shadow:0 12px 40px rgba(0,0,0,.5);width:320px}
 h1{font-size:18px;margin:0 0 4px}.sub{font-size:13px;color:#9aa0a6;margin:0 0 18px}
 input{width:100%;padding:10px 12px;border-radius:8px;border:1px solid #2a2f37;background:#0b0d10;color:var(--fg);font-size:14px;margin-bottom:12px}
 button,.btn{background:var(--accent);color:#fff;border:0;padding:8px 12px;border-radius:8px;font-size:13px;cursor:pointer}
 .btn.sec{background:#2a2f37}.err{color:#f87171;font-size:12px;min-height:16px}
 #app{display:none;flex-direction:column;height:100%}
 #bar{display:flex;align-items:center;gap:10px;background:var(--bar);padding:6px 10px;font-size:12px;flex:0 0 auto}
 #bar .dot{width:9px;height:9px;border-radius:50%;background:#f59e0b}#bar .dot.ok{background:#22c55e}#bar .sp{flex:1}
 #bar label{color:#9aa0a6;display:flex;align-items:center;gap:4px}
 #stage{flex:1;overflow:auto;display:flex;align-items:center;justify-content:center;background:#000}
 #screen{max-width:100%;max-height:100%;display:block;cursor:none}
</style></head><body>
 <div id="login"><div class="card"><h1>Remote Desktop</h1>
  <p class="sub">Enter the access password shown on the host.</p>
  <input id="pw" type="password" placeholder="Password" autocomplete="off">
  <div class="err" id="loginErr"></div><button id="connectBtn" style="width:100%">Connect</button></div></div>
 <div id="app"><div id="bar"><span class="dot" id="dot"></span><span id="status">connecting...</span>
   <span class="sp"></span><label>View only <input type="checkbox" id="viewOnly"></label>
   <span class="btn sec" id="fsBtn">Fullscreen</span>
   <span class="btn sec" id="cadBtn" title="Ctrl+Alt+Del cannot be injected without system rights">Ctrl+Alt+End</span></div>
  <div id="stage"><img id="screen" draggable="false"></div></div>
<script>
const $=s=>document.querySelector(s);
async function session(){try{return await (await fetch("/session",{cache:"no-store"})).json();}catch(e){return{authed:false};}}
async function boot(){const s=await session(); if(s.authed){showApp(s);}else{$("#login").style.display="flex";}}
$("#connectBtn").onclick=login; $("#pw").addEventListener("keydown",e=>{if(e.key==="Enter")login();});
async function login(){const pw=$("#pw").value.trim(); if(!pw)return; $("#loginErr").textContent=""; $("#connectBtn").disabled=true;
 try{const r=await fetch("/auth",{method:"POST",body:pw}); if(!r.ok)throw new Error(r.status===429?"Too many attempts":"Wrong password");
  const s=await session(); showApp(s);}catch(e){$("#loginErr").textContent=e.message||"Failed"; $("#connectBtn").disabled=false;}}
function showApp(s){$("#login").style.display="none"; $("#app").style.display="flex";
 $("#viewOnly").checked=!!s.viewOnly; $("#viewOnly").disabled=!!s.viewOnly; beginStream(); wireInput();}
function beginStream(){const img=$("#screen");
 img.onload=()=>{$("#dot").classList.add("ok");$("#status").textContent="connected";};
 img.onerror=()=>{$("#dot").classList.remove("ok");$("#status").textContent="reconnecting...";setTimeout(()=>img.src="/stream?_="+Date.now(),1000);};
 img.src="/stream?_="+Date.now();}
let sending=false,queue=[];
async function flush(){if(sending||!queue.length)return;sending=true;const b=queue;queue=[];
 try{await fetch("/input",{method:"POST",body:JSON.stringify(b)});}catch(e){}sending=false;if(queue.length)flush();}
function send(ev){if($("#viewOnly").checked)return;queue.push(ev);if(queue.length>50)queue.shift();flush();}
function coords(e){const img=$("#screen"),r=img.getBoundingClientRect();
 return{x:Math.max(0,Math.min(1,(e.clientX-r.left)/r.width)),y:Math.max(0,Math.min(1,(e.clientY-r.top)/r.height))};}
function wireInput(){const img=$("#screen");let last=0;
 img.addEventListener("mousemove",e=>{const n=performance.now();if(n-last<25)return;last=n;const c=coords(e);send({t:"move",x:c.x,y:c.y});});
 img.addEventListener("mousedown",e=>{e.preventDefault();const c=coords(e);send({t:"down",x:c.x,y:c.y,b:e.button});});
 window.addEventListener("mouseup",e=>{const c=coords(e);send({t:"up",x:c.x,y:c.y,b:e.button});});
 img.addEventListener("contextmenu",e=>e.preventDefault());
 img.addEventListener("wheel",e=>{e.preventDefault();send({t:"wheel",dy:-e.deltaY,dx:-e.deltaX});},{passive:false});
 window.addEventListener("keydown",e=>{if($("#app").style.display==="none")return;e.preventDefault();
  if(e.key.length===1&&!e.ctrlKey&&!e.altKey&&!e.metaKey)send({t:"char",c:e.key});else send({t:"key",k:e.key,down:true});});
 window.addEventListener("keyup",e=>{if($("#app").style.display==="none")return;e.preventDefault();
  if(!(e.key.length===1&&!e.ctrlKey&&!e.altKey&&!e.metaKey))send({t:"key",k:e.key,down:false});});
 $("#fsBtn").onclick=()=>document.fullscreenElement?document.exitFullscreen():document.documentElement.requestFullscreen();
 $("#cadBtn").onclick=()=>{["Control","Alt","End"].forEach(k=>send({t:"key",k:k,down:true}));["End","Alt","Control"].forEach(k=>send({t:"key",k:k,down:false}));};}
boot();
</script></body></html>"""

PANEL_HTML = r"""<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>Remote Desktop - Control</title>
<style>
 :root{--bg:#0b0d10;--fg:#e8eaed;--accent:#3b82f6;--bar:#15181d;--mut:#9aa0a6;--ok:#22c55e;--warn:#f59e0b;--bad:#f87171}
 *{box-sizing:border-box}body{margin:0;background:var(--bg);color:var(--fg);font-family:system-ui,Segoe UI,sans-serif}
 .wrap{max-width:680px;margin:0 auto;padding:22px 16px 60px}
 h1{font-size:20px;margin:0 0 2px}.sub{color:var(--mut);font-size:13px;margin:0 0 18px}
 .card{background:var(--bar);border:1px solid #22262d;border-radius:12px;padding:16px;margin-bottom:14px}
 .card h2{font-size:13px;text-transform:uppercase;letter-spacing:.04em;color:var(--mut);margin:0 0 12px}
 .row{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
 .row+.row{margin-top:10px}
 input[type=text],input[type=number]{background:#0b0d10;color:var(--fg);border:1px solid #2a2f37;border-radius:8px;padding:8px 10px;font-size:14px}
 .mono{font-family:ui-monospace,Consolas,monospace}
 button,.btn{background:var(--accent);color:#fff;border:0;padding:8px 12px;border-radius:8px;font-size:13px;cursor:pointer}
 .btn.sec{background:#2a2f37}.btn.bad{background:#7f1d1d}.btn.ok{background:#166534}
 .pill{display:inline-flex;align-items:center;gap:6px;font-size:12px;color:var(--mut)}
 .dot{width:9px;height:9px;border-radius:50%;background:var(--mut)}
 .dot.ok{background:var(--ok)}.dot.warn{background:var(--warn)}.dot.bad{background:var(--bad)}
 .seg{display:inline-flex;border:1px solid #2a2f37;border-radius:9px;overflow:hidden}
 .seg button{background:transparent;color:var(--mut);border:0;padding:8px 16px;cursor:pointer}
 .seg button.on{background:var(--accent);color:#fff}
 .url{word-break:break-all;background:#0b0d10;border:1px solid #2a2f37;border-radius:8px;padding:8px 10px;font-size:13px}
 table{width:100%;border-collapse:collapse;font-size:13px}td,th{text-align:left;padding:6px 6px;border-bottom:1px solid #22262d}
 th{color:var(--mut);font-weight:500}.muted{color:var(--mut);font-size:12px}
 .toast{position:fixed;bottom:16px;left:50%;transform:translateX(-50%);background:#166534;color:#fff;padding:8px 14px;border-radius:8px;font-size:13px;opacity:0;transition:.2s}
 .toast.show{opacity:1}
 label.sw{display:inline-flex;align-items:center;gap:8px;cursor:pointer}
</style></head><body><div class="wrap">
 <h1>Remote Desktop &mdash; Control Panel</h1>
 <p class="sub">Operator console. Keep this window private &mdash; it configures access to this PC.</p>

 <div class="card"><h2>Access password</h2>
  <div class="row"><input id="pw" type="text" class="mono" style="flex:1;min-width:160px" readonly>
   <button class="btn sec" id="copyPw">Copy</button><button class="btn" id="regen">Regenerate</button></div>
  <div class="muted" style="margin-top:8px">Viewers enter this once. Approved computers reconnect without it.</div>
 </div>

 <div class="card"><h2>Where people connect</h2>
  <div class="row"><span class="muted">Mode</span>
   <span class="seg"><button id="mLan" onclick="setMode('lan')">LAN only</button>
    <button id="mNet" onclick="setMode('internet')">Internet</button></span>
   <span class="pill"><span class="dot" id="netDot"></span><span id="netTxt"></span></span></div>
  <div class="row" id="lanBox" style="flex-direction:column;align-items:stretch"></div>
  <div class="row" id="netBox" style="flex-direction:column;align-items:stretch;display:none">
   <div class="url mono" id="pubUrl">starting tunnel...</div>
   <div class="row"><button class="btn sec" id="copyUrl">Copy link</button>
    <span class="muted" id="netHint"></span></div></div>
 </div>

 <div class="card"><h2>Trusted computers</h2>
  <label class="sw"><input type="checkbox" id="autoApprove"> Automatically approve new computers (give access without manual approval)</label>
  <div id="pendingWrap" style="margin-top:12px"></div>
  <table id="trustedTbl" style="margin-top:10px"><thead><tr><th>Computer</th><th>IP</th><th>Added</th><th></th></tr></thead><tbody></tbody></table>
  <div class="muted" id="trustedEmpty" style="margin-top:6px">No approved computers yet.</div>
 </div>

 <div class="card"><h2>Quality & input</h2>
  <div class="row"><label class="sw"><input type="checkbox" id="viewOnly"> View only (ignore all remote input)</label></div>
  <div class="row"><span class="muted" style="width:70px">FPS</span><input type="number" id="fps" min="1" max="30" style="width:80px">
   <span class="muted" style="width:70px">Quality</span><input type="number" id="quality" min="10" max="95" style="width:80px">
   <span class="muted" style="width:70px">Scale</span><input type="number" id="scale" min="0.2" max="1" step="0.05" style="width:80px">
   <button class="btn sec" id="applyQ">Apply</button></div>
 </div>
</div>
<div class="toast" id="toast"></div>
<script>
const $=s=>document.querySelector(s);
const K=new URLSearchParams(location.search).get("k")||"";
function api(path,opts={}){opts.headers=Object.assign({"X-Admin":K},opts.headers||{});opts.cache="no-store";return fetch(path,opts);}
function toast(t){const e=$("#toast");e.textContent=t;e.classList.add("show");setTimeout(()=>e.classList.remove("show"),1400);}
function copy(t){navigator.clipboard.writeText(t).then(()=>toast("Copied"));}

$("#copyPw").onclick=()=>copy($("#pw").value);
$("#regen").onclick=async()=>{await api("/api/password",{method:"POST",body:JSON.stringify({regen:true})});toast("New password");refresh();};
$("#copyUrl").onclick=()=>copy($("#pubUrl").textContent);
$("#autoApprove").onchange=async e=>{await api("/api/settings",{method:"POST",body:JSON.stringify({autoApprove:e.target.checked})});toast("Saved");};
$("#viewOnly").onchange=async e=>{await api("/api/settings",{method:"POST",body:JSON.stringify({viewOnly:e.target.checked})});toast("Saved");};
$("#applyQ").onclick=async()=>{await api("/api/settings",{method:"POST",body:JSON.stringify({
  fps:+$("#fps").value,quality:+$("#quality").value,scale:+$("#scale").value})});toast("Applied");};
async function setMode(m){$("#mLan").classList.toggle("on",m==="lan");$("#mNet").classList.toggle("on",m==="internet");
  $("#lanBox").style.display=m==="lan"?"flex":"none";$("#netBox").style.display=m==="internet"?"flex":"none";
  await api("/api/mode",{method:"POST",body:JSON.stringify({mode:m})});refresh();}
async function removeTrusted(id){await api("/api/trusted",{method:"POST",body:JSON.stringify({action:"remove",id})});refresh();}
async function approve(id){await api("/api/trusted",{method:"POST",body:JSON.stringify({action:"approve",id})});refresh();}
async function deny(id){await api("/api/trusted",{method:"POST",body:JSON.stringify({action:"deny",id})});refresh();}

async function refresh(){let s;try{s=await (await api("/api/state")).json();}catch(e){return;}
 $("#pw").value=s.password;
 $("#mLan").classList.toggle("on",s.mode==="lan");$("#mNet").classList.toggle("on",s.mode==="internet");
 $("#lanBox").style.display=s.mode==="lan"?"flex":"none";$("#netBox").style.display=s.mode==="internet"?"flex":"none";
 $("#lanBox").innerHTML=(s.lanUrls||[]).map(u=>`<div class="url mono">${u}</div>`).join("")||'<div class="muted">No network address found.</div>';
 const st=s.tunnel||{}; const dot=$("#netDot"),txt=$("#netTxt");
 dot.className="dot";
 if(s.mode==="internet"){
   if(st.status==="running"){dot.classList.add("ok");txt.textContent="online";$("#pubUrl").textContent=st.url;$("#netHint").textContent="Anyone with this link + password can connect.";}
   else if(st.status==="starting"){dot.classList.add("warn");txt.textContent="starting...";$("#pubUrl").textContent="starting tunnel...";$("#netHint").textContent="";}
   else if(st.status==="missing"){dot.classList.add("bad");txt.textContent="cloudflared missing";$("#pubUrl").textContent="cloudflared.exe not found";$("#netHint").textContent="Run Get-Cloudflared.ps1 once, then toggle Internet again.";}
   else{dot.classList.add("bad");txt.textContent=st.status||"error";$("#pubUrl").textContent="tunnel not running";$("#netHint").textContent="";}
 } else {dot.classList.add("ok");txt.textContent="LAN";}
 $("#autoApprove").checked=!!s.autoApprove; $("#viewOnly").checked=!!s.settings.viewOnly;
 if(document.activeElement.id!=="fps")$("#fps").value=s.settings.fps;
 if(document.activeElement.id!=="quality")$("#quality").value=s.settings.quality;
 if(document.activeElement.id!=="scale")$("#scale").value=s.settings.scale;
 // pending
 const pend=Object.entries(s.pending||{});
 $("#pendingWrap").innerHTML = pend.length? ('<div class="muted">Waiting for approval:</div>'+pend.map(([id,v])=>
   `<div class="row" style="margin-top:6px"><span style="flex:1">${v.label} <span class="muted">(${v.ip})</span></span>
    <button class="btn ok" onclick="approve('${id}')">Approve</button>
    <button class="btn bad" onclick="deny('${id}')">Deny</button></div>`).join('')) : '';
 // trusted
 const tr=Object.entries(s.trusted||{});
 $("#trustedTbl").style.display=tr.length?"table":"none";$("#trustedEmpty").style.display=tr.length?"none":"block";
 $("#trustedTbl tbody").innerHTML=tr.map(([id,v])=>`<tr><td>${v.label}</td><td class="mono">${v.ip}</td>
   <td class="muted">${v.added}</td><td><button class="btn bad" onclick="removeTrusted('${id}')">Remove</button></td></tr>`).join("");
}
refresh(); setInterval(refresh,2000);
</script></body></html>"""


# ===========================================================================
# HTTP server
# ===========================================================================
def client_label(handler):
    ip = handler.headers.get("X-Forwarded-For") or handler.client_address[0]
    ip = ip.split(",")[0].strip()
    ua = handler.headers.get("User-Agent", "")
    name = "Computer"
    for tag in ("Windows", "Macintosh", "Mac OS", "Linux", "Android", "iPhone", "iPad"):
        if tag in ua:
            name = tag.replace("Mac OS", "Mac").replace("Macintosh", "Mac")
            break
    return name, ip


def make_handler(state, cap, inj, admin_token, tunnel, port):
    settings = state["settings"]
    throttle = {}

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *a):
            pass

        # -- cookies / auth --
        def _cookies(self):
            out = {}
            for part in self.headers.get("Cookie", "").split(";"):
                if "=" in part:
                    k, v = part.strip().split("=", 1)
                    out[k] = v
            return out

        def _authed(self):
            c = self._cookies()
            if verify(state["secret"], c.get("rd_sess", "")):
                return True
            dev = verify(state["secret"], c.get("rd_dev", ""))
            return bool(dev and dev in state["trusted"])

        def _is_admin(self):
            if self.headers.get("X-Admin") == admin_token:
                return True
            q = parse_qs(urlparse(self.path).query)
            return q.get("k", [None])[0] == admin_token

        def _send(self, code, ctype, body, extra=None):
            if isinstance(body, str):
                body = body.encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            if extra:
                for k, v in extra:
                    self.send_header(k, v)
            self.end_headers()
            self.wfile.write(body)

        def _json(self, obj, code=200):
            self._send(code, "application/json", json.dumps(obj))

        # -- GET --
        def do_GET(self):
            p = urlparse(self.path)
            path = p.path
            if path == "/":
                return self._send(200, "text/html; charset=utf-8", VIEWER_HTML)
            if path == "/panel":
                if not self._is_admin():
                    return self._send(403, "text/plain", "forbidden")
                return self._send(200, "text/html; charset=utf-8", PANEL_HTML)
            if path == "/session":
                return self._json({"authed": self._authed(), "viewOnly": settings["viewOnly"]})
            if path == "/api/state":
                if not self._is_admin():
                    return self._json({"error": "forbidden"}, 403)
                return self._json(self._state_snapshot())
            if path == "/stream":
                return self._stream()
            if path == "/favicon.ico":
                return self._send(204, "text/plain", "")
            return self._send(404, "text/plain", "not found")

        # -- POST --
        def do_POST(self):
            p = urlparse(self.path)
            path = p.path
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length) if length else b""

            if path == "/auth":
                return self._auth(body)

            if path.startswith("/api/"):
                if not self._is_admin():
                    return self._json({"error": "forbidden"}, 403)
                return self._api(path, body)

            if not self._authed():
                return self._send(403, "text/plain", "no")

            if path == "/input":
                if not settings["viewOnly"]:
                    try:
                        region = (cap.vx, cap.vy, cap.vw, cap.vh)
                        for ev in json.loads(body or b"[]"):
                            inj.handle(ev, region)
                    except Exception:
                        pass
                return self._send(200, "text/plain", "ok")

            return self._send(404, "text/plain", "not found")

        # -- auth flow: password -> session + device cookies --
        def _auth(self, body):
            ip = (self.headers.get("X-Forwarded-For") or self.client_address[0]).split(",")[0].strip()
            now = time.time()
            tries = [t for t in throttle.get(ip, []) if now - t < 60]
            if len(tries) >= 10:
                return self._send(429, "text/plain", "slow down")
            if not secrets.compare_digest(body.decode("utf-8", "ignore"), state["password"]):
                tries.append(now); throttle[ip] = tries
                return self._send(403, "text/plain", "no")
            throttle[ip] = []
            # device id (reuse existing valid one, else new)
            dev = verify(state["secret"], self._cookies().get("rd_dev", "")) or secrets.token_hex(8)
            label, cip = client_label(self)
            info = {"label": label, "ip": cip, "added": time.strftime("%Y-%m-%d %H:%M")}
            if state["autoApprove"]:
                state["trusted"][dev] = info
                state["pending"].pop(dev, None)
            elif dev not in state["trusted"]:
                state["pending"][dev] = info
            save_state(state)
            sess = sign(state["secret"], secrets.token_hex(8))
            devtok = sign(state["secret"], dev)
            self._send(200, "text/plain", "ok", extra=[
                ("Set-Cookie", "rd_sess=%s; Path=/; HttpOnly; SameSite=Lax" % sess),
                ("Set-Cookie", "rd_dev=%s; Path=/; Max-Age=31536000; HttpOnly; SameSite=Lax" % devtok),
            ])

        # -- admin api --
        def _state_snapshot(self):
            return {
                "password": state["password"],
                "mode": state["mode"],
                "autoApprove": state["autoApprove"],
                "settings": settings,
                "trusted": state["trusted"],
                "pending": state["pending"],
                "lanUrls": ["http://%s:%d/" % (ip, port) for ip in local_ips()] + ["http://localhost:%d/" % port],
                "tunnel": {"status": tunnel.status, "url": tunnel.url},
            }

        def _api(self, path, body):
            try:
                data = json.loads(body or b"{}")
            except Exception:
                data = {}
            if path == "/api/password":
                if data.get("regen"):
                    state["password"] = gen_password()
                elif data.get("password"):
                    state["password"] = str(data["password"])[:64]
                save_state(state)
                return self._json({"ok": True, "password": state["password"]})
            if path == "/api/settings":
                if "viewOnly" in data: settings["viewOnly"] = bool(data["viewOnly"])
                if "autoApprove" in data: state["autoApprove"] = bool(data["autoApprove"])
                if "fps" in data: settings["fps"] = max(1, min(60, int(data["fps"])))
                if "quality" in data: settings["quality"] = max(1, min(100, int(data["quality"])))
                if "scale" in data: settings["scale"] = max(0.1, min(1.0, float(data["scale"])))
                save_state(state)
                return self._json({"ok": True})
            if path == "/api/mode":
                mode = data.get("mode")
                if mode in ("lan", "internet"):
                    state["mode"] = mode
                    save_state(state)
                    if mode == "internet":
                        tunnel.start()
                    else:
                        tunnel.stop()
                return self._json({"ok": True})
            if path == "/api/trusted":
                action, tid = data.get("action"), data.get("id")
                if action == "remove":
                    state["trusted"].pop(tid, None); state["pending"].pop(tid, None)
                elif action == "approve" and tid in state["pending"]:
                    state["trusted"][tid] = state["pending"].pop(tid)
                elif action == "deny":
                    state["pending"].pop(tid, None)
                save_state(state)
                return self._json({"ok": True})
            return self._json({"error": "unknown"}, 404)

        # -- MJPEG --
        def _stream(self):
            if not self._authed():
                return self._send(403, "text/plain", "no")
            self.send_response(200)
            self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=rdframe")
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            last = -1
            try:
                while cap.running:
                    seq, frame = cap.latest()
                    if frame is not None and seq != last:
                        last = seq
                        self.wfile.write(b"\r\n--rdframe\r\n")
                        self.wfile.write(b"Content-Type: image/jpeg\r\n")
                        self.wfile.write(("Content-Length: %d\r\n\r\n" % len(frame)).encode())
                        self.wfile.write(frame)
                    time.sleep(1.0 / (settings["fps"] + 2))
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass

    return Handler


def local_ips():
    ips = set()
    try:
        for info in socket.getaddrinfo(socket.gethostname(), None):
            a = info[4][0]
            if "." in a and not a.startswith("127."):
                ips.add(a)
    except Exception:
        pass
    return sorted(ips)


# ===========================================================================
# Self test (no capture / server / input)
# ===========================================================================
def selftest():
    results = []
    def check(name, cond, detail=""):
        results.append((name, bool(cond), detail))
    bits = ctypes.sizeof(ctypes.c_void_p) * 8
    print("Portable Remote Desktop - self test")
    print("  Python : %s" % sys.version.split()[0])
    print("  Arch   : %d-bit\n" % bits)
    expect = {64: (40, 32, 24), 32: (28, 24, 16)}.get(bits, (None, None, None))
    check("INPUT struct size", ctypes.sizeof(INPUT) == expect[0], "%d (want %s)" % (ctypes.sizeof(INPUT), expect[0]))
    check("MOUSEINPUT struct size", ctypes.sizeof(MOUSEINPUT) == expect[1], "%d" % ctypes.sizeof(MOUSEINPUT))
    check("KEYBDINPUT struct size", ctypes.sizeof(KEYBDINPUT) == expect[2], "%d" % ctypes.sizeof(KEYBDINPUT))
    check("GUID struct size", ctypes.sizeof(GUID) == 16, "%d" % ctypes.sizeof(GUID))
    check("GDI+ startup", bool(_gdip_token.value), "token set")
    cap = Capturer(dict(fps=10, quality=70, scale=1.0, viewOnly=True))
    vx, vy, vw, vh = cap._virtual_screen()
    check("Virtual screen metrics", vw > 0 and vh > 0, "%dx%d @ (%d,%d)" % (vw, vh, vx, vy))
    data = None
    try:
        gdi32.CreateSolidBrush.restype = wintypes.HGDIOBJ
        gdi32.CreateSolidBrush.argtypes = [wintypes.COLORREF]
        user32.FillRect.argtypes = [wintypes.HDC, ctypes.POINTER(wintypes.RECT), wintypes.HGDIOBJ]
        sdc = user32.GetDC(None); mdc = gdi32.CreateCompatibleDC(sdc)
        bmp = gdi32.CreateCompatibleBitmap(sdc, 96, 64); gdi32.SelectObject(mdc, bmp)
        for i, color in enumerate((0x2060E0, 0x40C040, 0xE0A020)):
            r = wintypes.RECT(0, i * 21, 96, (i + 1) * 21)
            br = gdi32.CreateSolidBrush(color); user32.FillRect(mdc, ctypes.byref(r), br); gdi32.DeleteObject(br)
        cap._tmp = os.path.join(tempfile.gettempdir(), "rdhost_selftest_%d.jpg" % os.getpid())
        data = cap._encode(bmp, 80)
        gdi32.DeleteObject(bmp); gdi32.DeleteDC(mdc); user32.ReleaseDC(None, sdc)
        try: os.remove(cap._tmp)
        except OSError: pass
    except Exception as e:
        check("GDI+ JPEG encode", False, repr(e))
    else:
        check("GDI+ JPEG encode", data and data[:3] == b"\xff\xd8\xff", "%d bytes" % (len(data) if data else 0))
    # auth signing round-trip
    sec = secrets.token_hex(32)
    tok = sign(sec, "device123")
    check("Cookie sign/verify", verify(sec, tok) == "device123" and verify(sec, tok + "x") is None, "HMAC ok")
    check("Tunnel URL parse", bool(TUNNEL_RE.search("inf https://happy-cat-42.trycloudflare.com ok")), "regex ok")
    check("Panel/viewer HTML", len(PANEL_HTML) > 500 and len(VIEWER_HTML) > 500, "present")
    print()
    allok = True
    for name, ok, detail in results:
        allok = allok and ok
        print("  [%s] %-26s %s" % ("PASS" if ok else "FAIL", name, detail))
    print("\n  %s\n" % ("ALL CHECKS PASSED - the engine works on this machine."
                        if allok else "SOME CHECKS FAILED - see above."))
    return 0 if allok else 1


# ===========================================================================
# main
# ===========================================================================
def main():
    ap = argparse.ArgumentParser(description="Portable Remote Desktop host (Python, stdlib only)")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--bind", default="0.0.0.0")
    ap.add_argument("--password", default="", help="force a specific password (otherwise saved/random)")
    ap.add_argument("--internet", action="store_true", help="start in Internet (tunnel) mode")
    ap.add_argument("--no-browser", action="store_true", help="do not auto-open the control panel")
    ap.add_argument("--reset", action="store_true", help="wipe saved state (new password/secret)")
    ap.add_argument("--selftest", action="store_true", help="verify the engine and exit")
    args = ap.parse_args()

    if args.selftest:
        sys.exit(selftest())

    if args.reset:
        try: os.remove(STATE_PATH)
        except OSError: pass

    state = load_state()
    if args.password:
        state["password"] = args.password
    if args.internet:
        state["mode"] = "internet"
    save_state(state)

    settings = state["settings"]
    cap = Capturer(settings)
    cap.start()
    time.sleep(0.3)

    admin_token = secrets.token_hex(16)
    tunnel = TunnelManager(args.port)
    handler = make_handler(state, cap, Injector(), admin_token, tunnel, args.port)
    httpd = ThreadingHTTPServer((args.bind, args.port), handler)

    if state["mode"] == "internet":
        tunnel.start()

    panel_url = "http://localhost:%d/panel?k=%s" % (args.port, admin_token)

    print("\n  " + "=" * 58)
    print("   Portable Remote Desktop Host (Python) is running")
    print("  " + "=" * 58 + "\n")
    print("   CONTROL PANEL (this machine, keep private):")
    print("       %s\n" % panel_url)
    print("   Viewers connect at:")
    for ip in local_ips():
        print("       http://%s:%d/" % (ip, args.port))
    print("       http://localhost:%d/\n" % args.port)
    print("   Password : %s" % state["password"])
    print("   Mode     : %s%s" % (state["mode"],
          "  (toggle LAN/Internet in the control panel)" if True else ""))
    print("\n   Press Ctrl+C to stop.\n")

    if not args.no_browser:
        try:
            threading.Timer(0.6, lambda: webbrowser.open(panel_url)).start()
        except Exception:
            pass

    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        cap.running = False
        tunnel.stop()
        httpd.shutdown()
        print("Stopped.")


if __name__ == "__main__":
    main()
