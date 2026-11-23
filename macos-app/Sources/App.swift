// Remote Desktop Host for macOS — the operator window (SwiftUI).

import SwiftUI
import AppKit
import ApplicationServices
import CoreGraphics

@main
struct RemoteDesktopHostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = HostModel()

    var body: some Scene {
        Window("Remote Desktop Host", id: "main") {
            ContentView().environmentObject(model)
        }
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var activity: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Keep serving while the window is in the background (no App Nap) and
        // keep the Mac from idle-sleeping while the host is open.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled],
            reason: "Serving remote desktop")
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { Engine.shared.stop() }
}

// ===================================================================
// View model: snapshots the engine once a second
// ===================================================================
struct DeviceItem: Identifiable, Equatable {
    let id: String
    let info: DeviceInfo
}
struct DisplayItem: Identifiable, Equatable {
    let id: UInt32
    let name: String
}

final class HostModel: ObservableObject {
    let eng = Engine.shared

    @Published var running = false
    @Published var password = ""
    @Published var mode = "lan"
    @Published var autoApprove = false
    @Published var settings = HostSettings()
    @Published var pending: [DeviceItem] = []
    @Published var trusted: [DeviceItem] = []
    @Published var lanURLs: [String] = []
    @Published var tunnelStatus = "stopped"
    @Published var tunnelURL: String?
    @Published var log: [String] = []
    @Published var screenOK = false
    @Published var axOK = false
    @Published var captureStatus = ""
    @Published var displays: [DisplayItem] = []

    private var timer: Timer?

    init() {
        eng.start()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private func set<T: Equatable>(_ kp: ReferenceWritableKeyPath<HostModel, T>, _ v: T) {
        if self[keyPath: kp] != v { self[keyPath: kp] = v }
    }

    func refresh() {
        let s = eng.snapshot
        set(\.running, eng.running)
        set(\.password, s.password)
        set(\.mode, s.mode)
        set(\.autoApprove, s.autoApprove)
        set(\.settings, s.settings)
        set(\.pending, s.pending.map { DeviceItem(id: $0.key, info: $0.value) }.sorted { $0.info.added < $1.info.added })
        set(\.trusted, s.trusted.map { DeviceItem(id: $0.key, info: $0.value) }.sorted { $0.info.added < $1.info.added })
        set(\.lanURLs, eng.lanURLs())
        set(\.tunnelStatus, eng.tunnel.status)
        set(\.tunnelURL, eng.tunnel.url)
        set(\.log, eng.logSnapshot())
        set(\.screenOK, CGPreflightScreenCaptureAccess())
        set(\.axOK, AXIsProcessTrusted())
        set(\.captureStatus, eng.capture.status)
        set(\.displays, NSScreen.screens.compactMap { sc in
            guard let n = sc.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return DisplayItem(id: n.uint32Value, name: sc.localizedName)
        })
    }

    // ---- bindings / actions ----
    func binding<T>(_ kp: WritableKeyPath<HostSettings, T>) -> Binding<T> {
        Binding(get: { self.settings[keyPath: kp] },
                set: { v in
                    self.settings[keyPath: kp] = v
                    self.eng.updateSettings { $0[keyPath: kp] = v }
                })
    }
    var modeBinding: Binding<String> {
        Binding(get: { self.mode }, set: { v in self.mode = v; self.eng.setMode(v); self.refresh() })
    }
    var autoBinding: Binding<Bool> {
        Binding(get: { self.autoApprove }, set: { v in self.autoApprove = v; self.eng.mutate { $0.autoApprove = v } })
    }

    func toggleServer() { if eng.running { eng.stop() } else { eng.start() }; refresh() }
    func regen() { eng.regenPassword(); refresh() }
    func approve(_ id: String) { eng.approve(id); refresh() }
    func deny(_ id: String) { eng.deny(id); refresh() }
    func remove(_ id: String) { eng.removeTrusted(id); refresh() }

    func copy(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }
    func openViewer() { NSWorkspace.shared.open(URL(string: "http://localhost:\(eng.port)/")!) }
    func openShared() {
        try? FileManager.default.createDirectory(at: eng.shareDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(eng.shareDir)
    }
    func requestScreen() {
        _ = CGRequestScreenCaptureAccess()
        openPrivacy("Privacy_ScreenCapture")
    }
    func requestAX() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
        openPrivacy("Privacy_Accessibility")
    }
    private func openPrivacy(_ anchor: String) {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + anchor) {
            NSWorkspace.shared.open(u)
        }
    }
    func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }

    func cloudflaredHelp() {
        let a = NSAlert()
        a.messageText = "Get cloudflared"
        a.informativeText = """
        Internet mode uses Cloudflare's free quick tunnel (no account, no router setup).

        Easiest:  brew install cloudflared

        Or download cloudflared-darwin-arm64.tgz (Apple silicon) or cloudflared-darwin-amd64.tgz (Intel) \
        from the GitHub releases page, extract it, and put the "cloudflared" file next to this app or in:
        \(Engine.supportDir.path)

        Then select Internet again.
        """
        a.addButton(withTitle: "Open download page")
        a.addButton(withTitle: "Show folder")
        a.addButton(withTitle: "OK")
        switch a.runModal() {
        case .alertFirstButtonReturn:
            NSWorkspace.shared.open(URL(string: "https://github.com/cloudflare/cloudflared/releases/latest")!)
        case .alertSecondButtonReturn:
            NSWorkspace.shared.open(Engine.supportDir)
        default:
            break
        }
        refresh()
    }
}

