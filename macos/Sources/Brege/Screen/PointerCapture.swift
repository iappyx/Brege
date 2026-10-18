import AppKit
import CoreGraphics

/// Takes over this Mac's pointer and keyboard and turns them into reports for the phone's virtual
/// input devices.
///
/// Push the pointer against the chosen screen edge and it crosses over: the Mac's cursor is hidden
/// and every click, scroll and keystroke goes to the phone instead, until Control-Escape brings it
/// back. Capturing keys needs Privacy & Security › Accessibility, the same permission the media and
/// slide keys use.
@MainActor
final class PointerCapture {
    enum Edge: String, CaseIterable {
        case left, right

        var label: String { self == .left ? "Left edge" : "Right edge" }
    }

    /// Mouse buttons, in the order the report descriptor lists them.
    private enum Button {
        static let left: UInt8 = 1
        static let right: UInt8 = 2
        static let middle: UInt8 = 4
    }

    private(set) var isCapturing = false
    var edge: Edge = .right
    /// The phone's screen width in pixels, for telling when the pointer has reached its far side.
    var phoneWidth = 1080
    /// Sends one report to the phone.
    var send: ((Data) -> Void)?
    var onCaptureChanged: ((Bool) -> Void)?

    /// How far the pointer must keep pushing past the phone's edge before it comes back, so that
    /// brushing the side while working does not end the capture.
    private static let returnPush = 160.0

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var edgeMonitor: Any?
    private var buttons: UInt8 = 0
    private var modifiers: UInt8 = 0
    private var keysDown: [UInt8] = []
    private var returnPoint: CGPoint?
    /// Where the phone's own pointer is, in its pixels. Android clamps its cursor to the screen, so
    /// an estimate that clamps the same way is exact whenever the pointer sits against a side —
    /// which is all this needs to be right about.
    private var phoneX = 0.0
    private var pushedPastEdge = 0.0

