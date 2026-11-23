// Engine: persisted state, auth (password + trusted computers), and the HTTP
// routes used by the browser viewer. Same protocol as the Windows host.

import Foundation
import AppKit
import ApplicationServices
import CryptoKit

// ===================================================================
// Persisted state
// ===================================================================
struct DeviceInfo: Codable, Equatable {
    var label: String
    var ip: String
    var added: String
}

struct HostSettings: Codable, Equatable {
    var fps = 12
    var quality = 55
    var scalePct = 100
    var viewOnly = false
    var ctrlAsCmd = true          // map a Windows/Linux viewer's Ctrl to ⌘
    var displayID: UInt32 = 0     // 0 = main display
}

extension HostSettings {
    init(from d: Decoder) throws {
        self.init()
        let c = try d.container(keyedBy: CodingKeys.self)
        fps = try c.decodeIfPresent(Int.self, forKey: .fps) ?? fps
        quality = try c.decodeIfPresent(Int.self, forKey: .quality) ?? quality
        scalePct = try c.decodeIfPresent(Int.self, forKey: .scalePct) ?? scalePct
        viewOnly = try c.decodeIfPresent(Bool.self, forKey: .viewOnly) ?? viewOnly
        ctrlAsCmd = try c.decodeIfPresent(Bool.self, forKey: .ctrlAsCmd) ?? ctrlAsCmd
        displayID = try c.decodeIfPresent(UInt32.self, forKey: .displayID) ?? displayID
    }
}

struct AppState: Codable {
    var password: String
    var secretHex: String
    var mode: String              // "lan" | "internet"
    var autoApprove: Bool
    var settings: HostSettings
    var trusted: [String: DeviceInfo]
    var pending: [String: DeviceInfo]

    static func fresh() -> AppState {
        AppState(password: Engine.genPassword(), secretHex: Engine.randHex(32), mode: "lan",
                 autoApprove: false, settings: HostSettings(), trusted: [:], pending: [:])
    }
}

extension AppState {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let f = AppState.fresh()
        password = try c.decodeIfPresent(String.self, forKey: .password) ?? f.password
        secretHex = try c.decodeIfPresent(String.self, forKey: .secretHex) ?? f.secretHex
        mode = try c.decodeIfPresent(String.self, forKey: .mode) ?? f.mode
        autoApprove = try c.decodeIfPresent(Bool.self, forKey: .autoApprove) ?? f.autoApprove
        settings = try c.decodeIfPresent(HostSettings.self, forKey: .settings) ?? f.settings
        trusted = try c.decodeIfPresent([String: DeviceInfo].self, forKey: .trusted) ?? [:]
        pending = try c.decodeIfPresent([String: DeviceInfo].self, forKey: .pending) ?? [:]
        if password.isEmpty { password = f.password }
        if Engine.hexToBytes(secretHex) == nil { secretHex = f.secretHex }
        if mode != "lan" && mode != "internet" { mode = "lan" }
    }
}

// ===================================================================
// Engine
// ===================================================================
final class Engine {
    static let shared = Engine()

    static let supportDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let d = base.appendingPathComponent("RemoteDesktopHost", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    static var statePath: URL { supportDir.appendingPathComponent("rd_state.json") }

    let port: UInt16 = 8765
    let shareDir: URL
    let tunnel: Tunnel
    let capture = ScreenCapture()
    let input = InputInjector()

    private let server = HTTPServer()
    private let lock = NSLock()
    private var state: AppState
    private let key: SymmetricKey
    private let runFlag = Flag()
    private let logLock = NSLock()
    private var logLines: [String] = []
    private let throttleLock = NSLock()
    private var throttle: [String: [Date]] = [:]
    private var warnedAX = false

    private lazy var viewerHTML: Data = {
        if let u = Bundle.main.url(forResource: "viewer", withExtension: "html"), let d = try? Data(contentsOf: u) {
            return d
        }
        return Data("<!doctype html><p>viewer.html is missing from the app bundle (Contents/Resources).</p>".utf8)
    }()

    private init() {
        var st = Engine.loadState()
        let secret = Engine.hexToBytes(st.secretHex) ?? {
            st.secretHex = Engine.randHex(32)
            return Engine.hexToBytes(st.secretHex)!
        }()
        state = st
        key = SymmetricKey(data: secret)
        shareDir = Engine.supportDir.appendingPathComponent("shared", isDirectory: true)
        try? FileManager.default.createDirectory(at: shareDir, withIntermediateDirectories: true)
        tunnel = Tunnel(port: port)

        capture.settingsProvider = { [unowned self] in self.settings }
        capture.log = { [unowned self] s in self.log(s) }
        input.boundsProvider = { [unowned self] in self.capture.displayBounds }
        server.handler = { [unowned self] c in self.handle(c) }
        save()
    }

    // ---- state ----
    var running: Bool { runFlag.value }
    var snapshot: AppState { lock.lock(); defer { lock.unlock() }; return state }
    var settings: HostSettings { lock.lock(); defer { lock.unlock() }; return state.settings }

    func mutate(_ f: (inout AppState) -> Void) {
        lock.lock(); f(&state); lock.unlock()
        save()
    }

    func updateSettings(_ f: (inout HostSettings) -> Void) {
        lock.lock()
        let old = state.settings
        f(&state.settings)
        let new = state.settings
        lock.unlock()
        save()
        if old.fps != new.fps || old.scalePct != new.scalePct || old.displayID != new.displayID {
            capture.reconfigure()
        }
    }

    private static func loadState() -> AppState {
        guard let d = try? Data(contentsOf: statePath),
              let s = try? JSONDecoder().decode(AppState.self, from: d) else { return AppState.fresh() }
        return s
    }

    func save() {
        let s = snapshot
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let d = try? enc.encode(s) else { return }
        try? d.write(to: Engine.statePath, options: [.atomic])
        // the file holds the password and signing secret: keep it private
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Engine.statePath.path)
    }

