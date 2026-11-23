// Minimal blocking HTTP/1.1 server on BSD sockets: one thread per client,
// keep-alive, Content-Length bodies. Mirrors the TcpListener server of the
// Windows host so the browser viewer works unchanged.

import Foundation
import Darwin

/// Thread-safe boolean.
final class Flag {
    private var v: Bool
    private let l = NSLock()
    init(_ v: Bool = false) { self.v = v }
    var value: Bool {
        get { l.lock(); defer { l.unlock() }; return v }
        set { l.lock(); v = newValue; l.unlock() }
    }
}

struct HTTPRequest {
    let method: String
    let path: String
    let query: String
    let headers: [String: String]
    let body: Data
    let remoteIP: String

    var keepAlive: Bool { !(headers["connection"]?.lowercased().contains("close") ?? false) }
    var userAgent: String { headers["user-agent"] ?? "" }

    /// Client address (first X-Forwarded-For hop when behind the tunnel).
    var clientIP: String {
        if let x = headers["x-forwarded-for"], let first = x.split(separator: ",").first {
            let t = first.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { return t }
        }
        return remoteIP
    }

    var cookies: [String: String] {
        var d: [String: String] = [:]
        for part in (headers["cookie"] ?? "").split(separator: ";") {
            guard let e = part.firstIndex(of: "=") else { continue }
            let k = part[..<e].trimmingCharacters(in: .whitespaces)
            let v = part[part.index(after: e)...].trimmingCharacters(in: .whitespaces)
            if !k.isEmpty { d[k] = v }
        }
        return d
    }

    func param(_ key: String) -> String {
        for kv in query.split(separator: "&") {
            let parts = kv.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.first.map(String.init) == key {
                let raw = parts.count > 1 ? String(parts[1]) : ""
                return raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? raw
            }
        }
        return ""
    }
}

final class HTTPConnection {
    let fd: Int32
    let remoteIP: String
    private var buf: [UInt8] = []
    private var pos = 0
    private var closed = false

    init(fd: Int32, remoteIP: String) {
        self.fd = fd
        self.remoteIP = remoteIP
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        var rcv = timeval(tv_sec: 120, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &rcv, socklen_t(MemoryLayout<timeval>.size))
        var snd = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &snd, socklen_t(MemoryLayout<timeval>.size))
    }

    func close() {
        if closed { return }
        closed = true
        Darwin.close(fd)
    }

    // ---- reading ----
    private func fill() -> Bool {
        if pos >= buf.count { buf.removeAll(keepingCapacity: true); pos = 0 }
        else if pos > 65536 { buf.removeFirst(pos); pos = 0 }
        var tmp = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = tmp.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { return false }
            buf.append(contentsOf: tmp[0..<n])
            return true
        }
    }

    private func readHead() -> String? {
        while true {
            var i = pos
            while i + 3 < buf.count {
                if buf[i] == 13 && buf[i + 1] == 10 && buf[i + 2] == 13 && buf[i + 3] == 10 {
                    let s = String(decoding: buf[pos..<i], as: UTF8.self)
                    pos = i + 4
                    return s
                }
                i += 1
            }
            if buf.count - pos > 65536 { return nil }
            if !fill() { return nil }
        }
    }

    private func readBody(_ n: Int) -> Data {
        var out = Data()
        out.reserveCapacity(n)
        let take = min(buf.count - pos, n)
        if take > 0 { out.append(contentsOf: buf[pos..<(pos + take)]); pos += take }
        var tmp = [UInt8](repeating: 0, count: 65536)
        while out.count < n {
            let want = min(tmp.count, n - out.count)
            let k = tmp.withUnsafeMutableBytes { recv(fd, $0.baseAddress, want, 0) }
            if k < 0 && errno == EINTR { continue }
            if k <= 0 { break }
            out.append(contentsOf: tmp[0..<k])
        }
        return out
    }

    func readRequest() -> HTTPRequest? {
        guard let head = readHead(), !head.isEmpty else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let rl = lines[0].split(separator: " ")
        guard rl.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let c = line.firstIndex(of: ":") else { continue }
            let k = line[..<c].trimmingCharacters(in: .whitespaces).lowercased()
            let v = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
            headers[k] = v
        }
        var body = Data()
        if let cl = headers["content-length"], let n = Int(cl), n > 0 {
            body = readBody(n)
            if body.count < n { return nil }
        }
        let raw = String(rl[1])
        var path = raw, query = ""
        if let q = raw.firstIndex(of: "?") {
            path = String(raw[..<q])
            query = String(raw[raw.index(after: q)...])
        }
        return HTTPRequest(method: String(rl[0]), path: path, query: query,
                           headers: headers, body: body, remoteIP: remoteIP)
    }

    // ---- writing ----
    @discardableResult
    func write(_ d: Data) -> Bool {
        return d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return true }
            var off = 0
            while off < raw.count {
                let n = Darwin.send(fd, base.advanced(by: off), raw.count - off, 0)
                if n < 0 { if errno == EINTR { continue }; return false }
                if n == 0 { return false }
                off += n
            }
            return true
        }
    }

    @discardableResult
    func write(_ s: String) -> Bool { write(Data(s.utf8)) }

    static func reason(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 204: return "No Content"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 429: return "Too Many Requests"
        default: return "Error"
        }
    }

    @discardableResult
    func respond(_ code: Int, _ ctype: String, _ body: Data, extra: String = "", keepAlive: Bool) -> Bool {
        let h = "HTTP/1.1 \(code) \(HTTPConnection.reason(code))\r\n"
            + "Content-Type: \(ctype)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Cache-Control: no-store\r\n"
            + extra
            + "Connection: \(keepAlive ? "keep-alive" : "close")\r\n\r\n"
        guard write(h) else { return false }
        return body.isEmpty || write(body)
    }

    @discardableResult
    func respond(_ code: Int, text: String, keepAlive: Bool) -> Bool {
        respond(code, "text/plain", Data(text.utf8), keepAlive: keepAlive)
    }
}

