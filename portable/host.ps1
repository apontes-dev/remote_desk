<#
.SYNOPSIS
    Portable Remote Desktop Host - zero install, no administrator rights required.

.DESCRIPTION
    Captures the current interactive desktop session and serves it to any web
    browser as an MJPEG stream, while receiving mouse / keyboard input back.

    Everything it relies on (PowerShell, .NET Framework, System.Drawing,
    System.Windows.Forms, user32.dll) ships with Windows, so there is nothing to
    install. Screen capture (Graphics.CopyFromScreen) and input injection
    (user32 SendInput / keybd_event / SetCursorPos) all run at the current
    user's privilege level - no elevation, no UAC prompt.

    The viewer side is just a browser pointed at http://<host-ip>:<port>/ , so
    the remote machine needs no software either.

.PARAMETER Port
    TCP port to listen on. Default 8765. High ports do not require admin to bind.

.PARAMETER Password
    Shared secret required to view / control. Strongly recommended. If omitted a
    random one is generated and printed at startup.

.PARAMETER Fps
    Target capture frames per second. Default 12.

.PARAMETER Quality
    JPEG quality 1-100. Lower = smaller / faster. Default 55.

.PARAMETER Scale
    Downscale factor for the stream, 0.1-1.0. 1.0 = native resolution.

.PARAMETER ViewOnly
    Disable all input injection - stream the screen but ignore mouse/keyboard.

.PARAMETER Bind
    Address to bind. Default 0.0.0.0 (all interfaces). Use 127.0.0.1 to restrict
    to this machine only (e.g. when tunneling over SSH).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File host.ps1 -Password hunter2
#>

[CmdletBinding()]
param(
    [int]$Port = 8765,
    [string]$Password = "",
    [ValidateRange(1, 60)][int]$Fps = 12,
    [ValidateRange(1, 100)][int]$Quality = 55,
    [ValidateRange(0.1, 1.0)][double]$Scale = 1.0,
    [switch]$ViewOnly,
    [string]$Bind = "0.0.0.0"
)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

# ----------------------------------------------------------------------------
# Native input injection (user32). Runs as the current user - no admin needed.
# keybd_event / mouse_event / SetCursorPos are used because they are simple and
# require no struct marshalling; SendInput with KEYEVENTF_UNICODE is used for
# typing arbitrary characters without a per-key virtual-key mapping.
# ----------------------------------------------------------------------------
if (-not ("RdInput" -as [type])) {
Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class RdInput {
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint dx, uint dy, uint data, IntPtr extra);
    [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, IntPtr extra);
    [DllImport("user32.dll")] public static extern uint MapVirtualKey(uint uCode, uint uMapType);

    [StructLayout(LayoutKind.Sequential)]
    struct INPUT { public uint type; public KEYBDINPUT ki; public int pad0; public int pad1; }
    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr extra; }
    [DllImport("user32.dll")] static extern uint SendInput(uint n, INPUT[] inputs, int size);

    const uint MOUSEEVENTF_MOVE = 0x0001, LEFTDOWN = 0x0002, LEFTUP = 0x0004,
               RIGHTDOWN = 0x0008, RIGHTUP = 0x0010, MIDDLEDOWN = 0x0020,
               MIDDLEUP = 0x0040, WHEEL = 0x0800, HWHEEL = 0x1000;
    const uint KEYEVENTF_KEYUP = 0x0002, KEYEVENTF_UNICODE = 0x0004, KEYEVENTF_SCANCODE = 0x0008;

    public static void Move(int x, int y) { SetCursorPos(x, y); }

    public static void Button(int button, bool down) {
        uint f = 0;
        if (button == 0) f = down ? LEFTDOWN : LEFTUP;
        else if (button == 2) f = down ? RIGHTDOWN : RIGHTUP;
        else if (button == 1) f = down ? MIDDLEDOWN : MIDDLEUP;
        if (f != 0) mouse_event(f, 0, 0, 0, IntPtr.Zero);
    }

    public static void Wheel(int delta, bool horizontal) {
        mouse_event(horizontal ? HWHEEL : WHEEL, 0, 0, (uint)delta, IntPtr.Zero);
    }

    // Virtual-key press (for Enter, Backspace, arrows, Ctrl/Alt/Shift, F-keys...).
    public static void Key(byte vk, bool down) {
        uint scan = MapVirtualKey(vk, 0);
        uint f = 0;
        if (!down) f |= KEYEVENTF_KEYUP;
        // extended keys (arrows, nav cluster, right ctrl/alt) want the extended flag
        keybd_event(vk, (byte)scan, f, IntPtr.Zero);
    }

    // Type a Unicode character directly - no VK mapping required.
    public static void TypeChar(char c) {
        INPUT[] inp = new INPUT[2];
        inp[0].type = 1; inp[0].ki.wScan = c; inp[0].ki.dwFlags = KEYEVENTF_UNICODE;
        inp[1].type = 1; inp[1].ki.wScan = c; inp[1].ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
        SendInput(2, inp, Marshal.SizeOf(typeof(INPUT)));
    }
}
'@
}