    // ---- log ----
    func log(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        logLock.lock()
        logLines.append(f.string(from: Date()) + "  " + s)
        if logLines.count > 300 { logLines.removeFirst(logLines.count - 300) }
        logLock.unlock()
    }
    func logSnapshot() -> [String] { logLock.lock(); defer { logLock.unlock() }; return logLines }

    // ---- crypto helpers ----
    static func randHex(_ n: Int) -> String {
        (0..<n).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
    static func hexToBytes(_ hex: String) -> [UInt8]? {
        let chars = Array(hex.utf8)
        guard !chars.isEmpty, chars.count % 2 == 0 else { return nil }
        var out = [UInt8]()
        out.reserveCapacity(chars.count / 2)
        var i = 0
        while i < chars.count {
            guard let b = UInt8(String(decoding: chars[i..<i + 2], as: UTF8.self), radix: 16) else { return nil }
            out.append(b)
            i += 2
        }
        return out
    }
    static func genPassword() -> String {
        let al = Array("23456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz")
        return String((0..<10).map { _ in al.randomElement()! })
    }
    private func mac(_ v: String) -> String {
        let m = HMAC<SHA256>.authenticationCode(for: Data(v.utf8), using: key)
        return String(m.map { String(format: "%02x", $0) }.joined().prefix(24))
    }
    private func sign(_ v: String) -> String { v + "." + mac(v) }
    private func verify(_ token: String?) -> String? {
        guard let t = token, let i = t.lastIndex(of: ".") else { return nil }
        let v = String(t[..<i]), m = String(t[t.index(after: i)...])
        return Engine.slowEquals(m, mac(v)) ? v : nil
    }
    static func slowEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var r: UInt8 = 0
        for i in 0..<x.count { r |= x[i] ^ y[i] }
        return r == 0
    }

