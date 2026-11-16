# Portable Remote Desktop — Python edition (no install, no admin, no AMSI block)

Same idea as [`../portable`](../portable) (a Windows host you view/control from a
browser), but written in **Python instead of PowerShell**. Two reasons that
matters:

1. **It is not scanned by AMSI.** The PowerShell host gets flagged by Windows
   Defender as a false positive (`ScriptContainedMaliciousContent`) because
   screen-capture + input-injection looks like a remote-access tool to the
   script heuristic. Python code does not go through AMSI, so this one runs.
2. **It needs nothing installed.** It uses **only the Python standard library**
   plus `ctypes` calls into DLLs that already ship with Windows (`gdi32`,
   `gdiplus`, `user32`). No pip, no packages, no wheels to match to a Python
   version. It runs unmodified on the official **embeddable** Python — a zip you
   just unpack, which requires no installation and no admin.

## Quick start

**On the machine you want to control (the host):**

1. Copy this `portable-python` folder onto it.
2. Get a Python next to the script (pick one):
   - **No Python yet?** Run once (no admin, outbound download only):
     ```
     powershell -ExecutionPolicy Bypass -File Get-PortablePython.ps1
     ```
     This drops the official embeddable Python into `.\python\`.
   - **Already have Python** (any 3.8+, or the Store build) → skip this step.
3. Double-click **`Start-Host.cmd`**.
4. It prints the URL(s) and a password:
   ```
   http://192.168.1.42:8765/
   Password : k7Pm9qRt2x
   ```

**On the viewing machine (any OS):** open that URL in a browser, enter the
password, Connect. Nothing to install there either.

Stop the host with `Ctrl+C` in its console.

## Options

Edit the variables at the top of `Start-Host.cmd`, or run directly:

```
python rdhost.py --password hunter2 --port 9000 --fps 15 --quality 60 --scale 0.8
python rdhost.py --view-only
```

| Flag | Default | Meaning |
|------|---------|---------|
| `--port` | `8765` | Listening TCP port (high ports need no admin). |
| `--password` | random | Access password (printed if omitted). |
| `--fps` | `12` | Target frames per second. |
| `--quality` | `55` | JPEG quality 1–100. |
| `--scale` | `1.0` | Downscale factor 0.1–1.0 for slow links. |
| `--view-only` | off | Stream only; ignore remote input. |
| `--bind` | `0.0.0.0` | Bind address (`127.0.0.1` = this machine only). |
| `--selftest` | — | Verify the engine and exit (see below). |

## Verify it works first (`--selftest`)

Before exposing anything, confirm the capture/encode/input engine runs on the
target machine. This opens **no port**, captures **no screen**, and injects
**no input** — it just checks the ctypes plumbing and encodes a synthetic test
image:

```
python rdhost.py --selftest
```

A healthy machine prints all `[PASS]` and exits 0:

```
  [PASS] INPUT struct size          40 (want 40)
  [PASS] GDI+ JPEG encode           1227 bytes, valid JPEG
  [PASS] Virtual screen metrics     2560x1860 @ (0,0)
  ...
  ALL CHECKS PASSED - the engine works on this machine.
```

## How it works

| Need | How | Admin? |
|------|-----|--------|
| Screen capture | `gdi32` `BitBlt`/`StretchBlt` over the virtual desktop | No |
| JPEG encoding | `gdiplus` (`GdipSaveImageToFile`) | No |
| Mouse / keyboard | `user32` `SendInput` (abs mouse, Unicode typing, VK keys) | No |
| Server | stdlib `http.server`, MJPEG `multipart/x-mixed-replace` | No |
| Viewer | any browser | No |

`Get-PortablePython.ps1` is a convenience only — any existing Python 3 works, and
the embeddable build it downloads is not "installed" (no registry/PATH changes).

## Reaching it over the internet

Don't expose the port directly. Tunnel it (all outbound → no admin, no firewall
rule): `ssh -L 8765:localhost:8765 user@host`, or ngrok / cloudflared / Tailscale,
then browse `http://localhost:8765/`.

## Same two Windows caveats as every build here

- **Firewall (inbound).** Binding needs no admin, but a strict firewall may drop
  connections from *other* machines with no rule. `localhost` and tunneled
  connections always work.
- **Elevated windows (UIPI).** Input cannot be injected into windows running at a
  higher integrity level (elevated apps, the secure Ctrl+Alt+Del desktop). This
  is a Windows security boundary. "Ctrl+Alt+End" in the toolbar is the usual
  workaround for the security screen.

Use only on machines you're authorised to access. Traffic is plain HTTP — tunnel
it on untrusted networks.
