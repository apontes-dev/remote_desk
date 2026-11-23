// Remote mouse & keyboard via Quartz events (CGEvent). Needs the
// Accessibility permission (System Settings › Privacy & Security).

import Foundation
import AppKit
import CoreGraphics

final class InputInjector {
    var boundsProvider: () -> CGRect = { CGDisplayBounds(CGMainDisplayID()) }

    private let lock = NSLock()
    private let src = CGEventSource(stateID: .hidSystemState)
    private var buttons = Set<Int>()
    private var mods: CGEventFlags = []
    private var pos = CGPoint.zero
    private var lastDownTime: TimeInterval = 0
    private var lastDownButton = -1
    private var lastDownPos = CGPoint.zero
    private var clicks = 1

    /// Handle a batch of viewer events: {t:"move"|"down"|"up"|"wheel"|"char"|"key", ...}.
    func handle(_ events: [[String: Any]], swapCtrlCmd: Bool) {
        lock.lock(); defer { lock.unlock() }
        for ev in events {
            switch ev["t"] as? String ?? "" {
            case "move":
                move(to: point(ev))
            case "down":
                move(to: point(ev))
                button(Int(num(ev["b"])), down: true)
            case "up":
                button(Int(num(ev["b"])), down: false)
            case "wheel":
                wheel(dy: num(ev["dy"]), dx: num(ev["dx"]))
            case "char":
                typeText(ev["c"] as? String ?? "")
            case "key":
                key(ev["k"] as? String ?? "", down: (ev["down"] as? Bool) ?? false, swap: swapCtrlCmd)
            default:
                break
            }
        }
    }

    // ---- helpers ----
    private func num(_ v: Any?) -> Double { (v as? NSNumber)?.doubleValue ?? 0 }

    private func point(_ ev: [String: Any]) -> CGPoint {
        let b = boundsProvider()
        let x = min(max(num(ev["x"]), 0), 1)
        let y = min(max(num(ev["y"]), 0), 1)
        return CGPoint(x: b.minX + x * max(0, b.width - 1), y: b.minY + y * max(0, b.height - 1))
    }

    private func post(_ e: CGEvent?) { e?.post(tap: .cghidEventTap) }

    private func cgButton(_ b: Int) -> CGMouseButton {
        if b == 2 { return .right }
        if b == 1 { return .center }
        return .left
    }

    // ---- mouse ----
    private func move(to p: CGPoint) {
        pos = p
        let type: CGEventType
        let btn: CGMouseButton
        if buttons.contains(0) { type = .leftMouseDragged; btn = .left }
        else if buttons.contains(2) { type = .rightMouseDragged; btn = .right }
        else if buttons.contains(1) { type = .otherMouseDragged; btn = .center }
        else { type = .mouseMoved; btn = .left }
        guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: p, mouseButton: btn) else { return }
        e.flags = mods
        post(e)
    }

    private func button(_ b: Int, down: Bool) {
        guard (0...2).contains(b) else { return }
        let type: CGEventType
        switch (b, down) {
        case (0, true): type = .leftMouseDown
        case (0, false): type = .leftMouseUp
        case (2, true): type = .rightMouseDown
        case (2, false): type = .rightMouseUp
        case (_, true): type = .otherMouseDown
        default: type = .otherMouseUp
        }
        if down {
            // macOS needs an explicit click count for double/triple clicks.
            let now = ProcessInfo.processInfo.systemUptime
            let near = hypot(pos.x - lastDownPos.x, pos.y - lastDownPos.y) < 6
            if b == lastDownButton && near && now - lastDownTime <= NSEvent.doubleClickInterval {
                clicks += 1
            } else {
                clicks = 1
            }
            lastDownTime = now
            lastDownButton = b
            lastDownPos = pos
            buttons.insert(b)
        } else {
            // the viewer reports every mouseup on its window; ignore ups we never pressed
            guard buttons.contains(b) else { return }
            buttons.remove(b)
        }
        guard let e = CGEvent(mouseEventSource: src, mouseType: type, mouseCursorPosition: pos, mouseButton: cgButton(b)) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: Int64(clicks))
        e.flags = mods
        post(e)
    }

    private func wheel(dy: Double, dx: Double) {
        let y = Int32(max(-3000, min(3000, dy)))
        let x = Int32(max(-3000, min(3000, dx)))
        if x == 0 && y == 0 { return }
        post(CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0))
    }

    // ---- keyboard ----
    private func typeText(_ text: String) {
        for ch in text {
            let u = Array(String(ch).utf16)
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { continue }
                e.flags = []
                e.keyboardSetUnicodeString(stringLength: u.count, unicodeString: u)
                post(e)
            }
        }
    }

    private static func modifier(_ name: String) -> (CGKeyCode, CGEventFlags)? {
        switch name {
        case "Shift": return (56, .maskShift)
        case "Control": return (59, .maskControl)
        case "Alt": return (58, .maskAlternate)
        case "Meta", "OS": return (55, .maskCommand)
        default: return nil
        }
    }

    private func key(_ k: String, down: Bool, swap: Bool) {
        var name = k
        if swap {
            // Windows/Linux viewers: their Ctrl+C should be ⌘C on the Mac.
            if name == "Control" { name = "Meta" } else if name == "Meta" || name == "OS" { name = "Control" }
        }
        if let m = InputInjector.modifier(name) {
            if down { mods.insert(m.1) } else { mods.remove(m.1) }
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: m.0, keyDown: down) else { return }
            e.type = .flagsChanged
            e.flags = mods
            post(e)
            return
        }
        var code = InputInjector.keyCodes[name]
        if code == nil, name.count == 1, let c = name.lowercased().first {
            code = InputInjector.charCodes[c]
        }
        guard let vk = code, let e = CGEvent(keyboardEventSource: src, virtualKey: vk, keyDown: down) else { return }
        var flags = mods
        if (123...126).contains(Int(vk)) { flags.insert(.maskNumericPad); flags.insert(.maskSecondaryFn) }
        e.flags = flags
        post(e)
    }

    // Browser KeyboardEvent.key -> macOS virtual key code (kVK_*).
    static let keyCodes: [String: CGKeyCode] = [
        "Enter": 36, "Tab": 48, "Backspace": 51, "Escape": 53, "Delete": 117, "Insert": 114,
        "Home": 115, "End": 119, "PageUp": 116, "PageDown": 121,
        "ArrowLeft": 123, "ArrowRight": 124, "ArrowDown": 125, "ArrowUp": 126,
        " ": 49, "CapsLock": 57,
        "F1": 122, "F2": 120, "F3": 99, "F4": 118, "F5": 96, "F6": 97,
        "F7": 98, "F8": 100, "F9": 101, "F10": 109, "F11": 103, "F12": 111,
    ]

    // ANSI layout character -> key code (used when a modifier is held, e.g. ⌘C).
    static let charCodes: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50,
    ]
}
