# Remote Desktop

**Want a GUI you double-click?** Use [`host-exe/`](host-exe/) — a native Windows
app (`RemoteDesktopHost.exe`, no install, no admin) with a window for the
password, the **LAN ⟷ Internet** toggle, and trusted-computer approvals. It's the
recommended host. The folders below are the script-based / headless equivalents.

All builds are connected from an ordinary **web browser** (so the viewing
machine never installs anything):

| | [`host-exe/`](host-exe/) |
|---|---|
| **What** | native GUI Windows app (.exe) |
| **Install / admin** | none / none |
| **GUI** | real desktop window |
| **Password** | random + regenerate button |
| **Access** | **LAN ⟷ Internet toggle** (Internet via cloudflared tunnel) |
| **Trusted computers** | approve once → auto-reconnect; optional auto-approve |
| **Built with** | the C# compiler already inside Windows (no SDK) |

Script-based equivalents:

| | [`portable/`](portable/) | [`portable-python/`](portable-python/) | [`full/`](full/) |
|---|---|---|---|
| **For** | locked-down PC | locked-down PC (Defender-safe) | a PC you fully control |
| **Language** | PowerShell + .NET | Python (stdlib + ctypes) | Python (mss/Pillow/pynput) |
| **Install** | none (built into Windows) | none (bare/embeddable Python) | `pip install -r requirements.txt` |
| **Admin rights** | none | none | none to run; one elevated cmd to open firewall |
| **Defender/AMSI** | ⚠ may be blocked as a false positive | not AMSI-scanned | not AMSI-scanned |
| **Host OS** | Windows | Windows | Windows / macOS / Linux |
| **Transport** | HTTP (tunnel for internet) | HTTP (tunnel for internet) | HTTP or **HTTPS/TLS** |
| **Streaming** | MJPEG, fps/quality/scale | MJPEG, fps/quality/scale | MJPEG, live fps/quality/**monitor** |
| **Extras** | — | — | multi-monitor, **clipboard**, **file transfer**, login throttling |

Both work the same way: the **host** captures its screen and serves it as an
MJPEG stream plus an input endpoint; the **viewer** is a browser pointed at the
host's URL. The host enters a password that gates viewing and control.

## Which one?

- **You want a double-click GUI app** → `host-exe/`. Native `.exe`, no install,
  no admin; password + LAN/Internet toggle + trusted computers in a window. This
  is the one most people want.
- **Restricted machine, and Windows Defender does not block scripts** →
  `portable/`. Pure PowerShell, nothing to fetch at all. Copy, double-click
  `Start-Host.cmd`, done.
- **Restricted machine where Defender blocks the PowerShell host** →
  `portable-python/`. Same no-install / no-admin story, but it isn't AMSI-scanned.
  Needs a Python next to it; `Get-PortablePython.ps1` fetches a no-install
  embeddable one.
- **Your own workstation / server / something you fully own** → `full/`. Most
  features and optional encryption, needs `pip install`.

Tip: they pair naturally — run the **full** build (relay-capable, firewall open)
on the machine you own, and the **portable** build on the restricted one, and
view either from a browser. For anything crossing the public internet, put it
behind a tunnel or VPN (SSH `-L`, Tailscale, WireGuard, cloudflared, ngrok)
rather than exposing a port directly.

See each folder's `README.md` for full instructions and options.

## Security summary

- Password-gated; `full/` additionally signs a session cookie and throttles logins.
- Portable transport is plain HTTP — **tunnel it** on untrusted networks. The full
  build can serve HTTPS with `--tls`.
- Neither can inject input into windows running at a higher integrity level
  (elevated apps, the secure Ctrl+Alt+Del desktop) — a Windows security boundary,
  not a limitation of the tools.
- Use only on machines you are authorized to access.
