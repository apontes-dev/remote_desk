# Remote Desktop Host — native Windows app (.exe)

A real desktop **GUI application** (not a web page at an address): one
self-contained `RemoteDesktopHost.exe` with no install and no admin rights.
The person connecting *in* still uses a browser (that's the remote-desktop
part), but what you run on the host is a proper Windows window.

![what it does] The window gives you:

- **Access password** — random, with **Regenerate** and **Copy**.
- **Where people connect** — a **LAN only ⟷ Internet** toggle. LAN shows your
  `http://<ip>:8765/` addresses; Internet opens a public
  `https://….trycloudflare.com` link (no router/port-forward, no admin).
- **Trusted computers** — approve a computer once and it reconnects
  **automatically** without the password. Or tick *Automatically approve new
  computers* to grant access to anyone who enters the password the first time.
  Pending computers show up with **Approve / Deny**; trusted ones with **Remove**.
- **Quality & input** — view-only switch, FPS, JPEG quality, scale.
- **Clipboard & files** — in the viewer's **Tools** drawer: pull/push the host
  clipboard, and upload/download files through a **shared folder** (the
  *Shared folder* button in the app opens it).
- **Activity** log and **Start/Stop**.

Everything the app does runs as the current user: screen capture
(`System.Drawing`), input injection (`user32 SendInput`), and an HTTP/MJPEG
server on a high port (`TcpListener`) — **no elevation, no UAC**.

## Run it

1. Copy this `host-exe` folder (or just `RemoteDesktopHost.exe`) to the host PC.
2. Double-click **`RemoteDesktopHost.exe`**. The window opens and the server
   starts automatically; a random password is shown.
3. On the viewing device, open the address from the window in a browser, type
   the password, and you're in.

To allow Internet access, put **`cloudflared.exe`** next to the exe (the
*Get cloudflared* button tells you where to download it — a single file, no
install, no admin), then pick **Internet**.

## Rebuild from source (optional)

The exe is already built. To rebuild after editing `RemoteDesktopHost.cs`, just
run **`build.cmd`**. It uses the C# compiler that ships inside Windows
(`%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe`) — no Visual Studio,
no SDK, no admin. Nothing else is required.

## Notes & limits

- **Antivirus.** A normal compiled `.exe` is not AMSI-script-scanned the way the
  PowerShell host was, so it runs where that one was blocked. Strict endpoint
  protection could still flag any remote-control tool; use it only where you're
  authorised.
- **Firewall (LAN).** Binding the port needs no admin, but to accept connections
  from other machines on the LAN, Windows Firewall may need to allow it the
  first time. `localhost` and the Internet tunnel always work (outbound).
- **Elevated windows.** Input can't be injected into apps running at a higher
  integrity level (an elevated/admin window, or the secure Ctrl+Alt+Del screen) —
  a Windows security boundary. The *Ctrl+Alt+End* button in the viewer is the
  usual workaround.
- **Transport.** LAN mode is plain HTTP — fine on a trusted network. The Internet
  tunnel (cloudflared) is HTTPS end-to-end.

## Files

| File | Role |
|------|------|
| `RemoteDesktopHost.exe` | The app (prebuilt). |
| `RemoteDesktopHost.cs` | Source (GUI + capture + input + server). |
| `build.cmd` | Rebuild with the in-box C# compiler. |
| `viewer.html` | The browser viewer page (also embedded in the exe). |
| `rd_state.json` | Created at runtime: password, trusted computers, settings. |
| `shared/` | Created at runtime: the file-transfer folder. |
| `cloudflared.exe` | *You add this* for Internet mode. |
