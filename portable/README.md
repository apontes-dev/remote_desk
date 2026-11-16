# Portable Remote Desktop (no install, no admin)

A single PowerShell script turns any Windows PC into a remote-desktop **host**
that you can view and control from a **web browser** on another machine. Nothing
is installed, and no administrator rights are required.

It works because everything it uses is already part of Windows:

| Need | Uses | Admin? |
|------|------|--------|
| Screen capture | .NET `Graphics.CopyFromScreen` | No |
| Mouse / keyboard input | `user32.dll` (`SetCursorPos`, `mouse_event`, `keybd_event`, `SendInput`) | No |
| Network server | .NET `TcpListener` on a high port | No |
| Viewer | any web browser (MJPEG + fetch) | No |

## Quick start

**On the machine you want to control (the host):**

1. Copy the `portable` folder onto it (USB stick, download, network share — anything).
2. Double-click **`Start-Host.cmd`**.
3. A console window prints the URL(s) and a password, e.g.:

   ```
   http://192.168.1.42:8765/
   Password : k7Pm9qRt2x
   ```

**On the machine you want to view from (any OS):**

1. Open a browser and go to that URL.
2. Enter the password, click **Connect**.
3. You now see and control the remote desktop. Done.

To stop: press `Ctrl+C` in the host console (or just close the window).

## Options

Edit the variables at the top of `Start-Host.cmd`, or run the script directly:

```bat
powershell -NoProfile -ExecutionPolicy Bypass -File host.ps1 -Password hunter2 -Port 9000 -Fps 15 -Quality 60 -Scale 0.8
```

| Parameter | Default | Meaning |
|-----------|---------|---------|
| `-Port` | `8765` | Listening TCP port (high ports need no admin). |
| `-Password` | random | Access password. Auto-generated and printed if empty. |
| `-Fps` | `12` | Target frames per second. |
| `-Quality` | `55` | JPEG quality 1–100 (lower = faster/smaller). |
| `-Scale` | `1.0` | Downscale factor 0.1–1.0 (e.g. `0.75` for slower links). |
| `-ViewOnly` | off | Stream only; ignore all remote input. |
| `-Bind` | `0.0.0.0` | Bind address. Use `127.0.0.1` for this-machine-only. |

## How to reach it

- **Same LAN** — use the printed `http://<lan-ip>:<port>/`. This is the normal case.
- **Same machine** — `http://localhost:<port>/`.
- **Over the internet / different network** — do **not** expose this port directly.
  Tunnel it instead (all outbound, so no admin and no firewall rule needed):
  - SSH:  `ssh -L 8765:localhost:8765 user@host` then browse `http://localhost:8765/`
  - or a tool like `cloudflared tunnel`, `ngrok http 8765`, Tailscale, etc.

## About the "no admin" requirement

Everything above runs as the logged-in user. Two honest caveats:

1. **Windows Firewall (inbound).** Binding the port needs no admin, but if the
   firewall has no rule for it, connections *from other machines* may be dropped.
   - `localhost` and tunneled (SSH/ngrok/Tailscale) connections always work,
     because they are outbound/loopback and the firewall does not block them.
   - On many private/work networks inbound high ports are already allowed.
   - If you *do* control the firewall, the full version (`../full`) ships a
     one-line rule-adding script.
2. **Elevated windows (UAC / UIPI).** Input cannot be injected into windows
   running at a *higher* integrity level than the host script (e.g. an elevated
   admin app, or the secure Ctrl+Alt+Del screen). This is a Windows security
   boundary, not a bug. Everything at your own user level works normally. The
   toolbar's "Ctrl+Alt+End" opens the standard security options as a workaround.

## Antivirus / Windows Defender may block it

Because the script both **captures the screen** and **injects mouse/keyboard
input**, it matches the generic behaviour pattern that antivirus engines use to
spot remote-access malware. Windows Defender's AMSI may therefore refuse to run
it with `ScriptContainedMaliciousContent`, even though the code is benign and
open for you to read.

This was observed on a stock Windows 11 machine. Legitimate ways to deal with it
(no obfuscation — that would only make a clean tool look worse):

- **Have IT / an admin allow it.** Add a Defender exclusion for the folder, or
  code-sign `host.ps1` with a trusted certificate. (Both need admin — ask whoever
  administers the machine, since the point of this tool is you don't have that.)
- **Use the full version instead** (`../full`). It's Python, not PowerShell, so
  it doesn't go through AMSI script scanning. It still needs Python available on
  the host, but a portable/embeddable Python build needs no install or admin.
- **Behavioural detection** may still flag either tool at runtime on a strictly
  managed machine; there is no honest way around a policy that forbids remote
  control, and you should only run this where you're authorised to.

If Defender does *not* block it on your target machine (policies vary), the
portable host runs exactly as described above.

## Security notes

- Traffic is plain HTTP. On an untrusted network, **always tunnel** (see above)
  so it is encrypted end to end.
- The password gates both viewing and control; pick a strong one for anything
  beyond your own LAN.
- Use `-ViewOnly` to let people watch without touching the machine.

## Troubleshooting

- *"running scripts is disabled on this system"* — use `Start-Host.cmd` (it
  passes `-ExecutionPolicy Bypass` per-process, no admin) rather than
  double-clicking the `.ps1`.
- *Browser shows a broken image / keeps reconnecting* — wrong password, or the
  port is blocked. Try `http://localhost:<port>/` on the host itself first.
- *Laggy* — lower `-Fps`, lower `-Quality`, or set `-Scale 0.6`.
- *Keyboard shortcuts hit your local browser instead* — click the remote image
  first, and use **Fullscreen** so the browser passes more keys through.
