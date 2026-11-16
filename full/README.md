# Remote Desktop — full version (server + viewer)

For a machine where you have full control. Adds the things the portable version
leaves out, at the cost of needing Python installed (and, if you want LAN access
through the firewall, one elevated command).

Features beyond the portable build:

- Fast capture (`mss`) and cross-platform input (`pynput`) — Windows, macOS, Linux
- Token login with signed, HttpOnly session cookie + brute-force throttling
- **Optional TLS** (`--tls`) with an auto-generated self-signed certificate
- **Multi-monitor**: switch displays live from the toolbar
- **Clipboard sync** (pull / push)
- **File transfer**: upload to / download from a shared folder
- Live **fps / quality / monitor / view-only** controls in the viewer

The viewer is still just a browser, so the *connecting* machine installs nothing.

## Install & run (host)

```bash
pip install -r requirements.txt
python server.py --password SECRET
```

It prints the URLs and password:

```
https://192.168.1.42:8766/        (if --tls)
http://192.168.1.42:8766/
Password : SECRET
```

Open that URL in a browser on another machine, enter the password, connect.

### Common options

```bash
python server.py --password SECRET --tls --monitor 1 --fps 20 --quality 65
python server.py --view-only            # stream only, ignore input
python server.py --bind 127.0.0.1       # this machine only (e.g. behind SSH)
python server.py --share D:\transfer    # folder used for file transfer
```

| Flag | Default | Meaning |
|------|---------|---------|
| `--port` | `8766` | Listening port. |
| `--bind` | `0.0.0.0` | Interface to bind. |
| `--password` | random | Access password (printed if omitted). |
| `--fps` | `15` | Target frames/sec. |
| `--quality` | `60` | JPEG quality 1–100. |
| `--scale` | `1.0` | Downscale factor 0.1–1.0. |
| `--monitor` | `0` | `0`=all displays, `1`=first, `2`=second… |
| `--view-only` | off | Disable input injection. |
| `--share` | `./shared` | File-transfer folder. |
| `--tls` | off | Serve HTTPS with a self-signed cert (needs `cryptography`). |

## Firewall (the only step that needs admin)

Binding the port needs no admin, but to accept connections from **other
machines** Windows Firewall needs a rule. From an **elevated** PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File Setup-Firewall.ps1 -Port 8766
```

Remove it later with `-Remove`. You do **not** need this for `localhost` or for
tunneled connections.

## Security

- Prefer `--tls` on any network you do not fully trust; the browser warns once
  about the self-signed cert — accept it (or import it to trust it permanently).
- The session cookie is signed (HMAC-SHA256) and `HttpOnly`; logins are throttled
  to 8 attempts/minute per IP.
- For internet access, still prefer a tunnel/VPN (SSH, Tailscale, WireGuard,
  cloudflared) over exposing the port directly.
- `pynput` cannot inject into windows running at higher integrity than the
  server process (elevated apps, the secure desktop) — a Windows boundary.

## Platform notes

- **Windows**: works out of the box. For the host to control elevated apps, run
  the server elevated (not required for normal use).
- **macOS**: grant the terminal/Python **Screen Recording** and **Accessibility**
  permissions (System Settings → Privacy & Security) or capture/input will be blank/ignored.
- **Linux**: X11 works directly; under Wayland, capture/input support varies by
  compositor.

## Pieces

| File | Role |
|------|------|
| `server.py` | Host: capture, input, HTTP/MJPEG, clipboard, files, TLS. |
| `viewer.html` | Browser viewer (served at `/`). |
| `requirements.txt` | Python dependencies. |
| `Setup-Firewall.ps1` | Admin-only helper to open the port on Windows. |
