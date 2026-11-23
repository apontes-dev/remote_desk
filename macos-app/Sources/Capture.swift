// Screen capture with ScreenCaptureKit: frames arrive as CVPixelBuffers and
// are JPEG-encoded (Core Image) into the latest-frame slot that the MJPEG
// streamer reads. Needs the Screen Recording permission.

import Foundation
import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import ImageIO
import ScreenCaptureKit

final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    var settingsProvider: () -> HostSettings = { HostSettings() }
    var log: (String) -> Void = { _ in }

    private let ci = CIContext(options: [.cacheIntermediates: false])
    private let sampleQueue = DispatchQueue(label: "rd.capture.samples")
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    // latest encoded frame
    private let frameLock = NSLock()
    private var frame: Data?
    private var seq = 0

    // control state
    private let ctl = NSLock()
    private var stream: SCStream?
    private var display: SCDisplay?
    private var wanted = false
    private var gen = 0
    private var _status = "stopped"
    private var _bounds = CGDisplayBounds(CGMainDisplayID())

    var latest: (Data?, Int) {
        frameLock.lock(); defer { frameLock.unlock() }
        return (frame, seq)
    }
    var status: String { ctl.lock(); defer { ctl.unlock() }; return _status }
    /// Captured display rectangle in global (top-left origin) points — used to map viewer coordinates.
    var displayBounds: CGRect { ctl.lock(); defer { ctl.unlock() }; return _bounds }

    private func setStatus(_ s: String) {
        ctl.lock(); let changed = _status != s; _status = s; ctl.unlock()
        if changed { log("Capture: " + s) }
    }

    // ---- lifecycle ----
    func start() {
        ctl.lock()
        wanted = true
        gen += 1
        let g = gen
        let old = stream
        stream = nil; display = nil
        ctl.unlock()
        Task {
            if let old = old { try? await old.stopCapture() }
            await self.run(g)
        }
    }

    func stop() {
        ctl.lock()
        wanted = false
        gen += 1
        let old = stream
        stream = nil; display = nil
        ctl.unlock()
        setStatus("stopped")
        Task { if let old = old { try? await old.stopCapture() } }
    }

    /// Apply new fps / scale / display settings to the running stream.
    func reconfigure() {
        ctl.lock()
        let st = stream, d = display, isWanted = wanted
        ctl.unlock()
        guard isWanted else { return }
        guard let st = st, let d = d else { start(); return }
        let s = settingsProvider()
        let targetID = s.displayID == 0 ? CGMainDisplayID() : s.displayID
        if targetID != d.displayID { start(); return }
        let cfg = makeConfig(d, s)
        Task {
            do { try await st.updateConfiguration(cfg) }
            catch { self.start() }
        }
    }

    private func isCurrent(_ g: Int) -> Bool {
        ctl.lock(); defer { ctl.unlock() }
        return wanted && gen == g
    }

    private func run(_ g: Int) async {
        var asked = false
        while isCurrent(g) {
            do {
                if !CGPreflightScreenCaptureAccess() && !asked {
                    asked = true
                    _ = CGRequestScreenCaptureAccess()
                }
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                let s = settingsProvider()
                let targetID = s.displayID == 0 ? CGMainDisplayID() : s.displayID
                guard let d = content.displays.first(where: { $0.displayID == targetID })
                        ?? content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                        ?? content.displays.first else {
                    throw NSError(domain: "RemoteDesktop", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "no display found"])
                }
                let filter = SCContentFilter(display: d, excludingWindows: [])
                let st = SCStream(filter: filter, configuration: makeConfig(d, s), delegate: self)
                try st.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
                try await st.startCapture()

                ctl.lock()
                if !(wanted && gen == g) {
                    ctl.unlock()
                    try? await st.stopCapture()
                    return
                }
                stream = st
                display = d
                _bounds = CGDisplayBounds(d.displayID)
                ctl.unlock()
                setStatus("running (\(d.width)×\(d.height))")
                return
            } catch {
                if CGPreflightScreenCaptureAccess() {
                    setStatus("error: \(error.localizedDescription)")
                } else {
                    setStatus("needs Screen Recording permission")
                }
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            }
        }
    }

    private func makeConfig(_ d: SCDisplay, _ s: HostSettings) -> SCStreamConfiguration {
        let cfg = SCStreamConfiguration()
        let pct = Double(min(max(s.scalePct, 10), 200)) / 100.0
        cfg.width = max(2, Int(Double(d.width) * pct)) & ~1
        cfg.height = max(2, Int(Double(d.height) * pct)) & ~1
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, min(s.fps, 60))))
        cfg.showsCursor = true
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.queueDepth = 4
        return cfg
    }

    // ---- SCStreamOutput ----
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
           let raw = attachments.first?[.status] as? Int,
           let st = SCFrameStatus(rawValue: raw), st != .complete {
            return // idle / blank frames carry no new image
        }
        guard let pb = sampleBuffer.imageBuffer else { return }
        let q = Double(min(max(settingsProvider().quality, 1), 100)) / 100.0
        let img = CIImage(cvPixelBuffer: pb)
        let opts: [CIImageRepresentationOption: Any] = [
            CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): q
        ]
        guard let jpg = ci.jpegRepresentation(of: img, colorSpace: srgb, options: opts) else { return }
        frameLock.lock()
        frame = jpg
        seq += 1
        frameLock.unlock()
    }

    // ---- SCStreamDelegate ----
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        ctl.lock()
        let current = self.stream === stream
        if current { self.stream = nil; display = nil }
        let again = current && wanted
        ctl.unlock()
        guard again else { return }
        log("Capture stopped: \(error.localizedDescription) — restarting")
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self else { return }
            self.ctl.lock(); let w = self.wanted; let none = self.stream == nil; self.ctl.unlock()
            if w && none { self.start() }
        }
    }
}