# ----------------------------------------------------------------------------
# Shared state between the capture thread and the connection worker threads.
# ----------------------------------------------------------------------------
if (-not $Password) {
    $Password = -join ((1..10) | ForEach-Object { '23456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz'[(Get-Random -Max 54)] })
}

$shared = [hashtable]::Synchronized(@{})
$shared.Frame     = $null          # latest JPEG bytes
$shared.Seq       = 0              # frame counter
$shared.Running   = $true
$shared.Password  = $Password
$shared.ViewOnly  = [bool]$ViewOnly
$shared.Quality   = $Quality
$shared.Scale     = $Scale
$shared.Fps       = $Fps
$shared.ScreenX   = [System.Windows.Forms.SystemInformation]::VirtualScreen.X
$shared.ScreenY   = [System.Windows.Forms.SystemInformation]::VirtualScreen.Y
$shared.ScreenW   = [System.Windows.Forms.SystemInformation]::VirtualScreen.Width
$shared.ScreenH   = [System.Windows.Forms.SystemInformation]::VirtualScreen.Height

# ----------------------------------------------------------------------------
# Capture thread: grabs the virtual desktop, draws a cursor marker, encodes JPEG.
# ----------------------------------------------------------------------------
$captureScript = {
    param($shared)
    Add-Type -AssemblyName System.Drawing
    Add-Type -AssemblyName System.Windows.Forms

    $jpegCodec = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() |
                 Where-Object { $_.FormatID -eq [System.Drawing.Imaging.ImageFormat]::Jpeg.Guid }
    $encParams = New-Object System.Drawing.Imaging.EncoderParameters 1

    $bmp = $null; $g = $null; $lastW = 0; $lastH = 0

    while ($shared.Running) {
        $frameStart = [DateTime]::UtcNow
        try {
            $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
            $shared.ScreenX = $vs.X; $shared.ScreenY = $vs.Y
            $shared.ScreenW = $vs.Width; $shared.ScreenH = $vs.Height

            if (-not $bmp -or $lastW -ne $vs.Width -or $lastH -ne $vs.Height) {
                if ($g) { $g.Dispose() }; if ($bmp) { $bmp.Dispose() }
                $bmp = New-Object System.Drawing.Bitmap $vs.Width, $vs.Height
                $g = [System.Drawing.Graphics]::FromImage($bmp)
                $lastW = $vs.Width; $lastH = $vs.Height
            }

            $g.CopyFromScreen($vs.X, $vs.Y, 0, 0, $bmp.Size)

            # draw a pointer marker (CopyFromScreen does not capture the cursor)
            try {
                $cp = [System.Windows.Forms.Cursor]::Position
                $cx = $cp.X - $vs.X; $cy = $cp.Y - $vs.Y
                $g.FillPolygon([System.Drawing.Brushes]::White, @(
                    (New-Object System.Drawing.Point($cx, $cy)),
                    (New-Object System.Drawing.Point($cx, ($cy + 16))),
                    (New-Object System.Drawing.Point(($cx + 4), ($cy + 12))),
                    (New-Object System.Drawing.Point(($cx + 7), ($cy + 18))),
                    (New-Object System.Drawing.Point(($cx + 9), ($cy + 17))),
                    (New-Object System.Drawing.Point(($cx + 6), ($cy + 11))),
                    (New-Object System.Drawing.Point(($cx + 11), ($cy + 11)))
                ))
                $g.DrawPolygon(([System.Drawing.Pens]::Black), @(
                    (New-Object System.Drawing.Point($cx, $cy)),
                    (New-Object System.Drawing.Point($cx, ($cy + 16))),
                    (New-Object System.Drawing.Point(($cx + 4), ($cy + 12))),
                    (New-Object System.Drawing.Point(($cx + 7), ($cy + 18))),
                    (New-Object System.Drawing.Point(($cx + 9), ($cy + 17))),
                    (New-Object System.Drawing.Point(($cx + 6), ($cy + 11))),
                    (New-Object System.Drawing.Point(($cx + 11), ($cy + 11)))
                ))
            } catch {}

            # optional downscale
            $outBmp = $bmp; $scaled = $null
            if ($shared.Scale -lt 1.0) {
                $sw = [int]($vs.Width * $shared.Scale); $sh = [int]($vs.Height * $shared.Scale)
                if ($sw -lt 1) { $sw = 1 }; if ($sh -lt 1) { $sh = 1 }
                $scaled = New-Object System.Drawing.Bitmap $sw, $sh
                $sg = [System.Drawing.Graphics]::FromImage($scaled)
                $sg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::Bilinear
                $sg.DrawImage($bmp, 0, 0, $sw, $sh)
                $sg.Dispose()
                $outBmp = $scaled
            }

            $encParams.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter(
                [System.Drawing.Imaging.Encoder]::Quality, [long]$shared.Quality)
            $ms = New-Object System.IO.MemoryStream
            $outBmp.Save($ms, $jpegCodec, $encParams)
            $shared.Frame = $ms.ToArray()
            $shared.Seq++
            $ms.Dispose()
            if ($scaled) { $scaled.Dispose() }
        } catch {
            Start-Sleep -Milliseconds 200
        }

        $targetMs = [int](1000 / $shared.Fps)
        $elapsed = ([DateTime]::UtcNow - $frameStart).TotalMilliseconds
        $sleep = $targetMs - $elapsed
        if ($sleep -gt 0) { Start-Sleep -Milliseconds ([int]$sleep) }
    }
    if ($g) { $g.Dispose() }; if ($bmp) { $bmp.Dispose() }
}

