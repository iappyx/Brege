import CoreGraphics
import Foundation

/// scrcpy control messages (client → phone), serialized as in scrcpy's `control_msg.c`.
enum ScreenControl {
    enum Action: UInt8 {
        case down = 0, up = 1, move = 2
    }

    /// Android key codes used by the window.
    enum Key: UInt32 {
        case home = 3, back = 4, dpadUp = 19, dpadDown = 20, dpadLeft = 21, dpadRight = 22
        case volumeUp = 24, volumeDown = 25, power = 26, tab = 61, enter = 66, delete = 67
        case pageUp = 92, pageDown = 93, escape = 111, forwardDelete = 112
        case moveHome = 122, moveEnd = 123, appSwitch = 187, wakeUp = 224
    }

    private static let pointerMouse = UInt64.max // -1
    private static let buttonPrimary: UInt32 = 1

    static func key(_ action: Action, _ key: UInt32, repeatCount: UInt32 = 0, metaState: UInt32 = 0) -> Data {
        var d = Data([0, action.rawValue])
        d.appendBigEndian(key)
        d.appendBigEndian(repeatCount)
        d.appendBigEndian(metaState)
        return d
    }

    /// Text is limited to 300 bytes per message by the server.
    static func text(_ text: String) -> Data {
        var bytes = Data(text.utf8)
        if bytes.count > 300 { bytes = bytes.prefix(300) }
        var d = Data([1])
        d.appendBigEndian(UInt32(bytes.count))
        d.append(bytes)
        return d
    }

    /// A left-button touch. The position is in video pixels; `videoSize` must match the stream.
    static func touch(_ action: Action, at point: CGPoint, videoSize: CGSize) -> Data {
        var d = Data([2, action.rawValue])
        d.appendBigEndian(pointerMouse)
        d.appendPosition(point, videoSize)
        d.appendBigEndian(UInt16(action == .up ? 0 : 0xFFFF)) // pressure
        d.appendBigEndian(buttonPrimary) // action button
        d.appendBigEndian(action == .up ? 0 : buttonPrimary) // buttons
        return d
    }

    /// Scroll amounts are in notches, clamped to ±16 by the protocol.
    static func scroll(at point: CGPoint, videoSize: CGSize, horizontal: Double, vertical: Double) -> Data {
        func fixed(_ value: Double) -> UInt16 {
            let normalized = max(-1, min(1, value / 16))
            return UInt16(bitPattern: normalized >= 1 ? 0x7FFF : Int16(normalized * 32768))
        }
        var d = Data([3])
        d.appendPosition(point, videoSize)
        d.appendBigEndian(fixed(horizontal))
        d.appendBigEndian(fixed(vertical))
        d.appendBigEndian(UInt32(0))
        return d
    }

    /// BACK, or turns the screen on when it is off.
    static func backOrScreenOn(_ action: Action) -> Data {
        Data([4, action.rawValue])
    }

    static func expandNotifications() -> Data { Data([5]) }

    /// Asks for the phone clipboard, after pressing COPY (1) or CUT (2) when given; the text
    /// arrives as a device message.
    static func getClipboard(copyKey: UInt8 = 0) -> Data { Data([8, copyKey]) }

    static func setClipboard(_ text: String, paste: Bool, sequence: UInt64 = 0) -> Data {
        var d = Data([9])
        d.appendBigEndian(sequence)
        d.append(paste ? 1 : 0)
        let bytes = Data(text.utf8)
        d.appendBigEndian(UInt32(bytes.count))
        d.append(bytes)
        return d
    }

    /// Turns the phone's own display off or on while streaming continues.
    static func setDisplayPower(_ on: Bool) -> Data { Data([10, on ? 1 : 0]) }

    static func rotate() -> Data { Data([11]) }

    /// Requests a new key frame, e.g. after the decoder failed.
    static func resetVideo() -> Data { Data([17]) }

    /// Starts an app on the session's display. `package` must be a plain package name: scrcpy
    /// treats a leading "+" (force stop) and "?" (search by name) specially.
    static func startApp(_ package: String) -> Data {
        let bytes = Data(package.utf8).prefix(255)
        return Data([16, UInt8(bytes.count)]) + bytes
    }

    /// Resizes an app's virtual display (flex display) to the window, in pixels.
    static func resizeDisplay(width: Int, height: Int) -> Data {
        var d = Data([21])
        d.appendBigEndian(UInt16(clamping: width))
        d.appendBigEndian(UInt16(clamping: height))
        return d
    }
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    mutating func appendPosition(_ point: CGPoint, _ size: CGSize) {
        appendBigEndian(Int32(point.x.rounded()))
        appendBigEndian(Int32(point.y.rounded()))
        appendBigEndian(UInt16(size.width))
        appendBigEndian(UInt16(size.height))
    }
}
