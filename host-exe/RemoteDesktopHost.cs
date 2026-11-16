// Remote Desktop Host - native Windows GUI (.exe), no install, no admin.
//
// A single self-contained WinForms app: operator control window + screen
// capture (System.Drawing) + input injection (user32 SendInput) + a small
// HTTP/MJPEG server (TcpListener on a high port, no admin) that remote users
// open in a browser. Random password, trusted-computer auto-access, and a
// LAN <-> Internet toggle (Internet via a cloudflared quick tunnel).
//
// Build with the C# compiler that ships inside Windows (.NET Framework):
//   build.cmd        (or see that file for the exact csc command)
// No SDK, no admin, no NuGet.

using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Diagnostics;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace RemoteDesktop
{
    // ===================================================================
    // Native input injection (user32) - current user, no admin.
    // ===================================================================
    static class Native
    {
        [StructLayout(LayoutKind.Sequential)]
        public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
        [StructLayout(LayoutKind.Sequential)]
        public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
        [StructLayout(LayoutKind.Explicit)]
        public struct INPUTUNION { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
        [StructLayout(LayoutKind.Sequential)]
        public struct INPUT { public uint type; public INPUTUNION u; }

        [DllImport("user32.dll", SetLastError = true)]
        public static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);
        [DllImport("user32.dll")] public static extern int GetSystemMetrics(int nIndex);
        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();

        public const uint INPUT_MOUSE = 0, INPUT_KEYBOARD = 1;
        public const uint MOVE = 0x0001, ABSOLUTE = 0x8000, VIRTUALDESK = 0x4000;
        public const uint LEFTDOWN = 0x0002, LEFTUP = 0x0004, RIGHTDOWN = 0x0008, RIGHTUP = 0x0010;
        public const uint MIDDLEDOWN = 0x0020, MIDDLEUP = 0x0040, WHEEL = 0x0800, HWHEEL = 0x1000;
        public const uint KEYUP = 0x0002, UNICODE = 0x0004;

        public static int Size = Marshal.SizeOf(typeof(INPUT));

        static void Send(INPUT inp) { INPUT[] a = new INPUT[1]; a[0] = inp; SendInput(1, a, Size); }

        public static void MoveAbs(double nx, double ny)
        {
            int vx = GetSystemMetrics(76), vy = GetSystemMetrics(77);
            int vw = GetSystemMetrics(78), vh = GetSystemMetrics(79);
            int ax = (int)(nx * vw * 65535.0 / Math.Max(1, vw - 1));
            int ay = (int)(ny * vh * 65535.0 / Math.Max(1, vh - 1));
            if (ax < 0) ax = 0; if (ax > 65535) ax = 65535;
            if (ay < 0) ay = 0; if (ay > 65535) ay = 65535;
            INPUT i = new INPUT(); i.type = INPUT_MOUSE;
            i.u.mi.dx = ax; i.u.mi.dy = ay; i.u.mi.dwFlags = MOVE | ABSOLUTE | VIRTUALDESK;
            Send(i);
        }
        public static void Button(int b, bool down)
        {
            uint f = 0;
            if (b == 0) f = down ? LEFTDOWN : LEFTUP;
            else if (b == 1) f = down ? MIDDLEDOWN : MIDDLEUP;
            else if (b == 2) f = down ? RIGHTDOWN : RIGHTUP;
            if (f == 0) return;
            INPUT i = new INPUT(); i.type = INPUT_MOUSE; i.u.mi.dwFlags = f; Send(i);
        }
        public static void Wheel(int delta, bool horizontal)
        {
            INPUT i = new INPUT(); i.type = INPUT_MOUSE;
            i.u.mi.mouseData = (uint)delta; i.u.mi.dwFlags = horizontal ? HWHEEL : WHEEL; Send(i);
        }
        public static void TypeChar(char c)
        {
            INPUT d = new INPUT(); d.type = INPUT_KEYBOARD; d.u.ki.wScan = c; d.u.ki.dwFlags = UNICODE; Send(d);
            INPUT u = new INPUT(); u.type = INPUT_KEYBOARD; u.u.ki.wScan = c; u.u.ki.dwFlags = UNICODE | KEYUP; Send(u);
        }
        public static void Key(ushort vk, bool down)
        {
            INPUT i = new INPUT(); i.type = INPUT_KEYBOARD; i.u.ki.wVk = vk; i.u.ki.dwFlags = down ? 0 : KEYUP; Send(i);
        }

        public static readonly Dictionary<string, ushort> VK = new Dictionary<string, ushort>()
        {
            {"Enter",0x0D},{"Tab",0x09},{"Backspace",0x08},{"Escape",0x1B},{"Delete",0x2E},
            {"Insert",0x2D},{"Home",0x24},{"End",0x23},{"PageUp",0x21},{"PageDown",0x22},
            {"ArrowLeft",0x25},{"ArrowUp",0x26},{"ArrowRight",0x27},{"ArrowDown",0x28},
            {"Shift",0x10},{"Control",0x11},{"Alt",0x12},{"Meta",0x5B},{"CapsLock",0x14},
            {" ",0x20},{"PrintScreen",0x2C},
            {"F1",0x70},{"F2",0x71},{"F3",0x72},{"F4",0x73},{"F5",0x74},{"F6",0x75},
            {"F7",0x76},{"F8",0x77},{"F9",0x78},{"F10",0x79},{"F11",0x7A},{"F12",0x7B},
        };
    }

    // ===================================================================
    // Persisted state
    // ===================================================================
    public class DeviceInfo { public string Label { get; set; } public string Ip { get; set; } public string Added { get; set; } }
    public class Settings { public int Fps { get; set; } public int Quality { get; set; } public int ScalePct { get; set; } public bool ViewOnly { get; set; } }
    public class AppState
    {
        public string Password { get; set; }
        public string SecretHex { get; set; }
        public string Mode { get; set; }
        public bool AutoApprove { get; set; }
        public Settings Settings { get; set; }
        public Dictionary<string, DeviceInfo> Trusted { get; set; }
        public Dictionary<string, DeviceInfo> Pending { get; set; }

        public static AppState Default()
        {
            return new AppState
            {
                Password = Engine.GenPassword(),
                SecretHex = Engine.RandHex(32),
                Mode = "lan",
                AutoApprove = false,
                Settings = new Settings { Fps = 12, Quality = 55, ScalePct = 100, ViewOnly = false },
                Trusted = new Dictionary<string, DeviceInfo>(),
                Pending = new Dictionary<string, DeviceInfo>(),
            };
        }
    }

    // ===================================================================
    // cloudflared quick tunnel
    // ===================================================================
    class TunnelManager
    {
        public string Status = "stopped"; // stopped|starting|running|missing|error
        public string Url = null;
        Process proc;
        int port;
        static Regex rx = new Regex(@"https://[a-z0-9-]+\.trycloudflare\.com");

        public TunnelManager(int p) { port = p; }

        public static string FindExe()
        {
            string local = Path.Combine(Engine.ExeDir, "cloudflared.exe");
            if (File.Exists(local)) return local;
            string path = Environment.GetEnvironmentVariable("PATH") ?? "";
            foreach (string dir in path.Split(';'))
            {
                try { string c = Path.Combine(dir.Trim(), "cloudflared.exe"); if (File.Exists(c)) return c; }
                catch { }
            }
            return null;
        }

        public void Start()
        {
            if (Status == "starting" || Status == "running") return;
            string exe = FindExe();
            if (exe == null) { Status = "missing"; return; }
            Url = null; Status = "starting";
            try
            {
                proc = new Process();
                proc.StartInfo.FileName = exe;
                proc.StartInfo.Arguments = "tunnel --no-autoupdate --url http://localhost:" + port;
                proc.StartInfo.UseShellExecute = false;
                proc.StartInfo.CreateNoWindow = true;
                proc.StartInfo.RedirectStandardOutput = true;
                proc.StartInfo.RedirectStandardError = true;
                proc.OutputDataReceived += OnData;
                proc.ErrorDataReceived += OnData;
                proc.Start();
                proc.BeginOutputReadLine();
                proc.BeginErrorReadLine();
            }
            catch { Status = "error"; }
        }
        void OnData(object s, DataReceivedEventArgs e)
        {
            if (e.Data == null) return;
            Match m = rx.Match(e.Data);
            if (m.Success) { Url = m.Value; Status = "running"; }
        }
        public void Stop()
        {
            try { if (proc != null && !proc.HasExited) proc.Kill(); } catch { }
            proc = null; Url = null; Status = "stopped";
        }
    }

    // ===================================================================
    // Engine: capture + server + state
    // ===================================================================
    class Engine
    {
        public static string ExeDir = AppDomain.CurrentDomain.BaseDirectory;
        public static string StatePath = Path.Combine(ExeDir, "rd_state.json");

        public AppState State;
        public Settings Set { get { return State.Settings; } }
        public readonly object Lock = new object();
        public int Port = 8765;
        public TunnelManager Tunnel;
        public string ShareDir;
        public bool Running = false;

        byte[] secret;
        TcpListener listener;
        Thread acceptThread, captureThread;
        volatile byte[] frame;
        long seq = 0;
        int capVw, capVh, capVx, capVy;
        readonly List<string> log = new List<string>();
        JavaScriptSerializer js = new JavaScriptSerializer();

        public Engine()
        {
            Load();
            secret = HexToBytes(State.SecretHex);
            Tunnel = new TunnelManager(Port);
            ShareDir = Path.Combine(ExeDir, "shared");
            try { Directory.CreateDirectory(ShareDir); } catch { }
        }

        // ---- query + clipboard helpers ----
        static string QParam(string query, string key)
        {
            foreach (string kv in query.Split('&'))
            {
                int e = kv.IndexOf('=');
                string k = e >= 0 ? kv.Substring(0, e) : kv;
                if (k == key) return e >= 0 ? Uri.UnescapeDataString(kv.Substring(e + 1).Replace('+', ' ')) : "";
            }
            return "";
        }
        static string ClipGet()
        {
            string res = "";
            Thread t = new Thread(delegate () { try { if (Clipboard.ContainsText()) res = Clipboard.GetText(); } catch { } });
            t.SetApartmentState(ApartmentState.STA); t.Start(); t.Join();
            return res;
        }
        static void ClipSet(string s)
        {
            Thread t = new Thread(delegate () { try { if (string.IsNullOrEmpty(s)) Clipboard.Clear(); else Clipboard.SetText(s); } catch { } });
            t.SetApartmentState(ApartmentState.STA); t.Start(); t.Join();
        }

        // ---- logging ----
        public void Log(string s)
        {
            lock (log) { log.Add(DateTime.Now.ToString("HH:mm:ss") + "  " + s); if (log.Count > 300) log.RemoveAt(0); }
        }
        public string[] DrainLog() { lock (log) { var a = log.ToArray(); return a; } }

        // ---- state persistence ----
        public void Load()
        {
            try
            {
                string txt = File.ReadAllText(StatePath);
                State = new JavaScriptSerializer().Deserialize<AppState>(txt);
                if (State == null) State = AppState.Default();
                if (State.Settings == null) State.Settings = AppState.Default().Settings;
                if (State.Trusted == null) State.Trusted = new Dictionary<string, DeviceInfo>();
                if (State.Pending == null) State.Pending = new Dictionary<string, DeviceInfo>();
                if (string.IsNullOrEmpty(State.SecretHex)) State.SecretHex = RandHex(32);
                if (string.IsNullOrEmpty(State.Password)) State.Password = GenPassword();
                if (string.IsNullOrEmpty(State.Mode)) State.Mode = "lan";
            }
            catch { State = AppState.Default(); }
        }
        public void Save()
        {
            try
            {
                lock (Lock)
                {
                    string txt = js.Serialize(State);
                    File.WriteAllText(StatePath + ".tmp", txt);
                    if (File.Exists(StatePath)) File.Delete(StatePath);
                    File.Move(StatePath + ".tmp", StatePath);
                }
            }
            catch { }
        }

        // ---- crypto helpers ----
        public static string RandHex(int nbytes)
        {
            byte[] b = new byte[nbytes];
            using (var r = new RNGCryptoServiceProvider()) r.GetBytes(b);
            return BitConverter.ToString(b).Replace("-", "").ToLowerInvariant();
        }
        public static byte[] HexToBytes(string hex)
        {
            byte[] b = new byte[hex.Length / 2];
            for (int i = 0; i < b.Length; i++) b[i] = Convert.ToByte(hex.Substring(i * 2, 2), 16);
            return b;
        }
        public static string GenPassword()
        {
            const string al = "23456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz";
            var sb = new StringBuilder();
            byte[] b = new byte[10];
            using (var r = new RNGCryptoServiceProvider()) r.GetBytes(b);
            foreach (byte x in b) sb.Append(al[x % al.Length]);
            return sb.ToString();
        }
        string Sign(string val)
        {
            using (var h = new HMACSHA256(secret))
            {
                byte[] mac = h.ComputeHash(Encoding.UTF8.GetBytes(val));
                string hex = BitConverter.ToString(mac).Replace("-", "").ToLowerInvariant().Substring(0, 24);
                return val + "." + hex;
            }
        }
        string Verify(string token)
        {
            if (string.IsNullOrEmpty(token) || token.IndexOf('.') < 0) return null;
            int i = token.LastIndexOf('.');
            string val = token.Substring(0, i), mac = token.Substring(i + 1);
            using (var h = new HMACSHA256(secret))
            {
                byte[] m = h.ComputeHash(Encoding.UTF8.GetBytes(val));
                string good = BitConverter.ToString(m).Replace("-", "").ToLowerInvariant().Substring(0, 24);
                return SlowEquals(mac, good) ? val : null;
            }
        }
        static bool SlowEquals(string a, string b)
        {
            if (a == null || b == null || a.Length != b.Length) return false;
            int r = 0; for (int i = 0; i < a.Length; i++) r |= a[i] ^ b[i]; return r == 0;
        }

        // ---- public URLs ----
        public List<string> LanUrls()
        {
            var list = new List<string>();
            try
            {
                foreach (var ip in Dns.GetHostAddresses(Dns.GetHostName()))
                    if (ip.AddressFamily == AddressFamily.InterNetwork && !ip.ToString().StartsWith("127."))
                        list.Add("http://" + ip + ":" + Port + "/");
            }
            catch { }
            list.Add("http://localhost:" + Port + "/");
            return list;
        }

        // ---- lifecycle ----
        public void Start()
        {
            if (Running) return;
            Running = true;
            captureThread = new Thread(CaptureLoop); captureThread.IsBackground = true; captureThread.Start();
            listener = new TcpListener(IPAddress.Any, Port);
            listener.Start();
            acceptThread = new Thread(AcceptLoop); acceptThread.IsBackground = true; acceptThread.Start();
            if (State.Mode == "internet") Tunnel.Start();
            Log("Server started on port " + Port + " (" + State.Mode + ")");
        }
        public void Stop()
        {
            Running = false;
            try { if (listener != null) listener.Stop(); } catch { }
            Tunnel.Stop();
            Log("Server stopped");
        }
        public void SetMode(string mode)
        {
            lock (Lock) { State.Mode = mode; }
            Save();
            if (mode == "internet") Tunnel.Start(); else Tunnel.Stop();
            Log("Mode: " + mode);
        }

        // ---- capture ----
        Bitmap full, scaled; Graphics gFull, gScaled; int lastW, lastH, lastSw, lastSh;
        ImageCodecInfo jpeg = GetJpegCodec();
        static ImageCodecInfo GetJpegCodec()
        {
            foreach (var c in ImageCodecInfo.GetImageEncoders()) if (c.FormatID == ImageFormat.Jpeg.Guid) return c;
            return null;
        }
        void CaptureLoop()
        {
            var ep = new EncoderParameters(1);
            while (Running)
            {
                var t0 = DateTime.UtcNow;
                try
                {
                    int vx = Native.GetSystemMetrics(76), vy = Native.GetSystemMetrics(77);
                    int vw = Native.GetSystemMetrics(78), vh = Native.GetSystemMetrics(79);
                    if (vw <= 0 || vh <= 0) { Thread.Sleep(200); continue; }
                    capVx = vx; capVy = vy; capVw = vw; capVh = vh;
                    if (full == null || lastW != vw || lastH != vh)
                    {
                        if (gFull != null) gFull.Dispose(); if (full != null) full.Dispose();
                        full = new Bitmap(vw, vh); gFull = Graphics.FromImage(full); lastW = vw; lastH = vh;
                    }
                    gFull.CopyFromScreen(vx, vy, 0, 0, full.Size);
                    try
                    {
                        Point cp = Cursor.Position;
                        int cx = cp.X - vx, cy = cp.Y - vy;
                        Point[] arrow = new Point[] {
                            new Point(cx,cy), new Point(cx,cy+16), new Point(cx+4,cy+12),
                            new Point(cx+7,cy+18), new Point(cx+9,cy+17), new Point(cx+6,cy+11), new Point(cx+11,cy+11) };
                        gFull.FillPolygon(Brushes.White, arrow); gFull.DrawPolygon(Pens.Black, arrow);
                    }
                    catch { }

                    int scalePct = Set.ScalePct; if (scalePct < 10) scalePct = 10; if (scalePct > 100) scalePct = 100;
                    Bitmap outBmp = full;
                    if (scalePct < 100)
                    {
                        int sw = Math.Max(1, vw * scalePct / 100), sh = Math.Max(1, vh * scalePct / 100);
                        if (scaled == null || lastSw != sw || lastSh != sh)
                        {
                            if (gScaled != null) gScaled.Dispose(); if (scaled != null) scaled.Dispose();
                            scaled = new Bitmap(sw, sh); gScaled = Graphics.FromImage(scaled);
                            gScaled.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.Bilinear;
                            lastSw = sw; lastSh = sh;
                        }
                        gScaled.DrawImage(full, 0, 0, sw, sh); outBmp = scaled;
                    }

                    int q = Set.Quality; if (q < 1) q = 1; if (q > 100) q = 100;
                    ep.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, (long)q);
                    using (var ms = new MemoryStream())
                    {
                        outBmp.Save(ms, jpeg, ep);
                        frame = ms.ToArray();
                        Interlocked.Increment(ref seq);
                    }
                }
                catch { Thread.Sleep(200); }

                int target = 1000 / Math.Max(1, Set.Fps);
                int dt = (int)(DateTime.UtcNow - t0).TotalMilliseconds;
                if (dt < target) Thread.Sleep(target - dt);
            }
        }

        // ---- server ----
        void AcceptLoop()
        {
            while (Running)
            {
                try
                {
                    TcpClient c = listener.AcceptTcpClient();
                    ThreadPool.QueueUserWorkItem(delegate { HandleClient(c); });
                }
                catch { if (!Running) break; Thread.Sleep(20); }
            }
        }

        static Dictionary<string, List<DateTime>> throttle = new Dictionary<string, List<DateTime>>();

        void HandleClient(TcpClient client)
        {
            try
            {
                client.NoDelay = true;
                NetworkStream ns = client.GetStream();
                while (Running && client.Connected)
                {
                    string head = ReadHeaders(ns);
                    if (head == null || head.Length == 0) break;
                    string[] lines = head.Split(new string[] { "\r\n" }, StringSplitOptions.None);
                    string[] rl = lines[0].Split(' ');
                    if (rl.Length < 2) break;
                    string method = rl[0], rawUrl = rl[1];
                    var headers = new Dictionary<string, string>();
                    for (int i = 1; i < lines.Length; i++)
                    {
                        int c = lines[i].IndexOf(':');
                        if (c > 0) headers[lines[i].Substring(0, c).Trim().ToLowerInvariant()] = lines[i].Substring(c + 1).Trim();
                    }
                    bool keepAlive = true;
                    if (headers.ContainsKey("connection") && headers["connection"].ToLowerInvariant().Contains("close")) keepAlive = false;

                    string path = rawUrl; string query = "";
                    int qm = rawUrl.IndexOf('?');
                    if (qm >= 0) { path = rawUrl.Substring(0, qm); query = rawUrl.Substring(qm + 1); }

                    byte[] body = new byte[0];
                    if (headers.ContainsKey("content-length"))
                    {
                        int clen = 0; int.TryParse(headers["content-length"], out clen);
                        body = ReadBody(ns, clen);
                    }

                    var cookies = ParseCookies(headers.ContainsKey("cookie") ? headers["cookie"] : "");
                    string xff = headers.ContainsKey("x-forwarded-for") ? headers["x-forwarded-for"].Split(',')[0].Trim()
                                   : ((IPEndPoint)client.Client.RemoteEndPoint).Address.ToString();
                    string ua = headers.ContainsKey("user-agent") ? headers["user-agent"] : "";

                    if (path == "/" && method == "GET")
                        Send(ns, 200, "OK", "text/html; charset=utf-8", ViewerHtml(), null, keepAlive);
                    else if (path == "/session" && method == "GET")
                        Send(ns, 200, "OK", "application/json",
                             Encoding.UTF8.GetBytes("{\"authed\":" + (Authed(cookies) ? "true" : "false") +
                             ",\"viewOnly\":" + (Set.ViewOnly ? "true" : "false") + "}"), null, keepAlive);
                    else if (path == "/auth" && method == "POST")
                        DoAuth(ns, body, cookies, xff, ua, keepAlive);
                    else if (path == "/stream" && method == "GET")
                    { Stream_(ns, cookies); break; }
                    else if (path == "/input" && method == "POST")
                    {
                        if (Authed(cookies)) { DoInput(body); Send(ns, 200, "OK", "text/plain", Encoding.UTF8.GetBytes("ok"), null, keepAlive); }
                        else Send(ns, 403, "Forbidden", "text/plain", Encoding.UTF8.GetBytes("no"), null, keepAlive);
                    }
                    else if (path == "/clipboard" && method == "GET")
                    {
                        if (!Authed(cookies)) Send(ns, 403, "Forbidden", "text/plain", Encoding.UTF8.GetBytes("no"), null, keepAlive);
                        else { string j = js.Serialize(new Dictionary<string, object>() { { "text", ClipGet() } });
                               Send(ns, 200, "OK", "application/json", Encoding.UTF8.GetBytes(j), null, keepAlive); }
                    }
                    else if (path == "/clipboard" && method == "POST")
                    {
                        if (!Authed(cookies)) Send(ns, 403, "Forbidden", "text/plain", Encoding.UTF8.GetBytes("no"), null, keepAlive);
                        else {
                            try { var d = js.DeserializeObject(Encoding.UTF8.GetString(body)) as Dictionary<string, object>;
                                  ClipSet(d != null && d.ContainsKey("text") && d["text"] != null ? d["text"].ToString() : ""); }
                            catch { }
                            Send(ns, 200, "OK", "text/plain", Encoding.UTF8.GetBytes("ok"), null, keepAlive);
                        }
                    }
                    else if (path == "/files" && method == "GET")
                    {
                        if (!Authed(cookies)) Send(ns, 403, "Forbidden", "text/plain", Encoding.UTF8.GetBytes("no"), null, keepAlive);
                        else {
                            var list = new List<object>();
                            try { foreach (string f in Directory.GetFiles(ShareDir)) { var fi = new FileInfo(f);
                                      list.Add(new Dictionary<string, object>() { { "name", fi.Name }, { "size", fi.Length } }); } }
                            catch { }
                            string j = js.Serialize(new Dictionary<string, object>() { { "files", list } });
                            Send(ns, 200, "OK", "application/json", Encoding.UTF8.GetBytes(j), null, keepAlive);
                        }
                    }
                    else if (path == "/download" && method == "GET")
                    {
                        if (!Authed(cookies)) Send(ns, 403, "Forbidden", "text/plain", Encoding.UTF8.GetBytes("no"), null, keepAlive);
                        else {
                            string name = Path.GetFileName(QParam(query, "name"));
                            string fp = string.IsNullOrEmpty(name) ? null : Path.Combine(ShareDir, name);
                            if (fp == null || !File.Exists(fp)) Send(ns, 404, "Not Found", "text/plain", Encoding.UTF8.GetBytes("not found"), null, keepAlive);
                            else { byte[] data = File.ReadAllBytes(fp);
                                   string extra = "Content-Disposition: attachment; filename=\"" + name + "\"\r\n";
                                   Send(ns, 200, "OK", "application/octet-stream", data, extra, keepAlive); }
                        }
                    }
                    else if (path == "/upload" && method == "POST")
                    {
                        if (!Authed(cookies)) Send(ns, 403, "Forbidden", "text/plain", Encoding.UTF8.GetBytes("no"), null, keepAlive);
                        else {
                            try { string name = Path.GetFileName(QParam(query, "name")); if (string.IsNullOrEmpty(name)) name = "upload.bin";
                                  File.WriteAllBytes(Path.Combine(ShareDir, name), body);
                                  Log("File uploaded: " + name + " (" + body.Length + " bytes)"); }
                            catch { }
                            Send(ns, 200, "OK", "text/plain", Encoding.UTF8.GetBytes("ok"), null, keepAlive);
                        }
                    }
                    else if (path == "/favicon.ico")
                        Send(ns, 204, "No Content", "text/plain", new byte[0], null, keepAlive);
                    else
                        Send(ns, 404, "Not Found", "text/plain", Encoding.UTF8.GetBytes("not found"), null, keepAlive);

                    if (!keepAlive) break;
                }
            }
            catch { }
            finally { try { client.Close(); } catch { } }
        }

        string ReadHeaders(Stream s)
        {
            var buf = new List<byte>();
            int b;
            while ((b = s.ReadByte()) != -1)
            {
                buf.Add((byte)b);
                int n = buf.Count;
                if (n >= 4 && buf[n - 4] == 13 && buf[n - 3] == 10 && buf[n - 2] == 13 && buf[n - 1] == 10) break;
                if (n > 65536) break;
            }
            if (buf.Count == 0) return null;
            return Encoding.ASCII.GetString(buf.ToArray());
        }
        byte[] ReadBody(Stream s, int len)
        {
            byte[] buf = new byte[len]; int read = 0;
            while (read < len) { int n = s.Read(buf, read, len - read); if (n <= 0) break; read += n; }
            if (read == len) return buf;
            byte[] t = new byte[read]; Array.Copy(buf, t, read); return t;
        }
        Dictionary<string, string> ParseCookies(string raw)
        {
            var d = new Dictionary<string, string>();
            foreach (string part in raw.Split(';'))
            {
                int e = part.IndexOf('=');
                if (e > 0) d[part.Substring(0, e).Trim()] = part.Substring(e + 1).Trim();
            }
            return d;
        }
        bool Authed(Dictionary<string, string> cookies)
        {
            string sess = cookies.ContainsKey("rd_sess") ? cookies["rd_sess"] : "";
            if (Verify(sess) != null) return true;
            string dev = cookies.ContainsKey("rd_dev") ? Verify(cookies["rd_dev"]) : null;
            if (dev == null) return false;
            lock (Lock) return State.Trusted.ContainsKey(dev);
        }
        void Send(Stream s, int code, string status, string ctype, byte[] body, string extra, bool keepAlive)
        {
            var sb = new StringBuilder();
            sb.Append("HTTP/1.1 ").Append(code).Append(' ').Append(status).Append("\r\n");
            sb.Append("Content-Type: ").Append(ctype).Append("\r\n");
            sb.Append("Content-Length: ").Append(body.Length).Append("\r\n");
            sb.Append("Cache-Control: no-store\r\n");
            if (extra != null) sb.Append(extra);
            sb.Append("Connection: ").Append(keepAlive ? "keep-alive" : "close").Append("\r\n\r\n");
            byte[] hb = Encoding.ASCII.GetBytes(sb.ToString());
            s.Write(hb, 0, hb.Length);
            if (body.Length > 0) s.Write(body, 0, body.Length);
            s.Flush();
        }

        void DoAuth(Stream ns, byte[] body, Dictionary<string, string> cookies, string ip, string ua, bool keepAlive)
        {
            lock (throttle)
            {
                List<DateTime> tries;
                if (!throttle.TryGetValue(ip, out tries)) { tries = new List<DateTime>(); throttle[ip] = tries; }
                tries.RemoveAll(delegate (DateTime t) { return (DateTime.UtcNow - t).TotalSeconds > 60; });
                if (tries.Count >= 10) { Send(ns, 429, "Too Many Requests", "text/plain", Encoding.UTF8.GetBytes("slow"), null, keepAlive); return; }
            }
            string pw = Encoding.UTF8.GetString(body);
            if (!SlowEquals(pw, State.Password))
            {
                lock (throttle) throttle[ip].Add(DateTime.UtcNow);
                Send(ns, 403, "Forbidden", "text/plain", Encoding.UTF8.GetBytes("no"), null, keepAlive);
                return;
            }
            lock (throttle) throttle[ip] = new List<DateTime>();
            string dev = cookies.ContainsKey("rd_dev") ? Verify(cookies["rd_dev"]) : null;
            if (dev == null) dev = RandHex(8);
            var info = new DeviceInfo { Label = Label(ua), Ip = ip, Added = DateTime.Now.ToString("yyyy-MM-dd HH:mm") };
            lock (Lock)
            {
                if (State.AutoApprove) { State.Trusted[dev] = info; State.Pending.Remove(dev); }
                else if (!State.Trusted.ContainsKey(dev)) State.Pending[dev] = info;
            }
            Save();
            Log((State.AutoApprove ? "Auto-approved " : "Login from ") + info.Label + " (" + ip + ")");
            string sess = Sign(RandHex(8)), devtok = Sign(dev);
            string extra = "Set-Cookie: rd_sess=" + sess + "; Path=/; HttpOnly; SameSite=Lax\r\n"
                         + "Set-Cookie: rd_dev=" + devtok + "; Path=/; Max-Age=31536000; HttpOnly; SameSite=Lax\r\n";
            Send(ns, 200, "OK", "text/plain", Encoding.UTF8.GetBytes("ok"), extra, keepAlive);
        }
        static string Label(string ua)
        {
            string[] tags = { "Windows", "Macintosh", "Linux", "Android", "iPhone", "iPad" };
            foreach (string t in tags) if (ua.Contains(t)) return t == "Macintosh" ? "Mac" : t;
            return "Computer";
        }

        void DoInput(byte[] body)
        {
            if (Set.ViewOnly) return;
            try
            {
                object parsed = js.DeserializeObject(Encoding.UTF8.GetString(body));
                object[] arr = parsed as object[];
                if (arr == null) return;
                foreach (object o in arr)
                {
                    var ev = o as Dictionary<string, object>;
                    if (ev == null) continue;
                    string t = Str(ev, "t");
                    if (t == "move") Native.MoveAbs(Dbl(ev, "x"), Dbl(ev, "y"));
                    else if (t == "down") { Native.MoveAbs(Dbl(ev, "x"), Dbl(ev, "y")); Native.Button((int)Dbl(ev, "b"), true); }
                    else if (t == "up") Native.Button((int)Dbl(ev, "b"), false);
                    else if (t == "wheel") { if (ev.ContainsKey("dy")) Native.Wheel((int)Dbl(ev, "dy"), false); if (ev.ContainsKey("dx")) Native.Wheel((int)Dbl(ev, "dx"), true); }
                    else if (t == "char") { string c = Str(ev, "c"); foreach (char ch in c) Native.TypeChar(ch); }
                    else if (t == "key")
                    {
                        string k = Str(ev, "k"); bool down = Bool(ev, "down");
                        ushort vk = 0;
                        if (Native.VK.ContainsKey(k)) vk = Native.VK[k];
                        else if (k.Length == 1) { char u = char.ToUpperInvariant(k[0]); if ((u >= '0' && u <= '9') || (u >= 'A' && u <= 'Z')) vk = u; }
                        if (vk != 0) Native.Key(vk, down);
                    }
                }
            }
            catch { }
        }
        static string Str(Dictionary<string, object> d, string k) { object v; return d.TryGetValue(k, out v) && v != null ? v.ToString() : ""; }
        static double Dbl(Dictionary<string, object> d, string k) { object v; if (d.TryGetValue(k, out v) && v != null) { try { return Convert.ToDouble(v, CultureInfo.InvariantCulture); } catch { } } return 0; }
        static bool Bool(Dictionary<string, object> d, string k) { object v; return d.TryGetValue(k, out v) && v is bool && (bool)v; }

        void Stream_(Stream ns, Dictionary<string, string> cookies)
        {
            if (!Authed(cookies)) { Send(ns, 403, "Forbidden", "text/plain", Encoding.UTF8.GetBytes("no"), null, false); return; }
            byte[] hb = Encoding.ASCII.GetBytes(
                "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=rdframe\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n");
            ns.Write(hb, 0, hb.Length);
            long last = -1;
            while (Running)
            {
                long sq = Interlocked.Read(ref seq);
                byte[] f = frame;
                if (f != null && sq != last)
                {
                    last = sq;
                    byte[] ph = Encoding.ASCII.GetBytes("\r\n--rdframe\r\nContent-Type: image/jpeg\r\nContent-Length: " + f.Length + "\r\n\r\n");
                    try { ns.Write(ph, 0, ph.Length); ns.Write(f, 0, f.Length); ns.Flush(); }
                    catch { break; }
                }
                Thread.Sleep(1000 / (Math.Max(1, Set.Fps) + 2));
            }
        }

        // ---- trusted mgmt (called by GUI) ----
        public void Approve(string id) { lock (Lock) { if (State.Pending.ContainsKey(id)) { State.Trusted[id] = State.Pending[id]; State.Pending.Remove(id); } } Save(); }
        public void Deny(string id) { lock (Lock) State.Pending.Remove(id); Save(); }
        public void RemoveTrusted(string id) { lock (Lock) { State.Trusted.Remove(id); State.Pending.Remove(id); } Save(); }
        public void RegenPassword() { lock (Lock) State.Password = GenPassword(); Save(); Log("Password regenerated"); }

        byte[] ViewerHtml() { return Convert.FromBase64String(Program.VIEWER_B64); }
    }

    // ===================================================================
    // GUI
    // ===================================================================
    class MainForm : Form
    {
        Engine eng;
        TextBox txtPw, txtLog;
        Label lblStatus, lblNetStatus, lblPubUrl;
        TextBox txtLan;
        Button btnStart, btnRegen, btnCopyPw, btnCopyUrl, btnGetCf, btnOpen;
        RadioButton rbLan, rbNet;
        CheckBox chkAuto, chkView;
        NumericUpDown numFps, numQ, numScale, numPort;
        ListView lvTrusted, lvPending;
        System.Windows.Forms.Timer timer;

        public MainForm()
        {
            eng = new Engine();
            Text = "Remote Desktop Host";
            Width = 640; Height = 760; StartPosition = FormStartPosition.CenterScreen;
            Font = new Font("Segoe UI", 9f);
            BackColor = Color.FromArgb(24, 26, 30); ForeColor = Color.Gainsboro;
            BuildUi();
            LoadFromState();
            eng.Start();
            timer = new System.Windows.Forms.Timer(); timer.Interval = 1000; timer.Tick += Refresh_; timer.Start();
            FormClosing += delegate { try { eng.Stop(); } catch { } };
        }

        Label Section(string t, int y)
        {
            var l = new Label(); l.Text = t.ToUpperInvariant(); l.ForeColor = Color.Gray;
            l.Font = new Font("Segoe UI", 8f, FontStyle.Bold); l.SetBounds(16, y, 600, 16); Controls.Add(l); return l;
        }
        Button Btn(string t, int x, int y, int w, EventHandler on)
        {
            var b = new Button(); b.Text = t; b.SetBounds(x, y, w, 26); b.FlatStyle = FlatStyle.Flat;
            b.BackColor = Color.FromArgb(45, 50, 58); b.ForeColor = Color.White; b.FlatAppearance.BorderSize = 0;
            b.Click += on; Controls.Add(b); return b;
        }

        void BuildUi()
        {
            int y = 12;
            lblStatus = new Label(); lblStatus.SetBounds(16, y, 600, 20);
            lblStatus.Font = new Font("Segoe UI", 11f, FontStyle.Bold); Controls.Add(lblStatus); y += 30;

            Section("Access password", y); y += 20;
            txtPw = new TextBox(); txtPw.SetBounds(16, y, 220, 26); txtPw.ReadOnly = true;
            txtPw.BackColor = Color.FromArgb(12, 14, 17); txtPw.ForeColor = Color.White;
            txtPw.Font = new Font("Consolas", 11f); Controls.Add(txtPw);
            btnCopyPw = Btn("Copy", 244, y, 60, delegate { Clipboard.SetText(txtPw.Text); });
            btnRegen = Btn("Regenerate", 310, y, 100, delegate { eng.RegenPassword(); LoadFromState(); });
            y += 40;

            Section("Where people connect", y); y += 22;
            rbLan = new RadioButton(); rbLan.Text = "LAN only"; rbLan.SetBounds(16, y, 90, 24);
            rbNet = new RadioButton(); rbNet.Text = "Internet"; rbNet.SetBounds(120, y, 90, 24);
            rbLan.CheckedChanged += ModeChanged; rbNet.CheckedChanged += ModeChanged;
            Controls.Add(rbLan); Controls.Add(rbNet);
            lblNetStatus = new Label(); lblNetStatus.SetBounds(220, y + 3, 300, 18); Controls.Add(lblNetStatus);
            y += 30;
            txtLan = new TextBox(); txtLan.SetBounds(16, y, 490, 46); txtLan.Multiline = true; txtLan.ReadOnly = true;
            txtLan.BackColor = Color.FromArgb(12, 14, 17); txtLan.ForeColor = Color.Gainsboro; txtLan.BorderStyle = BorderStyle.FixedSingle;
            Controls.Add(txtLan); y += 52;
            lblPubUrl = new Label(); lblPubUrl.SetBounds(16, y, 490, 18); lblPubUrl.ForeColor = Color.FromArgb(120, 170, 255);
            Controls.Add(lblPubUrl); y += 22;
            btnCopyUrl = Btn("Copy link", 16, y, 90, delegate { if (!string.IsNullOrEmpty(eng.Tunnel.Url)) Clipboard.SetText(eng.Tunnel.Url); });
            btnGetCf = Btn("Get cloudflared", 112, y, 120, delegate { Help_Cf(); });
            btnOpen = Btn("Open viewer here", 238, y, 130, delegate { try { Process.Start("http://localhost:" + eng.Port + "/"); } catch { } });
            Btn("Shared folder", 376, y, 118, delegate { try { Directory.CreateDirectory(eng.ShareDir); Process.Start(eng.ShareDir); } catch { } });
            y += 40;

            Section("Trusted computers", y); y += 20;
            chkAuto = new CheckBox(); chkAuto.Text = "Automatically approve new computers (give access without manual approval)";
            chkAuto.SetBounds(16, y, 520, 22); chkAuto.CheckedChanged += delegate { lock (eng.Lock) eng.State.AutoApprove = chkAuto.Checked; eng.Save(); };
            Controls.Add(chkAuto); y += 26;
            lvPending = MakeList(16, y, 490, 70); Controls.Add(lvPending); y += 74;
            var pbtns = y;
            Btn("Approve", 16, pbtns, 90, delegate { Each(lvPending, eng.Approve); LoadFromState(); });
            Btn("Deny", 112, pbtns, 70, delegate { Each(lvPending, eng.Deny); LoadFromState(); });
            new Label() { }.Dispose();
            y += 34;
            lvTrusted = MakeList(16, y, 490, 90); Controls.Add(lvTrusted); y += 94;
            Btn("Remove selected", 16, y, 130, delegate { Each(lvTrusted, eng.RemoveTrusted); LoadFromState(); });
            y += 38;

            Section("Quality & input", y); y += 20;
            chkView = new CheckBox(); chkView.Text = "View only (ignore all remote input)";
            chkView.SetBounds(16, y, 300, 22); chkView.CheckedChanged += delegate { eng.Set.ViewOnly = chkView.Checked; eng.Save(); };
            Controls.Add(chkView); y += 28;
            AddLbl("FPS", 16, y); numFps = Num(50, y, 1, 30, delegate { eng.Set.Fps = (int)numFps.Value; eng.Save(); });
            AddLbl("Quality", 120, y); numQ = Num(175, y, 10, 95, delegate { eng.Set.Quality = (int)numQ.Value; eng.Save(); });
            AddLbl("Scale %", 245, y); numScale = Num(305, y, 20, 100, delegate { eng.Set.ScalePct = (int)numScale.Value; eng.Save(); });
            AddLbl("Port", 375, y); numPort = Num(415, y, 1, 65000, null); numPort.Value = eng.Port;
            numPort.Enabled = false;
            y += 34;

            Section("Activity", y); y += 20;
            txtLog = new TextBox(); txtLog.SetBounds(16, y, 600, 90); txtLog.Multiline = true; txtLog.ReadOnly = true;
            txtLog.ScrollBars = ScrollBars.Vertical; txtLog.BackColor = Color.FromArgb(12, 14, 17); txtLog.ForeColor = Color.Gray;
            txtLog.Font = new Font("Consolas", 8f); Controls.Add(txtLog); y += 96;

            btnStart = Btn("Stop", 16, y, 100, delegate { ToggleServer(); });
            btnStart.BackColor = Color.FromArgb(120, 40, 40);
        }

        ListView MakeList(int x, int y, int w, int h)
        {
            var lv = new ListView(); lv.SetBounds(x, y, w, h); lv.View = View.Details; lv.FullRowSelect = true;
            lv.BackColor = Color.FromArgb(12, 14, 17); lv.ForeColor = Color.Gainsboro; lv.HeaderStyle = ColumnHeaderStyle.Nonclickable;
            lv.Columns.Add("Computer", 150); lv.Columns.Add("IP", 160); lv.Columns.Add("Added", 150);
            return lv;
        }
        void AddLbl(string t, int x, int y) { var l = new Label(); l.Text = t; l.SetBounds(x, y + 3, 55, 18); l.ForeColor = Color.Gray; Controls.Add(l); }
        NumericUpDown Num(int x, int y, int min, int max, EventHandler on)
        {
            var n = new NumericUpDown(); n.SetBounds(x, y, 60, 24); n.Minimum = min; n.Maximum = max;
            n.BackColor = Color.FromArgb(12, 14, 17); n.ForeColor = Color.White;
            if (on != null) n.ValueChanged += on; Controls.Add(n); return n;
        }
        void Each(ListView lv, Action<string> act)
        {
            foreach (ListViewItem it in lv.SelectedItems) if (it.Tag != null) act((string)it.Tag);
        }

        void ModeChanged(object s, EventArgs e)
        {
            if (!((RadioButton)s).Checked) return;
            eng.SetMode(rbNet.Checked ? "internet" : "lan");
        }
        void ToggleServer()
        {
            if (eng.Running) { eng.Stop(); btnStart.Text = "Start"; btnStart.BackColor = Color.FromArgb(40, 110, 60); }
            else { eng.Start(); btnStart.Text = "Stop"; btnStart.BackColor = Color.FromArgb(120, 40, 40); }
        }
        void Help_Cf()
        {
            MessageBox.Show(
                "Internet mode uses Cloudflare's free quick tunnel.\r\n\r\n" +
                "Put cloudflared.exe next to this program (or on PATH).\r\n" +
                "Get it (single file, no install, no admin) from:\r\n" +
                "https://github.com/cloudflare/cloudflared/releases/latest\r\n" +
                "  -> cloudflared-windows-amd64.exe  (rename to cloudflared.exe)\r\n\r\n" +
                "Then select Internet again.",
                "Get cloudflared", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        void LoadFromState()
        {
            txtPw.Text = eng.State.Password;
            rbLan.Checked = eng.State.Mode == "lan"; rbNet.Checked = eng.State.Mode == "internet";
            chkAuto.Checked = eng.State.AutoApprove; chkView.Checked = eng.Set.ViewOnly;
            numFps.Value = Clamp(eng.Set.Fps, 1, 30); numQ.Value = Clamp(eng.Set.Quality, 10, 95);
            numScale.Value = Clamp(eng.Set.ScalePct, 20, 100);
            FillLists();
        }
        decimal Clamp(int v, int lo, int hi) { if (v < lo) v = lo; if (v > hi) v = hi; return v; }

        void FillLists()
        {
            lock (eng.Lock)
            {
                lvPending.Items.Clear();
                foreach (var kv in eng.State.Pending)
                {
                    var it = new ListViewItem(new string[] { kv.Value.Label, kv.Value.Ip, kv.Value.Added }); it.Tag = kv.Key; lvPending.Items.Add(it);
                }
                lvTrusted.Items.Clear();
                foreach (var kv in eng.State.Trusted)
                {
                    var it = new ListViewItem(new string[] { kv.Value.Label, kv.Value.Ip, kv.Value.Added }); it.Tag = kv.Key; lvTrusted.Items.Add(it);
                }
            }
        }

        int lastLog = 0, lastPend = -1, lastTrust = -1;
        void Refresh_(object s, EventArgs e)
        {
            lblStatus.Text = eng.Running ? "●  Running" : "●  Stopped";
            lblStatus.ForeColor = eng.Running ? Color.FromArgb(80, 200, 120) : Color.IndianRed;

            txtLan.Lines = eng.LanUrls().ToArray();

            if (eng.State.Mode == "internet")
            {
                string st = eng.Tunnel.Status;
                if (st == "running") { lblNetStatus.Text = "● online"; lblNetStatus.ForeColor = Color.FromArgb(80, 200, 120); lblPubUrl.Text = eng.Tunnel.Url; }
                else if (st == "starting") { lblNetStatus.Text = "starting tunnel..."; lblNetStatus.ForeColor = Color.Orange; lblPubUrl.Text = ""; }
                else if (st == "missing") { lblNetStatus.Text = "cloudflared missing"; lblNetStatus.ForeColor = Color.IndianRed; lblPubUrl.Text = "Click 'Get cloudflared'"; }
                else { lblNetStatus.Text = st; lblNetStatus.ForeColor = Color.IndianRed; lblPubUrl.Text = ""; }
            }
            else { lblNetStatus.Text = "LAN mode"; lblNetStatus.ForeColor = Color.Gray; lblPubUrl.Text = ""; }

            int pc, tc;
            lock (eng.Lock) { pc = eng.State.Pending.Count; tc = eng.State.Trusted.Count; }
            if (pc != lastPend || tc != lastTrust) { FillLists(); lastPend = pc; lastTrust = tc; }

            string[] lg = eng.DrainLog();
            if (lg.Length != lastLog) { txtLog.Lines = lg; lastLog = lg.Length; txtLog.SelectionStart = txtLog.TextLength; txtLog.ScrollToCaret(); }
        }
    }

    static class Program
    {
        // Base64 of the browser viewer page served to remote users.
        public const string VIEWER_B64 = "PCFkb2N0eXBlIGh0bWw+PGh0bWwgbGFuZz0iZW4iPjxoZWFkPjxtZXRhIGNoYXJzZXQ9InV0Zi04Ij4KPG1ldGEgbmFtZT0idmlld3BvcnQiIGNvbnRlbnQ9IndpZHRoPWRldmljZS13aWR0aCwgaW5pdGlhbC1zY2FsZT0xIj48dGl0bGU+UmVtb3RlIERlc2t0b3A8L3RpdGxlPgo8c3R5bGU+CiA6cm9vdHstLWJnOiMwYjBkMTA7LS1mZzojZThlYWVkOy0tYWNjZW50OiMzYjgyZjY7LS1iYXI6IzE1MTgxZDstLW11dDojOWFhMGE2fQogKntib3gtc2l6aW5nOmJvcmRlci1ib3h9aHRtbCxib2R5e21hcmdpbjowO2hlaWdodDoxMDAlO2JhY2tncm91bmQ6dmFyKC0tYmcpO2NvbG9yOnZhcigtLWZnKTsKICBmb250LWZhbWlseTpzeXN0ZW0tdWksU2Vnb2UgVUksc2Fucy1zZXJpZjtvdmVyZmxvdzpoaWRkZW59CiAjbG9naW57ZGlzcGxheTpmbGV4O2FsaWduLWl0ZW1zOmNlbnRlcjtqdXN0aWZ5LWNvbnRlbnQ6Y2VudGVyO2hlaWdodDoxMDAlfQogLmNhcmR7YmFja2dyb3VuZDp2YXIoLS1iYXIpO3BhZGRpbmc6MjhweCAzMnB4O2JvcmRlci1yYWRpdXM6MTRweDtib3gtc2hhZG93OjAgMTJweCA0MHB4IHJnYmEoMCwwLDAsLjUpO3dpZHRoOjMyMHB4fQogaDF7Zm9udC1zaXplOjE4cHg7bWFyZ2luOjAgMCA0cHh9LnN1Yntmb250LXNpemU6MTNweDtjb2xvcjp2YXIoLS1tdXQpO21hcmdpbjowIDAgMThweH0KIGlucHV0e3dpZHRoOjEwMCU7cGFkZGluZzoxMHB4IDEycHg7Ym9yZGVyLXJhZGl1czo4cHg7Ym9yZGVyOjFweCBzb2xpZCAjMmEyZjM3O2JhY2tncm91bmQ6IzBiMGQxMDtjb2xvcjp2YXIoLS1mZyk7Zm9udC1zaXplOjE0cHg7bWFyZ2luLWJvdHRvbToxMnB4fQogYnV0dG9uLC5idG57YmFja2dyb3VuZDp2YXIoLS1hY2NlbnQpO2NvbG9yOiNmZmY7Ym9yZGVyOjA7cGFkZGluZzo4cHggMTJweDtib3JkZXItcmFkaXVzOjhweDtmb250LXNpemU6MTNweDtjdXJzb3I6cG9pbnRlcn0KIC5idG4uc2Vje2JhY2tncm91bmQ6IzJhMmYzN30uZXJye2NvbG9yOiNmODcxNzE7Zm9udC1zaXplOjEycHg7bWluLWhlaWdodDoxNnB4fQogI2FwcHtkaXNwbGF5Om5vbmU7ZmxleC1kaXJlY3Rpb246Y29sdW1uO2hlaWdodDoxMDAlfQogI2JhcntkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2dhcDoxMHB4O2JhY2tncm91bmQ6dmFyKC0tYmFyKTtwYWRkaW5nOjZweCAxMHB4O2ZvbnQtc2l6ZToxMnB4O2ZsZXg6MCAwIGF1dG99CiAjYmFyIC5kb3R7d2lkdGg6OXB4O2hlaWdodDo5cHg7Ym9yZGVyLXJhZGl1czo1MCU7YmFja2dyb3VuZDojZjU5ZTBifSNiYXIgLmRvdC5va3tiYWNrZ3JvdW5kOiMyMmM1NWV9I2JhciAuc3B7ZmxleDoxfQogI2JhciBsYWJlbHtjb2xvcjp2YXIoLS1tdXQpO2Rpc3BsYXk6ZmxleDthbGlnbi1pdGVtczpjZW50ZXI7Z2FwOjRweH0KICNzdGFnZXtmbGV4OjE7b3ZlcmZsb3c6YXV0bztkaXNwbGF5OmZsZXg7YWxpZ24taXRlbXM6Y2VudGVyO2p1c3RpZnktY29udGVudDpjZW50ZXI7YmFja2dyb3VuZDojMDAwfQogI3NjcmVlbnttYXgtd2lkdGg6MTAwJTttYXgtaGVpZ2h0OjEwMCU7ZGlzcGxheTpibG9jaztjdXJzb3I6bm9uZX0KICNkcmF3ZXJ7cG9zaXRpb246Zml4ZWQ7cmlnaHQ6MDt0b3A6MDtoZWlnaHQ6MTAwJTt3aWR0aDozMzBweDtiYWNrZ3JvdW5kOnZhcigtLWJhcik7CiAgYm94LXNoYWRvdzotOHB4IDAgMzBweCByZ2JhKDAsMCwwLC41KTt0cmFuc2Zvcm06dHJhbnNsYXRlWCgxMDAlKTt0cmFuc2l0aW9uOnRyYW5zZm9ybSAuMnM7cGFkZGluZzoxNnB4O292ZXJmbG93OmF1dG87ei1pbmRleDo1fQogI2RyYXdlci5vcGVue3RyYW5zZm9ybTp0cmFuc2xhdGVYKDApfQogI2RyYXdlciBoMntmb250LXNpemU6MTNweDt0ZXh0LXRyYW5zZm9ybTp1cHBlcmNhc2U7bGV0dGVyLXNwYWNpbmc6LjA0ZW07Y29sb3I6dmFyKC0tbXV0KTttYXJnaW46MThweCAwIDhweH0KIHRleHRhcmVhe3dpZHRoOjEwMCU7aGVpZ2h0OjExMHB4O2JhY2tncm91bmQ6IzBiMGQxMDtjb2xvcjp2YXIoLS1mZyk7Ym9yZGVyOjFweCBzb2xpZCAjMmEyZjM3O2JvcmRlci1yYWRpdXM6OHB4O3BhZGRpbmc6OHB4O2ZvbnQtc2l6ZToxM3B4O3Jlc2l6ZTp2ZXJ0aWNhbH0KIC5maWxlbGlzdHtmb250LXNpemU6MTNweH0uZmlsZWxpc3QgLnJvd3tkaXNwbGF5OmZsZXg7anVzdGlmeS1jb250ZW50OnNwYWNlLWJldHdlZW47YWxpZ24taXRlbXM6Y2VudGVyO3BhZGRpbmc6NnB4IDA7Ym9yZGVyLWJvdHRvbToxcHggc29saWQgIzIyMjYyZH0KIC5maWxlbGlzdCBhe2NvbG9yOnZhcigtLWFjY2VudCk7dGV4dC1kZWNvcmF0aW9uOm5vbmU7d29yZC1icmVhazpicmVhay1hbGx9Lm11dGVke2NvbG9yOnZhcigtLW11dCk7Zm9udC1zaXplOjEycHh9CiAuZHJhd2hlYWR7ZGlzcGxheTpmbGV4O2p1c3RpZnktY29udGVudDpzcGFjZS1iZXR3ZWVuO2FsaWduLWl0ZW1zOmNlbnRlcn0KPC9zdHlsZT48L2hlYWQ+PGJvZHk+CiA8ZGl2IGlkPSJsb2dpbiI+PGRpdiBjbGFzcz0iY2FyZCI+PGgxPlJlbW90ZSBEZXNrdG9wPC9oMT4KICA8cCBjbGFzcz0ic3ViIj5FbnRlciB0aGUgYWNjZXNzIHBhc3N3b3JkIHNob3duIG9uIHRoZSBob3N0LjwvcD4KICA8aW5wdXQgaWQ9InB3IiB0eXBlPSJwYXNzd29yZCIgcGxhY2Vob2xkZXI9IlBhc3N3b3JkIiBhdXRvY29tcGxldGU9Im9mZiI+CiAgPGRpdiBjbGFzcz0iZXJyIiBpZD0ibG9naW5FcnIiPjwvZGl2PjxidXR0b24gaWQ9ImNvbm5lY3RCdG4iIHN0eWxlPSJ3aWR0aDoxMDAlIj5Db25uZWN0PC9idXR0b24+PC9kaXY+PC9kaXY+CiA8ZGl2IGlkPSJhcHAiPjxkaXYgaWQ9ImJhciI+PHNwYW4gY2xhc3M9ImRvdCIgaWQ9ImRvdCI+PC9zcGFuPjxzcGFuIGlkPSJzdGF0dXMiPmNvbm5lY3RpbmcuLi48L3NwYW4+CiAgIDxzcGFuIGNsYXNzPSJzcCI+PC9zcGFuPjxsYWJlbD5WaWV3IG9ubHkgPGlucHV0IHR5cGU9ImNoZWNrYm94IiBpZD0idmlld09ubHkiPjwvbGFiZWw+CiAgIDxzcGFuIGNsYXNzPSJidG4gc2VjIiBpZD0idG9vbHNCdG4iPlRvb2xzPC9zcGFuPgogICA8c3BhbiBjbGFzcz0iYnRuIHNlYyIgaWQ9ImZzQnRuIj5GdWxsc2NyZWVuPC9zcGFuPgogICA8c3BhbiBjbGFzcz0iYnRuIHNlYyIgaWQ9ImNhZEJ0biIgdGl0bGU9IkN0cmwrQWx0K0RlbCBjYW5ub3QgYmUgaW5qZWN0ZWQgd2l0aG91dCBzeXN0ZW0gcmlnaHRzIj5DdHJsK0FsdCtFbmQ8L3NwYW4+PC9kaXY+CiAgPGRpdiBpZD0ic3RhZ2UiPjxpbWcgaWQ9InNjcmVlbiIgZHJhZ2dhYmxlPSJmYWxzZSI+PC9kaXY+PC9kaXY+CiA8ZGl2IGlkPSJkcmF3ZXIiPgogIDxkaXYgY2xhc3M9ImRyYXdoZWFkIj48c3Ryb25nPlRvb2xzPC9zdHJvbmc+PHNwYW4gY2xhc3M9ImJ0biBzZWMiIGlkPSJjbG9zZURyYXdlciI+Q2xvc2U8L3NwYW4+PC9kaXY+CiAgPGgyPkNsaXBib2FyZDwvaDI+CiAgPHRleHRhcmVhIGlkPSJjbGlwIiBwbGFjZWhvbGRlcj0iU2hhcmVkIGNsaXBib2FyZCB0ZXh0Li4uIj48L3RleHRhcmVhPgogIDxkaXYgc3R5bGU9ImRpc3BsYXk6ZmxleDtnYXA6OHB4O21hcmdpbi10b3A6OHB4Ij4KICAgPGJ1dHRvbiBjbGFzcz0iYnRuIHNlYyIgaWQ9ImNsaXBQdWxsIj5QdWxsIGZyb20gaG9zdDwvYnV0dG9uPgogICA8YnV0dG9uIGNsYXNzPSJidG4iIGlkPSJjbGlwUHVzaCI+UHVzaCB0byBob3N0PC9idXR0b24+PC9kaXY+CiAgPGgyPkZpbGVzPC9oMj4KICA8ZGl2IGNsYXNzPSJtdXRlZCI+U2hhcmVkIGZvbGRlciBvbiB0aGUgaG9zdC48L2Rpdj4KICA8ZGl2IGNsYXNzPSJmaWxlbGlzdCIgaWQ9ImZpbGVzIj48L2Rpdj4KICA8ZGl2IHN0eWxlPSJtYXJnaW4tdG9wOjhweCI+PGlucHV0IHR5cGU9ImZpbGUiIGlkPSJmaWxlSW5wdXQiIHN0eWxlPSJmb250LXNpemU6MTJweCI+CiAgIDxidXR0b24gY2xhc3M9ImJ0biIgaWQ9InVwbG9hZEJ0biIgc3R5bGU9Im1hcmdpbi10b3A6NnB4Ij5VcGxvYWQgdG8gaG9zdDwvYnV0dG9uPjwvZGl2PgogPC9kaXY+CjxzY3JpcHQ+CmNvbnN0ICQ9cz0+ZG9jdW1lbnQucXVlcnlTZWxlY3RvcihzKTsKYXN5bmMgZnVuY3Rpb24gc2Vzc2lvbigpe3RyeXtyZXR1cm4gYXdhaXQgKGF3YWl0IGZldGNoKCIvc2Vzc2lvbiIse2NhY2hlOiJuby1zdG9yZSJ9KSkuanNvbigpO31jYXRjaChlKXtyZXR1cm57YXV0aGVkOmZhbHNlfTt9fQphc3luYyBmdW5jdGlvbiBib290KCl7Y29uc3Qgcz1hd2FpdCBzZXNzaW9uKCk7IGlmKHMuYXV0aGVkKXtzaG93QXBwKHMpO31lbHNleyQoIiNsb2dpbiIpLnN0eWxlLmRpc3BsYXk9ImZsZXgiO319CiQoIiNjb25uZWN0QnRuIikub25jbGljaz1sb2dpbjsgJCgiI3B3IikuYWRkRXZlbnRMaXN0ZW5lcigia2V5ZG93biIsZT0+e2lmKGUua2V5PT09IkVudGVyIilsb2dpbigpO30pOwphc3luYyBmdW5jdGlvbiBsb2dpbigpe2NvbnN0IHB3PSQoIiNwdyIpLnZhbHVlLnRyaW0oKTsgaWYoIXB3KXJldHVybjsgJCgiI2xvZ2luRXJyIikudGV4dENvbnRlbnQ9IiI7ICQoIiNjb25uZWN0QnRuIikuZGlzYWJsZWQ9dHJ1ZTsKIHRyeXtjb25zdCByPWF3YWl0IGZldGNoKCIvYXV0aCIse21ldGhvZDoiUE9TVCIsYm9keTpwd30pOyBpZighci5vayl0aHJvdyBuZXcgRXJyb3Ioci5zdGF0dXM9PT00Mjk/IlRvbyBtYW55IGF0dGVtcHRzIjoiV3JvbmcgcGFzc3dvcmQiKTsKICBjb25zdCBzPWF3YWl0IHNlc3Npb24oKTsgc2hvd0FwcChzKTt9Y2F0Y2goZSl7JCgiI2xvZ2luRXJyIikudGV4dENvbnRlbnQ9ZS5tZXNzYWdlfHwiRmFpbGVkIjsgJCgiI2Nvbm5lY3RCdG4iKS5kaXNhYmxlZD1mYWxzZTt9fQpmdW5jdGlvbiBzaG93QXBwKHMpeyQoIiNsb2dpbiIpLnN0eWxlLmRpc3BsYXk9Im5vbmUiOyAkKCIjYXBwIikuc3R5bGUuZGlzcGxheT0iZmxleCI7CiAkKCIjdmlld09ubHkiKS5jaGVja2VkPSEhcy52aWV3T25seTsgJCgiI3ZpZXdPbmx5IikuZGlzYWJsZWQ9ISFzLnZpZXdPbmx5OyBiZWdpblN0cmVhbSgpOyB3aXJlSW5wdXQoKTsgd2lyZVRvb2xzKCk7fQpmdW5jdGlvbiBiZWdpblN0cmVhbSgpe2NvbnN0IGltZz0kKCIjc2NyZWVuIik7CiBpbWcub25sb2FkPSgpPT57JCgiI2RvdCIpLmNsYXNzTGlzdC5hZGQoIm9rIik7JCgiI3N0YXR1cyIpLnRleHRDb250ZW50PSJjb25uZWN0ZWQiO307CiBpbWcub25lcnJvcj0oKT0+eyQoIiNkb3QiKS5jbGFzc0xpc3QucmVtb3ZlKCJvayIpOyQoIiNzdGF0dXMiKS50ZXh0Q29udGVudD0icmVjb25uZWN0aW5nLi4uIjtzZXRUaW1lb3V0KCgpPT5pbWcuc3JjPSIvc3RyZWFtP189IitEYXRlLm5vdygpLDEwMDApO307CiBpbWcuc3JjPSIvc3RyZWFtP189IitEYXRlLm5vdygpO30KbGV0IHNlbmRpbmc9ZmFsc2UscXVldWU9W107CmFzeW5jIGZ1bmN0aW9uIGZsdXNoKCl7aWYoc2VuZGluZ3x8IXF1ZXVlLmxlbmd0aClyZXR1cm47c2VuZGluZz10cnVlO2NvbnN0IGI9cXVldWU7cXVldWU9W107CiB0cnl7YXdhaXQgZmV0Y2goIi9pbnB1dCIse21ldGhvZDoiUE9TVCIsYm9keTpKU09OLnN0cmluZ2lmeShiKX0pO31jYXRjaChlKXt9c2VuZGluZz1mYWxzZTtpZihxdWV1ZS5sZW5ndGgpZmx1c2goKTt9CmZ1bmN0aW9uIHNlbmQoZXYpe2lmKCQoIiN2aWV3T25seSIpLmNoZWNrZWQpcmV0dXJuO3F1ZXVlLnB1c2goZXYpO2lmKHF1ZXVlLmxlbmd0aD41MClxdWV1ZS5zaGlmdCgpO2ZsdXNoKCk7fQpmdW5jdGlvbiBjb29yZHMoZSl7Y29uc3QgaW1nPSQoIiNzY3JlZW4iKSxyPWltZy5nZXRCb3VuZGluZ0NsaWVudFJlY3QoKTsKIHJldHVybnt4Ok1hdGgubWF4KDAsTWF0aC5taW4oMSwoZS5jbGllbnRYLXIubGVmdCkvci53aWR0aCkpLHk6TWF0aC5tYXgoMCxNYXRoLm1pbigxLChlLmNsaWVudFktci50b3ApL3IuaGVpZ2h0KSl9O30KZnVuY3Rpb24gd2lyZUlucHV0KCl7Y29uc3QgaW1nPSQoIiNzY3JlZW4iKTtsZXQgbGFzdD0wOwogaW1nLmFkZEV2ZW50TGlzdGVuZXIoIm1vdXNlbW92ZSIsZT0+e2NvbnN0IG49cGVyZm9ybWFuY2Uubm93KCk7aWYobi1sYXN0PDI1KXJldHVybjtsYXN0PW47Y29uc3QgYz1jb29yZHMoZSk7c2VuZCh7dDoibW92ZSIseDpjLngseTpjLnl9KTt9KTsKIGltZy5hZGRFdmVudExpc3RlbmVyKCJtb3VzZWRvd24iLGU9PntlLnByZXZlbnREZWZhdWx0KCk7Y29uc3QgYz1jb29yZHMoZSk7c2VuZCh7dDoiZG93biIseDpjLngseTpjLnksYjplLmJ1dHRvbn0pO30pOwogd2luZG93LmFkZEV2ZW50TGlzdGVuZXIoIm1vdXNldXAiLGU9Pntjb25zdCBjPWNvb3JkcyhlKTtzZW5kKHt0OiJ1cCIseDpjLngseTpjLnksYjplLmJ1dHRvbn0pO30pOwogaW1nLmFkZEV2ZW50TGlzdGVuZXIoImNvbnRleHRtZW51IixlPT5lLnByZXZlbnREZWZhdWx0KCkpOwogaW1nLmFkZEV2ZW50TGlzdGVuZXIoIndoZWVsIixlPT57ZS5wcmV2ZW50RGVmYXVsdCgpO3NlbmQoe3Q6IndoZWVsIixkeTotZS5kZWx0YVksZHg6LWUuZGVsdGFYfSk7fSx7cGFzc2l2ZTpmYWxzZX0pOwogd2luZG93LmFkZEV2ZW50TGlzdGVuZXIoImtleWRvd24iLGU9PntpZigkKCIjYXBwIikuc3R5bGUuZGlzcGxheT09PSJub25lIilyZXR1cm47aWYoJCgiI2NsaXAiKT09PWRvY3VtZW50LmFjdGl2ZUVsZW1lbnQpcmV0dXJuO2UucHJldmVudERlZmF1bHQoKTsKICBpZihlLmtleS5sZW5ndGg9PT0xJiYhZS5jdHJsS2V5JiYhZS5hbHRLZXkmJiFlLm1ldGFLZXkpc2VuZCh7dDoiY2hhciIsYzplLmtleX0pO2Vsc2Ugc2VuZCh7dDoia2V5IixrOmUua2V5LGRvd246dHJ1ZX0pO30pOwogd2luZG93LmFkZEV2ZW50TGlzdGVuZXIoImtleXVwIixlPT57aWYoJCgiI2FwcCIpLnN0eWxlLmRpc3BsYXk9PT0ibm9uZSIpcmV0dXJuO2lmKCQoIiNjbGlwIik9PT1kb2N1bWVudC5hY3RpdmVFbGVtZW50KXJldHVybjtlLnByZXZlbnREZWZhdWx0KCk7CiAgaWYoIShlLmtleS5sZW5ndGg9PT0xJiYhZS5jdHJsS2V5JiYhZS5hbHRLZXkmJiFlLm1ldGFLZXkpKXNlbmQoe3Q6ImtleSIsazplLmtleSxkb3duOmZhbHNlfSk7fSk7CiAkKCIjZnNCdG4iKS5vbmNsaWNrPSgpPT5kb2N1bWVudC5mdWxsc2NyZWVuRWxlbWVudD9kb2N1bWVudC5leGl0RnVsbHNjcmVlbigpOmRvY3VtZW50LmRvY3VtZW50RWxlbWVudC5yZXF1ZXN0RnVsbHNjcmVlbigpOwogJCgiI2NhZEJ0biIpLm9uY2xpY2s9KCk9PntbIkNvbnRyb2wiLCJBbHQiLCJFbmQiXS5mb3JFYWNoKGs9PnNlbmQoe3Q6ImtleSIsazprLGRvd246dHJ1ZX0pKTtbIkVuZCIsIkFsdCIsIkNvbnRyb2wiXS5mb3JFYWNoKGs9PnNlbmQoe3Q6ImtleSIsazprLGRvd246ZmFsc2V9KSk7fTt9CmZ1bmN0aW9uIHdpcmVUb29scygpewogJCgiI3Rvb2xzQnRuIikub25jbGljaz0oKT0+JCgiI2RyYXdlciIpLmNsYXNzTGlzdC50b2dnbGUoIm9wZW4iKTsKICQoIiNjbG9zZURyYXdlciIpLm9uY2xpY2s9KCk9PiQoIiNkcmF3ZXIiKS5jbGFzc0xpc3QucmVtb3ZlKCJvcGVuIik7CiAkKCIjY2xpcFB1bGwiKS5vbmNsaWNrPWFzeW5jKCk9Pnt0cnl7JCgiI2NsaXAiKS52YWx1ZT0oYXdhaXQgKGF3YWl0IGZldGNoKCIvY2xpcGJvYXJkIix7Y2FjaGU6Im5vLXN0b3JlIn0pKS5qc29uKCkpLnRleHQ7fWNhdGNoKGUpe319OwogJCgiI2NsaXBQdXNoIikub25jbGljaz0oKT0+ZmV0Y2goIi9jbGlwYm9hcmQiLHttZXRob2Q6IlBPU1QiLGJvZHk6SlNPTi5zdHJpbmdpZnkoe3RleHQ6JCgiI2NsaXAiKS52YWx1ZX0pfSk7CiAkKCIjdXBsb2FkQnRuIikub25jbGljaz11cGxvYWRGaWxlOyByZWZyZXNoRmlsZXMoKTt9CmFzeW5jIGZ1bmN0aW9uIHJlZnJlc2hGaWxlcygpe3RyeXtjb25zdCBkPWF3YWl0IChhd2FpdCBmZXRjaCgiL2ZpbGVzIix7Y2FjaGU6Im5vLXN0b3JlIn0pKS5qc29uKCk7CiBjb25zdCBlbD0kKCIjZmlsZXMiKTtlbC5pbm5lckhUTUw9IiI7KGQuZmlsZXN8fFtdKS5mb3JFYWNoKGY9Pntjb25zdCByb3c9ZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgiZGl2Iik7cm93LmNsYXNzTmFtZT0icm93IjsKICBjb25zdCBhPWRvY3VtZW50LmNyZWF0ZUVsZW1lbnQoImEiKTthLmhyZWY9Ii9kb3dubG9hZD9uYW1lPSIrZW5jb2RlVVJJQ29tcG9uZW50KGYubmFtZSk7YS50ZXh0Q29udGVudD1mLm5hbWU7YS5kb3dubG9hZD1mLm5hbWU7CiAgY29uc3Qgc3o9ZG9jdW1lbnQuY3JlYXRlRWxlbWVudCgic3BhbiIpO3N6LmNsYXNzTmFtZT0ibXV0ZWQiO3N6LnRleHRDb250ZW50PU1hdGgubWF4KDEsTWF0aC5yb3VuZChmLnNpemUvMTAyNCkpKyIgS0IiOwogIHJvdy5hcHBlbmRDaGlsZChhKTtyb3cuYXBwZW5kQ2hpbGQoc3opO2VsLmFwcGVuZENoaWxkKHJvdyk7fSk7CiBpZighZC5maWxlc3x8IWQuZmlsZXMubGVuZ3RoKWVsLmlubmVySFRNTD0nPGRpdiBjbGFzcz0ibXV0ZWQiPk5vIGZpbGVzIHlldC48L2Rpdj4nO31jYXRjaChlKXt9fQphc3luYyBmdW5jdGlvbiB1cGxvYWRGaWxlKCl7Y29uc3QgZj0kKCIjZmlsZUlucHV0IikuZmlsZXNbMF07aWYoIWYpcmV0dXJuOwogYXdhaXQgZmV0Y2goIi91cGxvYWQ/bmFtZT0iK2VuY29kZVVSSUNvbXBvbmVudChmLm5hbWUpLHttZXRob2Q6IlBPU1QiLGJvZHk6YXdhaXQgZi5hcnJheUJ1ZmZlcigpfSk7CiAkKCIjZmlsZUlucHV0IikudmFsdWU9IiI7cmVmcmVzaEZpbGVzKCk7fQpib290KCk7Cjwvc2NyaXB0PjwvYm9keT48L2h0bWw+Cg==";

        [STAThread]
        static void Main()
        {
            try { Native.SetProcessDPIAware(); } catch { }
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new MainForm());
        }
    }
}