    // ---- URLs ----
    func lanURLs() -> [String] {
        var out: [String] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&ifap) == 0 {
            var p = ifap
            while let cur = p {
                let ifa = cur.pointee
                if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                   (ifa.ifa_flags & UInt32(IFF_LOOPBACK)) == 0, (ifa.ifa_flags & UInt32(IFF_UP)) != 0 {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = String(cString: host)
                        let u = "http://\(ip):\(port)/"
                        if !ip.hasPrefix("169.254.") && !out.contains(u) { out.append(u) }
                    }
                }
                p = ifa.ifa_next
            }
            freeifaddrs(ifap)
        }
        out.append("http://localhost:\(port)/")
        return out
    }

    // ---- lifecycle ----
    func start() {
        if running { return }
        do { try server.start(port: port) }
        catch { log("Could not start server: \(error.localizedDescription)"); return }
        runFlag.value = true
        capture.start()
        let mode = snapshot.mode
        if mode == "internet" { tunnel.start() }
        log("Server started on port \(port) (\(mode))")
    }

    func stop() {
        if !running { return }
        runFlag.value = false
        server.stop()
        capture.stop()
        tunnel.stop()
        log("Server stopped")
    }

    func setMode(_ mode: String) {
        mutate { $0.mode = mode }
        if mode == "internet" { if running { tunnel.start() } } else { tunnel.stop() }
        log("Mode: " + mode)
    }

    // ---- trusted management (GUI) ----
    func approve(_ id: String) {
        mutate { s in if let d = s.pending.removeValue(forKey: id) { s.trusted[id] = d } }
    }
    func deny(_ id: String) { mutate { _ = $0.pending.removeValue(forKey: id) } }
    func removeTrusted(_ id: String) {
        mutate { s in s.trusted.removeValue(forKey: id); s.pending.removeValue(forKey: id) }
    }
    func regenPassword() { mutate { $0.password = Engine.genPassword() }; log("Password regenerated") }

    // ===================================================================
    // HTTP
    // ===================================================================
    private func isAuthed(_ cookies: [String: String]) -> Bool {
        if verify(cookies["rd_sess"]) != nil { return true }
        guard let dev = verify(cookies["rd_dev"]) else { return false }
        lock.lock(); defer { lock.unlock() }
        return state.trusted[dev] != nil
    }

    private func json(_ obj: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
    }

    private func handle(_ c: HTTPConnection) {
        while running {
            guard let req = c.readRequest() else { return }
            let ka = req.keepAlive
            let cookies = req.cookies
            let authed = isAuthed(cookies)
            var ok = true

            switch (req.method, req.path) {
            case ("GET", "/"):
                ok = c.respond(200, "text/html; charset=utf-8", viewerHTML, keepAlive: ka)

            case ("GET", "/session"):
                ok = c.respond(200, "application/json",
                               json(["authed": authed, "viewOnly": settings.viewOnly, "host": "mac"]), keepAlive: ka)

            case ("POST", "/auth"):
                ok = doAuth(c, req, cookies)

            case ("GET", "/stream"):
                if authed { streamMJPEG(c) } else { c.respond(403, text: "no", keepAlive: false) }
                return

            case ("POST", "/input"):
                if authed {
                    doInput(req.body, ua: req.userAgent)
                    ok = c.respond(200, text: "ok", keepAlive: ka)
                } else { ok = c.respond(403, text: "no", keepAlive: ka) }

            case ("GET", "/clipboard"):
                if authed {
                    ok = c.respond(200, "application/json", json(["text": clipGet()]), keepAlive: ka)
                } else { ok = c.respond(403, text: "no", keepAlive: ka) }

            case ("POST", "/clipboard"):
                if authed {
                    let o = (try? JSONSerialization.jsonObject(with: req.body)) as? [String: Any]
                    clipSet(o?["text"] as? String ?? "")
                    ok = c.respond(200, text: "ok", keepAlive: ka)
                } else { ok = c.respond(403, text: "no", keepAlive: ka) }

            case ("GET", "/files"):
                if authed {
                    ok = c.respond(200, "application/json", json(["files": listFiles()]), keepAlive: ka)
                } else { ok = c.respond(403, text: "no", keepAlive: ka) }

            case ("GET", "/download"):
                if !authed { ok = c.respond(403, text: "no", keepAlive: ka); break }
                let name = Engine.safeName(req.param("name"))
                let url = shareDir.appendingPathComponent(name)
                if !name.isEmpty, let d = try? Data(contentsOf: url) {
                    ok = c.respond(200, "application/octet-stream", d,
                                   extra: "Content-Disposition: attachment; filename=\"\(name)\"\r\n", keepAlive: ka)
                } else { ok = c.respond(404, text: "not found", keepAlive: ka) }

            case ("POST", "/upload"):
                if !authed { ok = c.respond(403, text: "no", keepAlive: ka); break }
                var name = Engine.safeName(req.param("name"))
                if name.isEmpty { name = "upload.bin" }
                do {
                    try req.body.write(to: shareDir.appendingPathComponent(name), options: [.atomic])
                    log("File uploaded: \(name) (\(req.body.count) bytes)")
                } catch { log("Upload failed: \(error.localizedDescription)") }
                ok = c.respond(200, text: "ok", keepAlive: ka)

            case (_, "/favicon.ico"):
                ok = c.respond(204, "text/plain", Data(), keepAlive: ka)

            default:
                ok = c.respond(404, text: "not found", keepAlive: ka)
            }
            if !ok || !ka { return }
        }
    }

    /// A plain file name: no directories, no control characters or quotes.
    static func safeName(_ raw: String) -> String {
        let base = (raw as NSString).lastPathComponent
        let cleaned = String(base.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && $0 != "\"" && $0 != "/" && $0 != ":" && $0 != "\\"
        }).trimmingCharacters(in: .whitespaces)
        if cleaned == "." || cleaned == ".." { return "" }
        return cleaned
    }

    private func listFiles() -> [[String: Any]] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        let items = (try? FileManager.default.contentsOfDirectory(at: shareDir, includingPropertiesForKeys: keys,
                                                                  options: [.skipsHiddenFiles])) ?? []
        return items.compactMap { u in
            guard let v = try? u.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return nil }
            return ["name": u.lastPathComponent, "size": v.fileSize ?? 0]
        }.sorted { ($0["name"] as? String ?? "") < ($1["name"] as? String ?? "") }
    }

    private func doAuth(_ c: HTTPConnection, _ req: HTTPRequest, _ cookies: [String: String]) -> Bool {
        let ip = req.clientIP, ka = req.keepAlive
        throttleLock.lock()
        var tries = (throttle[ip] ?? []).filter { Date().timeIntervalSince($0) < 60 }
        throttle[ip] = tries
        throttleLock.unlock()
        if tries.count >= 10 { return c.respond(429, text: "slow", keepAlive: ka) }

        let pw = String(decoding: req.body, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard Engine.slowEquals(pw, snapshot.password) else {
            tries.append(Date())
            throttleLock.lock(); throttle[ip] = tries; throttleLock.unlock()
            return c.respond(403, text: "no", keepAlive: ka)
        }
        throttleLock.lock(); throttle[ip] = []; throttleLock.unlock()

        let dev = verify(cookies["rd_dev"]) ?? Engine.randHex(8)
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd HH:mm"
        let info = DeviceInfo(label: Engine.label(req.userAgent), ip: ip, added: df.string(from: Date()))
        var auto = false
        mutate { s in
            auto = s.autoApprove
            if s.autoApprove { s.trusted[dev] = info; s.pending.removeValue(forKey: dev) }
            else if s.trusted[dev] == nil { s.pending[dev] = info }
        }
        log((auto ? "Auto-approved " : "Login from ") + "\(info.label) (\(ip))")
        let extra = "Set-Cookie: rd_sess=\(sign(Engine.randHex(8))); Path=/; HttpOnly; SameSite=Lax\r\n"
            + "Set-Cookie: rd_dev=\(sign(dev)); Path=/; Max-Age=31536000; HttpOnly; SameSite=Lax\r\n"
        return c.respond(200, "text/plain", Data("ok".utf8), extra: extra, keepAlive: ka)
    }

    static func label(_ ua: String) -> String {
        for t in ["iPhone", "iPad", "Android", "Windows", "Macintosh", "Linux"] where ua.contains(t) {
            return t == "Macintosh" ? "Mac" : t
        }
        return "Computer"
    }

    private func doInput(_ body: Data, ua: String) {
        let s = settings
        if s.viewOnly { return }
        if !AXIsProcessTrusted() {
            if !warnedAX { warnedAX = true; log("Input ignored: grant Accessibility permission to this app") }
            return
        }
        warnedAX = false
        guard let arr = (try? JSONSerialization.jsonObject(with: body)) as? [[String: Any]] else { return }
        // A Mac viewer already sends ⌘ as "Meta"; only remap for Windows/Linux viewers.
        let swap = s.ctrlAsCmd && !ua.contains("Macintosh")
        input.handle(arr, swapCtrlCmd: swap)
    }

    private func streamMJPEG(_ c: HTTPConnection) {
        guard c.write("HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=rdframe\r\n"
                      + "Cache-Control: no-store\r\nConnection: close\r\n\r\n--rdframe\r\n") else { return }
        var last = -1
        var lastSent = Date.distantPast
        while running {
            let (f, sq) = capture.latest
            // ScreenCaptureKit only delivers frames when the screen changes, so
            // re-send the last frame once a second (keeps the viewer fresh and
            // detects closed connections).
            if let f = f, sq != last || Date().timeIntervalSince(lastSent) > 1 {
                last = sq
                lastSent = Date()
                let head = "Content-Type: image/jpeg\r\nContent-Length: \(f.count)\r\n\r\n"
                guard c.write(head), c.write(f), c.write("\r\n--rdframe\r\n") else { break }
            }
            usleep(UInt32(1_000_000 / (max(1, settings.fps) + 2)))
        }
    }

    // ---- clipboard (AppKit, on the main thread) ----
    private func clipGet() -> String {
        DispatchQueue.main.sync { NSPasteboard.general.string(forType: .string) ?? "" }
    }
    private func clipSet(_ s: String) {
        DispatchQueue.main.sync {
            let pb = NSPasteboard.general
            pb.clearContents()
            if !s.isEmpty { pb.setString(s, forType: .string) }
        }
    }
}
