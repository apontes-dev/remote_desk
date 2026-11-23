// Internet mode: a cloudflared "quick tunnel" (free, no account, outbound
// only) that gives a public https://….trycloudflare.com URL.

import Foundation

final class Tunnel {
    private let lock = NSLock()
    private var _status = "stopped" // stopped|starting|running|missing|error
    private var _url: String?
    private var proc: Process?
    private var outBuf = ""
    private let port: UInt16
    private static let rx = try! NSRegularExpression(pattern: "https://[a-z0-9-]+\\.trycloudflare\\.com")

    init(port: UInt16) { self.port = port }

    var status: String { lock.lock(); defer { lock.unlock() }; return _status }
    var url: String? { lock.lock(); defer { lock.unlock() }; return _url }

    /// Where we look for the cloudflared binary.
    static var searchPaths: [String] {
        var c: [String] = []
        let appDir = Bundle.main.bundleURL.deletingLastPathComponent().path
        c.append(appDir + "/cloudflared")
        if let r = Bundle.main.resourcePath { c.append(r + "/cloudflared") }
        c.append(Engine.supportDir.appendingPathComponent("cloudflared").path)
        c.append("/opt/homebrew/bin/cloudflared")
        c.append("/usr/local/bin/cloudflared")
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            c.append(String(dir) + "/cloudflared")
        }
        return c
    }

    static func findExe() -> String? {
        searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func start() {
        lock.lock(); defer { lock.unlock() }
        if _status == "starting" || _status == "running" { return }
        guard let exe = Tunnel.findExe() else { _status = "missing"; return }
        _url = nil
        outBuf = ""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["tunnel", "--no-autoupdate", "--url", "http://127.0.0.1:\(port)"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.scan(String(decoding: d, as: UTF8.self))
        }
        p.terminationHandler = { [weak self] pr in self?.exited(pr) }
        do {
            try p.run()
            proc = p
            _status = "starting"
        } catch {
            _status = "error"
        }
    }

    private func scan(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        outBuf += s
        if outBuf.count > 8192 { outBuf = String(outBuf.suffix(4096)) }
        let ns = outBuf as NSString
        for m in Tunnel.rx.matches(in: outBuf, range: NSRange(location: 0, length: ns.length)) {
            let u = ns.substring(with: m.range)
            if u == "https://api.trycloudflare.com" { continue }
            _url = u
            _status = "running"
        }
    }

    private func exited(_ p: Process) {
        lock.lock(); defer { lock.unlock() }
        guard proc === p else { return }
        proc = nil
        _url = nil
        _status = "error"
    }

    func stop() {
        lock.lock()
        let p = proc
        proc = nil
        _url = nil
        _status = "stopped"
        lock.unlock()
        if let p = p, p.isRunning { p.terminate() }
    }
}