enum ServerError: Error, LocalizedError {
    case socket(String)
    var errorDescription: String? { if case .socket(let s) = self { return s }; return nil }
}

final class HTTPServer {
    var handler: ((HTTPConnection) -> Void)?
    private var listenFD: Int32 = -1
    private let active = Flag()

    var isRunning: Bool { active.value }

    func start(port: UInt16) throws {
        if active.value { return }
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socket("socket() failed: \(String(cString: strerror(errno)))") }
        var yes: Int32 = 1, no: Int32 = 0
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &no, socklen_t(MemoryLayout<Int32>.size)) // dual-stack

        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_port = port.bigEndian
        addr.sin6_addr = in6addr_any
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard r == 0 else {
            let msg = String(cString: strerror(errno))
            Darwin.close(fd)
            throw ServerError.socket("port \(port): \(msg)")
        }
        guard listen(fd, 64) == 0 else {
            let msg = String(cString: strerror(errno))
            Darwin.close(fd)
            throw ServerError.socket("listen: \(msg)")
        }
        listenFD = fd
        active.value = true
        let t = Thread { [weak self] in self?.acceptLoop(fd) }
        t.name = "rd-accept"
        t.start()
    }

    func stop() {
        guard active.value else { return }
        active.value = false
        if listenFD >= 0 { Darwin.close(listenFD); listenFD = -1 }
    }

    private func acceptLoop(_ lfd: Int32) {
        while active.value {
            var pfd = pollfd(fd: lfd, events: Int16(POLLIN), revents: 0)
            let pr = poll(&pfd, 1, 500)
            if !active.value { break }
            if pr <= 0 { continue }

            var ss = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let cfd = withUnsafeMutablePointer(to: &ss) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(lfd, $0, &len) }
            }
            if cfd < 0 { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            _ = withUnsafePointer(to: &ss) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getnameinfo($0, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                }
            }
            var ip = String(cString: host)
            if ip.hasPrefix("::ffff:") { ip = String(ip.dropFirst(7)) }

            let conn = HTTPConnection(fd: cfd, remoteIP: ip)
            let h = handler
            let t = Thread {
                if let h = h { h(conn) }
                conn.close()
            }
            t.name = "rd-client"
            t.start()
        }
    }
}