// ===================================================================
// Views
// ===================================================================
struct StatusDot: View {
    let color: Color
    var body: some View { Circle().fill(color).frame(width: 10, height: 10) }
}

struct ContentView: View {
    @EnvironmentObject var m: HostModel

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    StatusDot(color: m.running ? .green : .red)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.running ? "Running" : "Stopped").font(.headline)
                        if m.running {
                            Text("Capture: " + m.captureStatus).font(.caption).foregroundColor(.secondary)
                        }
                    }
                    Spacer()
                    Button(m.running ? "Stop" : "Start") { m.toggleServer() }
                        .controlSize(.large)
                }
            }

            Section("Permissions") {
                PermissionRow(ok: m.screenOK, title: "Screen Recording",
                              detail: "Lets remote viewers see this screen.", action: m.requestScreen)
                PermissionRow(ok: m.axOK, title: "Accessibility",
                              detail: "Lets remote viewers use the mouse and keyboard.", action: m.requestAX)
                if !m.screenOK || !m.axOK {
                    HStack {
                        Text("After granting a permission, macOS may need the app to be relaunched.")
                            .font(.caption).foregroundColor(.secondary)
                        Spacer()
                        Button("Relaunch") { m.relaunch() }
                    }
                }
            }

            Section("Access password") {
                HStack {
                    Text(m.password)
                        .font(.system(.title3, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button("Copy") { m.copy(m.password) }
                    Button("Regenerate") { m.regen() }
                }
            }

            Section("Where people connect") {
                Picker("Access", selection: m.modeBinding) {
                    Text("LAN only").tag("lan")
                    Text("Internet").tag("internet")
                }
                .pickerStyle(.segmented)

                if m.mode == "internet" {
                    HStack {
                        StatusDot(color: tunnelColor)
                        Text(tunnelText).foregroundColor(.secondary)
                        Spacer()
                    }
                    if let u = m.tunnelURL {
                        HStack {
                            Text(u).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                                .foregroundColor(.accentColor)
                            Spacer()
                            Button("Copy link") { m.copy(u) }
                        }
                    }
                }
                ForEach(m.lanURLs, id: \.self) { u in
                    HStack {
                        Text(u).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        Spacer()
                        Button("Copy") { m.copy(u) }
                    }
                }
                HStack {
                    Button("Get cloudflared…") { m.cloudflaredHelp() }
                    Button("Open viewer here") { m.openViewer() }
                    Button("Shared folder") { m.openShared() }
                }
            }

            Section("Trusted computers") {
                Toggle("Automatically approve new computers (give access without manual approval)",
                       isOn: m.autoBinding)
                if m.pending.isEmpty {
                    Text("No computers waiting for approval.").foregroundColor(.secondary)
                }
                ForEach(m.pending) { d in
                    HStack {
                        DeviceLabel(info: d.info, waiting: true)
                        Spacer()
                        Button("Approve") { m.approve(d.id) }
                        Button("Deny") { m.deny(d.id) }
                    }
                }
                ForEach(m.trusted) { d in
                    HStack {
                        DeviceLabel(info: d.info, waiting: false)
                        Spacer()
                        Button("Remove") { m.remove(d.id) }
                    }
                }
            }

            Section("Quality & input") {
                Toggle("View only (ignore all remote input)", isOn: m.binding(\.viewOnly))
                Toggle("Treat a Windows/Linux viewer's Ctrl as ⌘ Command", isOn: m.binding(\.ctrlAsCmd))
                Stepper(value: m.binding(\.fps), in: 1...30) {
                    LabeledContent("Frames per second", value: "\(m.settings.fps)")
                }
                Stepper(value: m.binding(\.quality), in: 10...95, step: 5) {
                    LabeledContent("JPEG quality", value: "\(m.settings.quality)")
                }
                Stepper(value: m.binding(\.scalePct), in: 20...200, step: 10) {
                    LabeledContent("Scale (200% = Retina sharp)", value: "\(m.settings.scalePct)%")
                }
                Picker("Display", selection: m.binding(\.displayID)) {
                    Text("Main display").tag(UInt32(0))
                    ForEach(m.displays) { d in Text(d.name).tag(d.id) }
                }
                LabeledContent("Port", value: "\(m.eng.port)")
            }

            Section("Activity") {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(m.log.enumerated()), id: \.offset) { i, line in
                                Text(line).font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(.secondary).textSelection(.enabled).id(i)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 120)
                    .onChange(of: m.log.count) { n in
                        if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 600, minHeight: 760)
    }

    private var tunnelColor: Color {
        switch m.tunnelStatus {
        case "running": return .green
        case "starting": return .orange
        default: return .red
        }
    }
    private var tunnelText: String {
        switch m.tunnelStatus {
        case "running": return "online"
        case "starting": return "starting tunnel…"
        case "missing": return "cloudflared not found — click “Get cloudflared…”"
        case "stopped": return m.running ? "stopped" : "server stopped"
        default: return "tunnel error — select LAN, then Internet, to retry"
        }
    }
}

struct PermissionRow: View {
    let ok: Bool
    let title: String
    let detail: String
    let action: () -> Void

    var body: some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if ok { Text("Granted").foregroundColor(.secondary) } else { Button("Grant…", action: action) }
        }
    }
}

struct DeviceLabel: View {
    let info: DeviceInfo
    let waiting: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: waiting ? "hourglass" : "checkmark.shield.fill")
                .foregroundColor(waiting ? .orange : .green)
            VStack(alignment: .leading, spacing: 2) {
                Text(info.label + (waiting ? " — approve to trust" : ""))
                Text("\(info.ip) · \(info.added)").font(.caption).foregroundColor(.secondary)
            }
        }
    }
}