    /// Watches for the pointer reaching the edge. Stops watching while the phone has the pointer.
    func startWatchingEdge() {
        guard edgeMonitor == nil else { return }
        edgeMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            guard let self, !self.isCapturing else { return }
            let point = NSEvent.mouseLocation
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main else { return }
            let atEdge = self.edge == .left ? point.x <= screen.frame.minX + 1 : point.x >= screen.frame.maxX - 1
            if atEdge { self.beginCapture() }
        }
    }

    func stopWatchingEdge() {
        if let edgeMonitor { NSEvent.removeMonitor(edgeMonitor) }
        edgeMonitor = nil
    }

    /// Hands the pointer and keyboard to the phone. Returns false when Accessibility is not granted.
    @discardableResult
    func beginCapture() -> Bool {
        guard !isCapturing else { return true }
        // Listed rather than or-ed together: the type checker gives up on a long chain of shifts.
        let wanted: [CGEventType] = [
            .mouseMoved, .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp,
            .otherMouseDown, .otherMouseUp, .leftMouseDragged, .rightMouseDragged,
            .otherMouseDragged, .scrollWheel, .keyDown, .keyUp, .flagsChanged,
        ]
        var events: CGEventMask = 0
        for type in wanted { events |= CGEventMask(1) << CGEventMask(type.rawValue) }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: events,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let capture = Unmanaged<PointerCapture>.fromOpaque(refcon).takeUnretainedValue()
                return capture.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        runLoopSource = source

        returnPoint = CGEvent(source: nil)?.location
        // Unpin the cursor from the mouse: the Mac's pointer stays put while the phone's moves.
        CGAssociateMouseAndMouseCursorPosition(0)
        CGDisplayHideCursor(CGMainDisplayID())
        isCapturing = true

        // Plug the phone's mouse and keyboard in for as long as the pointer is over there. Leaving
        // them registered would leave its cursor sitting on screen after the pointer came back.
        send?(UhidInput.createPointer())
        send?(UhidInput.createKeyboard())
        phoneX = edge == .right ? 0 : Double(phoneWidth - 1)
        pushedPastEdge = 0
        // Android needs a moment to register a new device before it acts on its reports.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.isCapturing else { return }
            // Come in at the side the pointer crossed, the way a second screen would. Pushing the
            // phone's cursor hard against that side pins it where this Mac's estimate says it is.
            let inwards = self.edge == .right ? -127 : 127
            for _ in 0..<24 { self.send?(UhidInput.move(dx: inwards, dy: 0)) }
            self.phoneX = self.edge == .right ? 0 : Double(self.phoneWidth - 1)
        }
        onCaptureChanged?(true)
        return true
    }

    /// Gives the pointer back to the Mac, releasing anything still held on the phone.
    func endCapture() {
        guard isCapturing else { return }
        isCapturing = false
        if buttons != 0 {
            buttons = 0
            send?(UhidInput.move(dx: 0, dy: 0, buttons: 0))
        }
        if !keysDown.isEmpty || modifiers != 0 {
            keysDown = []
            modifiers = 0
            send?(UhidInput.keys(modifiers: 0, down: []))
        }
        // Unplugging both devices makes the phone hide its cursor straight away.
        send?(UhidInput.destroy(UhidInput.keyboardID))
        send?(UhidInput.destroy(UhidInput.pointerID))
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        }
        tap = nil
        runLoopSource = nil

        CGAssociateMouseAndMouseCursorPosition(1)
        CGDisplayShowCursor(CGMainDisplayID())
        // Step back from the edge, so the pointer does not cross again straight away.
        if let point = returnPoint {
            let nudge: CGFloat = edge == .left ? 8 : -8
            CGWarpMouseCursorPosition(CGPoint(x: point.x + nudge, y: point.y))
        }
        returnPoint = nil
        onCaptureChanged?(false)
    }

    // MARK: Events

    private nonisolated func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system disables a tap that takes too long; turn it back on rather than lose the keys.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            MainActor.assumeIsolated { if let tap { CGEvent.tapEnable(tap: tap, enable: true) } }
            return nil
        }
        return MainActor.assumeIsolated { translate(type: type, event: event) }
    }

    private func translate(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard isCapturing else { return Unmanaged.passUnretained(event) }
        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            let dx = Int(event.getIntegerValueField(.mouseEventDeltaX))
            let dy = Int(event.getIntegerValueField(.mouseEventDeltaY))
            if dx != 0 || dy != 0 { send?(UhidInput.move(dx: dx, dy: dy, buttons: buttons)) }
            if let parked = returnPoint { CGWarpMouseCursorPosition(parked) }
            if trackedPastEdge(dx: dx) { endCapture() }

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            buttons |= button(for: event, type: type)
            send?(UhidInput.move(dx: 0, dy: 0, buttons: buttons))

        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            buttons &= ~button(for: event, type: type)
            send?(UhidInput.move(dx: 0, dy: 0, buttons: buttons))

        case .scrollWheel:
            // Trackpads report pixels, mouse wheels report lines; the phone wants notches.
            let pixels = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
            let raw = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
            let notches = Int((pixels ? raw / 10 : raw).rounded())
            if notches != 0 { send?(UhidInput.move(dx: 0, dy: 0, wheel: notches, buttons: buttons)) }

        case .keyDown, .keyUp:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            // Control-Escape is the way back, and never reaches the phone.
            if type == .keyDown, code == 53, event.flags.contains(.maskControl) {
                endCapture()
                return nil
            }
            guard let usage = Self.hidUsage[code] else { return nil }
            if type == .keyDown {
                if !keysDown.contains(usage), keysDown.count < UhidInput.maxKeysDown { keysDown.append(usage) }
            } else {
                keysDown.removeAll { $0 == usage }
            }
            send?(UhidInput.keys(modifiers: modifiers, down: keysDown))

        case .flagsChanged:
            modifiers = Self.modifierBits(event.flags)
            send?(UhidInput.keys(modifiers: modifiers, down: keysDown))

        default:
            break
        }
        return nil // consumed: the Mac must not act on it too
    }

    /// Follows the phone's cursor across its screen and reports when it has been pushed off the
    /// side it came in on — the way a pointer leaves one screen for the next.
    ///
    /// The estimate drifts in the middle of the screen, because the phone applies its own pointer
    /// acceleration to what it is sent. It cannot drift at the sides: both this and Android stop
    /// at the same place, so a cursor held against the edge is in a position both agree on. Asking
    /// for a further push before handing the pointer back also covers any drift that made the
    /// estimate arrive late.
    private func trackedPastEdge(dx: Int) -> Bool {
        phoneX = min(Double(phoneWidth - 1), max(0, phoneX + Double(dx)))
        let leaving = edge == .right ? phoneX <= 0 : phoneX >= Double(phoneWidth - 1)
        let outwards = edge == .right ? dx < 0 : dx > 0
        guard leaving, outwards else {
            if !leaving { pushedPastEdge = 0 }
            return false
        }
        pushedPastEdge += Double(abs(dx))
        return pushedPastEdge >= Self.returnPush
    }

    private func button(for event: CGEvent, type: CGEventType) -> UInt8 {
        switch type {
        case .leftMouseDown, .leftMouseUp: return Button.left
        case .rightMouseDown, .rightMouseUp: return Button.right
        default: return event.getIntegerValueField(.mouseEventButtonNumber) == 2 ? Button.middle : 0
        }
    }

    private static func modifierBits(_ flags: CGEventFlags) -> UInt8 {
        var bits: UInt8 = 0
        if flags.contains(.maskControl) { bits |= 0x01 }
        if flags.contains(.maskShift) { bits |= 0x02 }
        if flags.contains(.maskAlternate) { bits |= 0x04 }
        if flags.contains(.maskCommand) { bits |= 0x08 }
        return bits
    }

    /// Mac key codes to HID keyboard usages, for a US layout.
    private static let hidUsage: [UInt16: UInt8] = [
        0: 0x04, 1: 0x16, 2: 0x07, 3: 0x09, 4: 0x0B, 5: 0x0A, 6: 0x1D, 7: 0x1B, 8: 0x06, 9: 0x19,
        11: 0x05, 12: 0x14, 13: 0x1A, 14: 0x08, 15: 0x15, 16: 0x1C, 17: 0x17, 31: 0x12, 32: 0x18,
        34: 0x0C, 35: 0x13, 37: 0x0F, 38: 0x0D, 40: 0x0E, 45: 0x11, 46: 0x10,
        18: 0x1E, 19: 0x1F, 20: 0x20, 21: 0x21, 22: 0x23, 23: 0x22, 25: 0x26, 26: 0x24, 28: 0x25, 29: 0x27,
        24: 0x2E, 27: 0x2D, 30: 0x30, 33: 0x2F, 39: 0x34, 41: 0x33, 42: 0x31, 43: 0x36, 44: 0x38,
        47: 0x37, 50: 0x35,
        36: 0x28, 48: 0x2B, 49: 0x2C, 51: 0x2A, 53: 0x29,
        115: 0x4A, 116: 0x4B, 117: 0x4C, 119: 0x4D, 121: 0x4E,
        123: 0x50, 124: 0x4F, 125: 0x51, 126: 0x52,
    ]
}