# ----------------------------------------------------------------------------
# Embedded browser viewer (served at GET /).
# ----------------------------------------------------------------------------
$viewerHtml = @'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Remote Desktop</title>
<style>
  :root { --bg:#0b0d10; --fg:#e8eaed; --accent:#3b82f6; --bar:#15181d; }
  * { box-sizing: border-box; }
  html,body { margin:0; height:100%; background:var(--bg); color:var(--fg);
    font-family: system-ui, Segoe UI, sans-serif; overflow:hidden; }
  #login { display:flex; align-items:center; justify-content:center; height:100%; }
  #login .card { background:var(--bar); padding:28px 32px; border-radius:14px;
    box-shadow:0 12px 40px rgba(0,0,0,.5); width:320px; }
  #login h1 { font-size:18px; margin:0 0 4px; }
  #login p { font-size:13px; color:#9aa0a6; margin:0 0 18px; }
  input { width:100%; padding:10px 12px; border-radius:8px; border:1px solid #2a2f37;
    background:#0b0d10; color:var(--fg); font-size:14px; margin-bottom:12px; }
  button { background:var(--accent); color:#fff; border:0; padding:10px 14px;
    border-radius:8px; font-size:14px; cursor:pointer; }
  button:disabled { opacity:.5; cursor:default; }
  #app { display:none; flex-direction:column; height:100%; }
  #bar { display:flex; align-items:center; gap:10px; background:var(--bar);
    padding:6px 10px; font-size:12px; flex:0 0 auto; }
  #bar .dot { width:9px; height:9px; border-radius:50%; background:#f59e0b; }
  #bar .dot.ok { background:#22c55e; }
  #bar .sp { flex:1; }
  #bar label { color:#9aa0a6; display:flex; align-items:center; gap:4px; }
  #bar .btn { background:#2a2f37; padding:5px 9px; border-radius:6px; }
  #stage { flex:1; overflow:auto; display:flex; align-items:center;
    justify-content:center; background:#000; }
  #screen { max-width:100%; max-height:100%; display:block; cursor:none; }
  .err { color:#f87171; font-size:12px; min-height:16px; }
</style>
</head>
<body>
  <div id="login">
    <div class="card">
      <h1>Remote Desktop</h1>
      <p>Enter the access password shown on the host.</p>
      <input id="pw" type="password" placeholder="Password" autocomplete="off">
      <div class="err" id="loginErr"></div>
      <button id="connectBtn">Connect</button>
    </div>
  </div>

  <div id="app">
    <div id="bar">
      <span class="dot" id="dot"></span>
      <span id="status">connecting...</span>
      <span class="sp"></span>
      <label>View only <input type="checkbox" id="viewOnly"></label>
      <span class="btn" id="fsBtn">Fullscreen</span>
      <span class="btn" id="cadBtn" title="Sends Ctrl+Alt+End (Ctrl+Alt+Del cannot be injected without system rights)">Ctrl+Alt+End</span>
    </div>
    <div id="stage">
      <img id="screen" draggable="false">
    </div>
  </div>

<script>
const $ = s => document.querySelector(s);
let token = "";

$("#connectBtn").onclick = () => start($("#pw").value.trim());
$("#pw").addEventListener("keydown", e => { if (e.key === "Enter") $("#connectBtn").click(); });

async function start(pw) {
  if (!pw) return;
  $("#loginErr").textContent = "";
  $("#connectBtn").disabled = true;
  try {
    const r = await fetch("/auth", { method:"POST", body: pw });
    if (!r.ok) throw new Error("Wrong password");
    token = pw;
    $("#login").style.display = "none";
    $("#app").style.display = "flex";
    beginStream();
    wireInput();
  } catch (e) {
    $("#loginErr").textContent = e.message || "Connection failed";
    $("#connectBtn").disabled = false;
  }
}

function beginStream() {
  const img = $("#screen");
  img.onload = () => { $("#dot").classList.add("ok"); $("#status").textContent = "connected"; };
  img.onerror = () => {
    $("#dot").classList.remove("ok"); $("#status").textContent = "reconnecting...";
    setTimeout(() => { img.src = "/stream?token=" + encodeURIComponent(token) + "&_=" + Date.now(); }, 1000);
  };
  img.src = "/stream?token=" + encodeURIComponent(token);
}

// ---- input ----
let sending = false, queue = [];
async function flush() {
  if (sending || !queue.length) return;
  sending = true;
  const batch = queue; queue = [];
  try {
    await fetch("/input?token=" + encodeURIComponent(token), {
      method: "POST", body: JSON.stringify(batch)
    });
  } catch (e) {}
  sending = false;
  if (queue.length) flush();
}
function send(ev) {
  if ($("#viewOnly").checked) return;
  queue.push(ev);
  if (queue.length > 40) queue.shift();
  flush();
}

function imgCoords(e) {
  const img = $("#screen");
  const r = img.getBoundingClientRect();
  const x = (e.clientX - r.left) / r.width;
  const y = (e.clientY - r.top) / r.height;
  return { x: Math.max(0, Math.min(1, x)), y: Math.max(0, Math.min(1, y)) };
}

function wireInput() {
  const img = $("#screen");
  let lastMove = 0;
  img.addEventListener("mousemove", e => {
    const now = performance.now();
    if (now - lastMove < 25) return;   // throttle ~40/s
    lastMove = now;
    const c = imgCoords(e);
    send({ t:"move", x:c.x, y:c.y });
  });
  img.addEventListener("mousedown", e => {
    e.preventDefault();
    const c = imgCoords(e);
    send({ t:"down", x:c.x, y:c.y, b:e.button });
  });
  window.addEventListener("mouseup", e => {
    const c = imgCoords(e);
    send({ t:"up", x:c.x, y:c.y, b:e.button });
  });
  img.addEventListener("contextmenu", e => e.preventDefault());
  img.addEventListener("wheel", e => {
    e.preventDefault();
    send({ t:"wheel", dy: -e.deltaY, dx: -e.deltaX });
  }, { passive:false });

  // keyboard
  window.addEventListener("keydown", e => {
    if ($("#app").style.display === "none") return;
    e.preventDefault();
    if (e.key.length === 1 && !e.ctrlKey && !e.altKey && !e.metaKey) {
      send({ t:"char", c: e.key });
    } else {
      send({ t:"key", k: e.key, code: e.code, down:true,
             ctrl:e.ctrlKey, alt:e.altKey, shift:e.shiftKey });
    }
  });
  window.addEventListener("keyup", e => {
    if ($("#app").style.display === "none") return;
    e.preventDefault();
    if (!(e.key.length === 1 && !e.ctrlKey && !e.altKey && !e.metaKey)) {
      send({ t:"key", k:e.key, code:e.code, down:false,
             ctrl:e.ctrlKey, alt:e.altKey, shift:e.shiftKey });
    }
  });

  $("#fsBtn").onclick = () => {
    if (!document.fullscreenElement) document.documentElement.requestFullscreen();
    else document.exitFullscreen();
  };
  $("#cadBtn").onclick = () => {
    send({ t:"key", k:"Control", code:"ControlLeft", down:true });
    send({ t:"key", k:"Alt", code:"AltLeft", down:true });
    send({ t:"key", k:"End", code:"End", down:true });
    send({ t:"key", k:"End", code:"End", down:false });
    send({ t:"key", k:"Alt", code:"AltLeft", down:false });
    send({ t:"key", k:"Control", code:"ControlLeft", down:false });
  };
}
</script>
</body>
</html>
'@
$shared.ViewerHtml = $viewerHtml

# ----------------------------------------------------------------------------
# Connection worker: parses minimal HTTP/1.1 (with keep-alive) and routes.
# ----------------------------------------------------------------------------
$workerScript = {
    param($client, $shared)

    # JS event.key / event.code -> Windows virtual-key code
    $vk = @{
        "Enter"=0x0D; "Tab"=0x09; "Backspace"=0x08; "Escape"=0x1B; "Delete"=0x2E;
        "Insert"=0x2D; "Home"=0x24; "End"=0x23; "PageUp"=0x21; "PageDown"=0x22;
        "ArrowLeft"=0x25; "ArrowUp"=0x26; "ArrowRight"=0x27; "ArrowDown"=0x28;
        "Shift"=0x10; "Control"=0x11; "Alt"=0x12; "Meta"=0x5B; "CapsLock"=0x14;
        " "=0x20; "F1"=0x70; "F2"=0x71; "F3"=0x72; "F4"=0x73; "F5"=0x74; "F6"=0x75;
        "F7"=0x76; "F8"=0x77; "F9"=0x78; "F10"=0x79; "F11"=0x7A; "F12"=0x7B;
        "PrintScreen"=0x2C
    }
    $vkCode = @{
        "ControlLeft"=0x11; "ControlRight"=0x11; "AltLeft"=0x12; "AltRight"=0x12;
        "ShiftLeft"=0x10; "ShiftRight"=0x10; "MetaLeft"=0x5B; "MetaRight"=0x5C
    }

    function Resolve-Vk($ev) {
        if ($ev.code -and $vkCode.ContainsKey([string]$ev.code)) { return [byte]$vkCode[[string]$ev.code] }
        if ($ev.k -and $vk.ContainsKey([string]$ev.k)) { return [byte]$vk[[string]$ev.k] }
        if ($ev.k -and ([string]$ev.k).Length -eq 1) {
            $ch = ([string]$ev.k).ToUpper()[0]
            if ($ch -match '[A-Z0-9]') { return [byte][int]$ch }
        }
        return 0
    }

    try {
        $client.NoDelay = $true
        $stream = $client.GetStream()
        $enc = [System.Text.Encoding]::UTF8

        while ($shared.Running -and $client.Connected) {
            # --- read request line + headers ---
            $headerBytes = New-Object System.Collections.Generic.List[byte]
            $buf = New-Object byte[] 1
            $matched = 0  # count of trailing CR LF CR LF
            $pattern = @(13, 10, 13, 10)
            $gotAny = $false
            while ($true) {
                $n = $stream.Read($buf, 0, 1)
                if ($n -le 0) { break }
                $gotAny = $true
                $headerBytes.Add($buf[0])
                if ($buf[0] -eq $pattern[$matched]) { $matched++ } else { $matched = if ($buf[0] -eq 13) {1} else {0} }
                if ($matched -eq 4) { break }
                if ($headerBytes.Count -gt 65536) { break }
            }
            if (-not $gotAny -or $headerBytes.Count -eq 0) { break }

            $headerText = $enc.GetString($headerBytes.ToArray())
            $lines = $headerText -split "`r`n"
            $requestLine = $lines[0]
            $parts = $requestLine -split ' '
            if ($parts.Count -lt 2) { break }
            $method = $parts[0]; $rawUrl = $parts[1]

            $headers = @{}
            for ($i = 1; $i -lt $lines.Count; $i++) {
                if ($lines[$i] -match '^\s*([^:]+):\s*(.*)$') {
                    $headers[$matches[1].ToLower()] = $matches[2]
                }
            }
            $keepAlive = $true
            if ($headers["connection"] -and $headers["connection"].ToLower() -match "close") { $keepAlive = $false }

            # path + query
            $path = $rawUrl; $query = @{}
            if ($rawUrl -match '^([^?]*)\?(.*)$') {
                $path = $matches[1]
                foreach ($kv in ($matches[2] -split '&')) {
                    $p = $kv -split '=', 2
                    $query[$p[0]] = [System.Uri]::UnescapeDataString(($p[1] -replace '\+',' '))
                }
            }

            # body (for POST)
            $body = $null
            $clen = 0
            if ($headers["content-length"]) { [int]::TryParse($headers["content-length"], [ref]$clen) | Out-Null }
            if ($clen -gt 0) {
                $bodyBuf = New-Object byte[] $clen
                $read = 0
                while ($read -lt $clen) {
                    $n = $stream.Read($bodyBuf, $read, $clen - $read)
                    if ($n -le 0) { break }
                    $read += $n
                }
                $body = $enc.GetString($bodyBuf, 0, $read)
            }

            function Send-Response($code, $status, $contentType, [byte[]]$payload, $extraHeaders) {
                $sb = "HTTP/1.1 $code $status`r`n"
                $sb += "Content-Type: $contentType`r`n"
                $sb += "Content-Length: $($payload.Length)`r`n"
                $sb += "Cache-Control: no-store`r`n"
                $sb += "Access-Control-Allow-Origin: *`r`n"
                if ($extraHeaders) { $sb += $extraHeaders }
                $sb += if ($keepAlive) { "Connection: keep-alive`r`n`r`n" } else { "Connection: close`r`n`r`n" }
                $hb = $enc.GetBytes($sb)
                $stream.Write($hb, 0, $hb.Length)
                if ($payload.Length) { $stream.Write($payload, 0, $payload.Length) }
                $stream.Flush()
            }

            $authed = ($query["token"] -eq $shared.Password)

            # ---- routes ----
            if ($path -eq "/" -and $method -eq "GET") {
                Send-Response 200 "OK" "text/html; charset=utf-8" ($enc.GetBytes($shared.ViewerHtml)) $null
            }
            elseif ($path -eq "/auth" -and $method -eq "POST") {
                if ($body -eq $shared.Password) { Send-Response 200 "OK" "text/plain" ($enc.GetBytes("ok")) $null }
                else { Send-Response 403 "Forbidden" "text/plain" ($enc.GetBytes("no")) $null }
            }
            elseif ($path -eq "/stream" -and $method -eq "GET") {
                if (-not $authed) { Send-Response 403 "Forbidden" "text/plain" ($enc.GetBytes("no")) $null; continue }
                # MJPEG multipart stream - loops until the client disconnects.
                $boundary = "rdframe"
                $head = "HTTP/1.1 200 OK`r`nContent-Type: multipart/x-mixed-replace; boundary=$boundary`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
                $hb = $enc.GetBytes($head)
                $stream.Write($hb, 0, $hb.Length)
                $lastSeq = -1
                while ($shared.Running -and $client.Connected) {
                    if ($shared.Seq -ne $lastSeq -and $shared.Frame) {
                        $lastSeq = $shared.Seq
                        $frame = $shared.Frame
                        $part = "`r`n--$boundary`r`nContent-Type: image/jpeg`r`nContent-Length: $($frame.Length)`r`n`r`n"
                        $pb = $enc.GetBytes($part)
                        try {
                            $stream.Write($pb, 0, $pb.Length)
                            $stream.Write($frame, 0, $frame.Length)
                            $stream.Flush()
                        } catch { break }
                    }
                    Start-Sleep -Milliseconds ([int](1000 / ($shared.Fps + 2)))
                }
                break  # stream connection is done
            }
            elseif ($path -eq "/input" -and $method -eq "POST") {
                if (-not $authed) { Send-Response 403 "Forbidden" "text/plain" ($enc.GetBytes("no")) $null; continue }
                if (-not $shared.ViewOnly -and $body) {
                    try {
                        $events = $body | ConvertFrom-Json
                        if ($events -isnot [array]) { $events = @($events) }
                        foreach ($ev in $events) {
                            switch ($ev.t) {
                                "move" {
                                    $sx = [int]($shared.ScreenX + $ev.x * $shared.ScreenW)
                                    $sy = [int]($shared.ScreenY + $ev.y * $shared.ScreenH)
                                    [RdInput]::Move($sx, $sy)
                                }
                                "down" {
                                    $sx = [int]($shared.ScreenX + $ev.x * $shared.ScreenW)
                                    $sy = [int]($shared.ScreenY + $ev.y * $shared.ScreenH)
                                    [RdInput]::Move($sx, $sy); [RdInput]::Button([int]$ev.b, $true)
                                }
                                "up"   { [RdInput]::Button([int]$ev.b, $false) }
                                "wheel" {
                                    if ($ev.dy) { [RdInput]::Wheel([int]$ev.dy, $false) }
                                    if ($ev.dx) { [RdInput]::Wheel([int]$ev.dx, $true) }
                                }
                                "char" { if ($ev.c) { [RdInput]::TypeChar(([string]$ev.c)[0]) } }
                                "key"  {
                                    $code = Resolve-Vk $ev
                                    if ($code -ne 0) { [RdInput]::Key($code, [bool]$ev.down) }
                                }
                            }
                        }
                    } catch {}
                }
                Send-Response 200 "OK" "text/plain" ($enc.GetBytes("ok")) $null
            }
            else {
                Send-Response 404 "Not Found" "text/plain" ($enc.GetBytes("not found")) $null
            }

            if (-not $keepAlive) { break }
        }
    } catch {
    } finally {
        try { $client.Close() } catch {}
    }
}

# ----------------------------------------------------------------------------
# Start everything.
# ----------------------------------------------------------------------------
$pool = [runspacefactory]::CreateRunspacePool(1, 32)
$pool.Open()

# capture thread in its own runspace
$captureRs = [runspacefactory]::CreateRunspace()
$captureRs.Open()
$capturePs = [powershell]::Create()
$capturePs.Runspace = $captureRs
[void]$capturePs.AddScript($captureScript).AddArgument($shared)
$captureHandle = $capturePs.BeginInvoke()

# TCP listener
$ipAddr = [System.Net.IPAddress]::Parse($Bind)
$listener = New-Object System.Net.Sockets.TcpListener($ipAddr, $Port)
$listener.Start()

# discover LAN IPs to print
$ips = @()
try {
    $ips = [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
           Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.IPAddressToString }
} catch {}

Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host "   Portable Remote Desktop Host is running" -ForegroundColor Cyan
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "   Open a browser on the viewing machine and go to one of:" -ForegroundColor Gray
foreach ($ip in $ips) { Write-Host "       http://$ip`:$Port/" -ForegroundColor Green }
Write-Host "       http://localhost:$Port/   (this machine)" -ForegroundColor Green
Write-Host ""
Write-Host "   Password : " -NoNewline -ForegroundColor Gray; Write-Host $Password -ForegroundColor Yellow
Write-Host "   View only: $ViewOnly    FPS: $Fps    Quality: $Quality    Scale: $Scale" -ForegroundColor Gray
Write-Host ""
Write-Host "   Press Ctrl+C in this window to stop." -ForegroundColor DarkGray
Write-Host ""

$workers = New-Object System.Collections.ArrayList
try {
    while ($true) {
        if ($listener.Pending()) {
            $client = $listener.AcceptTcpClient()
            $ps = [powershell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($workerScript).AddArgument($client).AddArgument($shared)
            $h = $ps.BeginInvoke()
            [void]$workers.Add([pscustomobject]@{ Ps = $ps; Handle = $h })
        } else {
            Start-Sleep -Milliseconds 20
        }
        # reap finished workers
        for ($i = $workers.Count - 1; $i -ge 0; $i--) {
            if ($workers[$i].Handle.IsCompleted) {
                try { $workers[$i].Ps.EndInvoke($workers[$i].Handle) } catch {}
                $workers[$i].Ps.Dispose()
                $workers.RemoveAt($i)
            }
        }
    }
} finally {
    $shared.Running = $false
    try { $listener.Stop() } catch {}
    try { $capturePs.EndInvoke($captureHandle) } catch {}
    try { $capturePs.Dispose(); $captureRs.Close() } catch {}
    try { $pool.Close() } catch {}
    Write-Host "Stopped." -ForegroundColor Yellow
}
