import Foundation

/// scrcpy's UHID control messages (client → phone), serialized as in scrcpy's `control_msg.c`.
///
/// These ask the phone to open `/dev/uhid` and register a virtual input device, so Android sees a
/// real mouse and keyboard the way it would see a plugged-in one: the system draws its own
/// pointer, the status bar and the launcher respond, and apps that ignore synthesized taps work.
enum UhidInput {
    static let pointerID: UInt16 = 1
    static let keyboardID: UInt16 = 2

    /// A relative pointer: three buttons, five padding bits, then X, Y and wheel as signed bytes.
    private static let pointerDescriptor: [UInt8] = [
        0x05, 0x01,        // Usage Page (Generic Desktop)
        0x09, 0x02,        // Usage (Mouse)
        0xA1, 0x01,        // Collection (Application)
        0x09, 0x01,        //   Usage (Pointer)
        0xA1, 0x00,        //   Collection (Physical)
        0x05, 0x09,        //     Usage Page (Button)
        0x19, 0x01,        //     Usage Minimum (1)
        0x29, 0x03,        //     Usage Maximum (3)
        0x15, 0x00, 0x25, 0x01,
        0x95, 0x03, 0x75, 0x01,
        0x81, 0x02,        //     Input (Data, Variable, Absolute) — the three buttons
        0x95, 0x01, 0x75, 0x05,
        0x81, 0x03,        //     Input (Constant) — padding to a whole byte
        0x05, 0x01,        //     Usage Page (Generic Desktop)
        0x09, 0x30,        //     Usage (X)
        0x09, 0x31,        //     Usage (Y)
        0x09, 0x38,        //     Usage (Wheel)
        0x15, 0x81, 0x25, 0x7F,
        0x75, 0x08, 0x95, 0x03,
        0x81, 0x06,        //     Input (Data, Variable, Relative)
        0xC0,              //   End Collection
        0xC0,              // End Collection
    ]

    /// A boot keyboard: a modifier bitmap, one reserved byte, and six key slots.
    private static let keyboardDescriptor: [UInt8] = [
        0x05, 0x01,        // Usage Page (Generic Desktop)
        0x09, 0x06,        // Usage (Keyboard)
        0xA1, 0x01,        // Collection (Application)
        0x05, 0x07,        //   Usage Page (Keyboard)
        0x19, 0xE0, 0x29, 0xE7,
        0x15, 0x00, 0x25, 0x01,
        0x75, 0x01, 0x95, 0x08,
        0x81, 0x02,        //   Input — the eight modifier bits
        0x95, 0x01, 0x75, 0x08,
        0x81, 0x03,        //   Input (Constant) — the reserved byte
        0x95, 0x06, 0x75, 0x08,
        0x15, 0x00, 0x25, 0x65,
        0x05, 0x07, 0x19, 0x00, 0x29, 0x65,
        0x81, 0x00,        //   Input (Data, Array) — six keys at once
        0xC0,              // End Collection
    ]

    /// The report a pressed-key report holds at most; further keys are dropped, as on real hardware.
    static let maxKeysDown = 6

    static func createPointer() -> Data {
        create(id: pointerID, name: "Brêge Pointer", product: 0x0001, descriptor: pointerDescriptor)
    }

    static func createKeyboard() -> Data {
        create(id: keyboardID, name: "Brêge Keyboard", product: 0x0002, descriptor: keyboardDescriptor)
    }

    /// Movement is in HID units; the phone's own pointer acceleration applies on top.
    static func move(dx: Int, dy: Int, wheel: Int = 0, buttons: UInt8 = 0) -> Data {
        func clamped(_ value: Int) -> UInt8 { UInt8(bitPattern: Int8(max(-127, min(127, value)))) }
        return input(id: pointerID, report: Data([buttons, clamped(dx), clamped(dy), clamped(wheel)]))
    }

    /// `keys` holds the HID usages currently held down, `modifiers` the shift/control/alt/meta bits.
    static func keys(modifiers: UInt8, down keys: [UInt8]) -> Data {
        var report = Data([modifiers, 0])
        report.append(contentsOf: keys.prefix(maxKeysDown))
        report.append(contentsOf: [UInt8](repeating: 0, count: maxKeysDown - min(keys.count, maxKeysDown)))
        return input(id: keyboardID, report: report)
    }

    static func destroy(_ id: UInt16) -> Data {
        var d = Data([14])
        d.appendBigEndian(id)
        return d
    }

    /// UHID_CREATE: the id the later reports use, a vendor and product id so Android can tell the
    /// two devices apart, the name shown in the phone's input device list, and the report descriptor.
    private static func create(id: UInt16, name: String, product: UInt16, descriptor: [UInt8]) -> Data {
        let bytes = Data(name.utf8).prefix(255)
        var d = Data([12])
        d.appendBigEndian(id)
        d.appendBigEndian(UInt16(0xB7E6))  // vendor, matching the Brêge service id
        d.appendBigEndian(product)
        d.append(UInt8(bytes.count))
        d.append(bytes)
        d.appendBigEndian(UInt16(descriptor.count))
        d.append(contentsOf: descriptor)
        return d
    }

    private static func input(id: UInt16, report: Data) -> Data {
        var d = Data([13])
        d.appendBigEndian(id)
        d.appendBigEndian(UInt16(report.count))
        d.append(report)
        return d
    }
}

private extension Data {
    mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
