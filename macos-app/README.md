# Remote Desktop Host — native macOS app

The Mac counterpart of [`host-exe/`](../host-exe/): a real macOS window
(`Remote Desktop Host.app`, Swift + SwiftUI) that shares this Mac's screen,
mouse and keyboard. The person connecting *in* uses an ordinary web browser —
the same viewer page, login, Tools drawer (clipboard + files) as the Windows
host. No install, no admin password, no Xcode project.

The window gives you:

- **Permissions** — status of *Screen Recording* and *Accessibility*, with
  **Grant…** buttons that open the right page in System Settings.
- **Access password** — random, with **Copy** and **Regenerate**.
- **Where people connect** — **LAN only ⟷ Internet**. LAN lists your
  `http://<ip>:8765/` addresses; Internet opens a public
  `https://….trycloudflare.com` link through a cloudflared quick tunnel
  (no router / port-forward, no account).
- **Trusted computers** — approve a computer once and it reconnects
  automatically without the password, or tick *Automatically approve new
  computers*. Remove trust any time.
- **Quality & input** — view-only, FPS, JPEG quality, scale (up to 200% for
  Retina-sharp text), which display to share (multi-monitor), and
  **Ctrl → ⌘** mapping so a Windows/Linux viewer's Ctrl+C / Ctrl+V do what
  they expect on the Mac (Mac viewers are detected and left alone).
- **Clipboard & files** — from the viewer's **Tools** drawer; *Shared folder*
  opens the transfer folder in Finder.
- **Activity** log and **Start/Stop**.

How it works: ScreenCaptureKit captures the display (cursor included), Core
Image encodes JPEG frames, a small HTTP server on port 8765 streams them as
MJPEG, and Quartz events (`CGEvent`) inject the remote mouse and keyboard —
all as the current user.

## Requirements

- macOS **13 Ventura** or later, Apple silicon or Intel (universal binary).
- To build: Xcode **or** just the Command Line Tools (`xcode-select --install`).

## Get the app

**Prebuilt:** every push that touches `macos-app/` is built by GitHub Actions
(workflow *macOS app*). Download the `RemoteDesktopHost-macOS` artifact from
the run, unzip it, and move `Remote Desktop Host.app` wherever you like.

**Build it yourself:**

```bash
cd macos-app
./build.sh            # universal; ARCHS=arm64 ./build.sh for one arch only
open "build/Remote Desktop Host.app"
```

### First launch (unsigned app)

The app is ad-hoc signed, not notarized, so Gatekeeper blocks a copy that was
downloaded. Either run once:

```bash
xattr -dr com.apple.quarantine "/path/to/Remote Desktop Host.app"
```

or try to open it, then go to **System Settings › Privacy & Security** and click
**Open Anyway**. A copy you built yourself opens normally.

## Run it

1. Open **Remote Desktop Host**. The server starts and a password is shown.
2. Grant the two permissions when asked (or use the **Grant…** buttons):
   - **Screen Recording** — to send the screen.
   - **Accessibility** — to accept remote mouse/keyboard.
   macOS often applies Screen Recording only after a restart of the app — use
   **Relaunch**.
3. On the other device open one of the shown addresses in a browser, type the
   password, done.

For **Internet** mode install cloudflared (`brew install cloudflared`), or put
the `cloudflared` binary from the
[releases page](https://github.com/cloudflare/cloudflared/releases/latest)
(`cloudflared-darwin-arm64.tgz` / `-amd64.tgz`) next to the app or in
`~/Library/Application Support/RemoteDesktopHost/`, then pick **Internet**.

## Notes & limits

- **Firewall.** If the macOS firewall is on, accept the "allow incoming
  connections" prompt the first time, or LAN viewers can't connect.
  `localhost` and the Internet tunnel always work.
- **Permissions & rebuilds.** Permissions are tied to the app's signature. An
  ad-hoc signed app gets a new signature on every rebuild, so after rebuilding
  you may need to turn the app off and on again in *Screen Recording* /
  *Accessibility* (or remove it with “–” and re-add it).
- **macOS 15+** periodically asks again whether the app may keep recording the
  screen — a system policy for apps that capture the screen.
- **Secure input.** macOS blocks synthetic keystrokes into password fields that
  use Secure Event Input, and the login window / lock screen can't be
  controlled by an app running in your user session.
- **Sleep.** While the app is open it keeps the Mac from idle-sleeping
  (the display may still turn off; remote input wakes it).
- **Transport.** LAN mode is plain HTTP — fine on a trusted network. The
  Internet tunnel is HTTPS end-to-end.
- Use only on machines you're authorized to access.

## Files

| File | Role |
|------|------|
| `Sources/App.swift` | SwiftUI window, view model, permissions. |
| `Sources/Engine.swift` | State, password/trusted-computer auth, HTTP routes. |
| `Sources/Server.swift` | Small HTTP/1.1 server on BSD sockets. |
| `Sources/Capture.swift` | ScreenCaptureKit capture + JPEG encoding. |
| `Sources/Input.swift` | Mouse/keyboard injection with `CGEvent`. |
| `Sources/Tunnel.swift` | cloudflared quick tunnel (Internet mode). |
| `Resources/viewer.html` | The browser viewer (bundled into the app). |
| `Resources/Info.plist` | App bundle metadata. |
| `build.sh` | Compile with `swiftc`, assemble and ad-hoc sign the `.app`. |

Runtime data lives in `~/Library/Application Support/RemoteDesktopHost/`:
`rd_state.json` (password, trusted computers, settings — readable only by you)
and `shared/` (the file-transfer folder).
