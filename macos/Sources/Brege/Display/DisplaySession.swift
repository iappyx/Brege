import CoreMedia
import Foundation
import VirtualDisplay

/// The Mac's second display, on a tablet: a display macOS believes in, captured, encoded and sent
/// over the link (`docs/brege-second-display-plan.md`).
///
/// The display is created first and taken away last. Everything between — capture, encoder, stream —
/// can fail and be retried without macOS ever seeing a screen appear and vanish, which is what
/// would scatter the user's windows.
@MainActor
final class DisplaySession {
    enum Failure: LocalizedError {
        case unsupported
        case notCreated

        var errorDescription: String? {
            switch self {
            case .unsupported:
                return "This version of macOS does not let Brêge add a display."
            case .notCreated:
                return "macOS would not add the display."
            }
        }
    }

    /// Matches the flags the core and the camera's stream use: 1 = codec config, 2 = key frame.
    private static let configFlag: UInt8 = 1
    private static let keyFrameFlag: UInt8 = 2

    /// What the tablet said it can decode, chosen when the session was made.
    let codec: DisplayEncoder.Codec
    /// The name the protocol uses for it.
    var codecName: String { codec == .hevc ? "h265" : "h264" }
    let refreshHz = 60

    private(set) var width = 1920
    private(set) var height = 1080
    /// 2 means macOS draws at twice the size and the tablet shows it as a Retina screen.
    private(set) var scale = 2

    private let send: @Sendable (UInt8, UInt64, Data) -> Bool
    /// Frames queued and frames the link had no room for, read from the core.
    private let stats: @Sendable () -> (sent: UInt64, dropped: UInt64)
    private var display: BRGVirtualDisplay?
    private var capture: DisplayCapture?
    private var encoder: DisplayEncoder?
    private var gate = Gate()

    /// Open while frames may be encoded.
    ///
    /// The capture queue holds the encoder itself and is still calling into it when a session is
    /// stopped, so closing this is the one thing that can be done immediately: the encoder cannot
    /// be taken apart until that queue has actually come to a stop.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var open = true

        var isOpen: Bool {
            lock.lock()
            defer { lock.unlock() }
            return open
        }

        func close() {
            lock.lock()
            open = false
            lock.unlock()
        }
    }

    init(codec: DisplayEncoder.Codec,
         stats: @escaping @Sendable () -> (sent: UInt64, dropped: UInt64),
         send: @escaping @Sendable (UInt8, UInt64, Data) -> Bool) {
        self.codec = codec
        self.stats = stats
        self.send = send
    }

    var displayID: CGDirectDisplayID { display?.displayID ?? 0 }
    var isRunning: Bool { display != nil }

    /// Adds the display. Done before the tablet is told anything, so the offer can carry the size
    /// macOS actually gave us rather than the one we asked for.
    func createDisplay(width: Int, height: Int, scale: Int) throws {
        guard BRGVirtualDisplay.isSupported else { throw Failure.unsupported }
        // H.264 works in macroblocks: an odd number of pixels either way is a frame no encoder
        // will take.
        let even = { (value: Int) in value - value % 2 }
        guard let made = BRGVirtualDisplay(name: "Brêge Display", width: UInt32(even(width)),
                                           height: UInt32(even(height)), refreshRate: Double(refreshHz),
                                           hiDPI: scale > 1) else {
            throw Failure.notCreated
        }
        display = made
        self.width = even(width)
        self.height = even(height)
        self.scale = scale
    }

    /// Bitrate for this many pixels at this frame rate.
    ///
    /// Roughly 0.08 bits per pixel per frame, which is what the first 1080p measurements came out
    /// at (10.5 Mbit/s for moving content) — so a bigger screen is given proportionally more rather
    /// than being squeezed into a figure that happened to suit 1080p.
    /// H.265 is given two thirds: it carries the same picture in appreciably less, and the
    /// headroom is worth more on Wi-Fi than the last of the quality.
    var suggestedBitsPerSecond: Int {
        let perPixel = codec == .hevc ? 0.053 : 0.08
        let estimate = Double(width * height) * perPixel * Double(refreshHz)
        return Int(min(40_000_000, max(6_000_000, estimate)))
    }

    /// Starts capturing and sending. The stream to the tablet must already be open.
    func startStreaming(bitsPerSecond: Int = 20_000_000) async throws {
        guard let display else { throw Failure.notCreated }
        let send = self.send

        let encoder = try DisplayEncoder(width: width, height: height, codec: codec,
                                         bitsPerSecond: bitsPerSecond, framesPerSecond: refreshHz) { frame in
            let pts = UInt64(max(0, frame.presentationTime.seconds * 1_000_000))
            // The parameter sets go as their own config packet rather than inside the key frame, so
            // the tablet can set its decoder up before any picture arrives — and so a tablet that
            // joins late is one key frame away from decoding instead of waiting for a new session.
            if let sets = frame.parameterSets {
                _ = send(Self.configFlag, pts, sets)
            }
            _ = send(frame.isKeyframe ? Self.keyFrameFlag : 0, pts, frame.bytes)
        }
        // Nothing on the tablet can start from a mid-stream frame.
        encoder.requestKeyframe()

        let gate = Gate()
        self.gate = gate
        let capture = DisplayCapture { frame in
            // Encoded on the capture queue: a hop to the main thread would add latency to every
            // frame, and the main thread is where the rest of the app lives.
            guard gate.isOpen, frame.isNew,
                  let buffer = CMSampleBufferGetImageBuffer(frame.sample) else { return }
            encoder.encode(buffer, presentationTime: CMSampleBufferGetPresentationTimeStamp(frame.sample))
        }
        try await capture.start(displayID: display.displayID, width: width, height: height,
                                framesPerSecond: refreshHz)
        self.encoder = encoder
        self.capture = capture
        startAdapting(ceiling: bitsPerSecond)
    }

    // MARK: Keeping up with the link

    /// Never go below this: under it the picture is too poor to be worth sending at all, and the
    /// honest thing is a bad picture rather than none.
    private static let floorBitsPerSecond = 4_000_000
    /// Long enough for a burst to show up in the counters, short enough to react within a sentence
    /// of typing.
    private static let adaptInterval = 2.0

    private var adapter: Timer?
    private var ceilingBitsPerSecond = 0
    private var currentBitsPerSecond = 0
    private var lastSent: UInt64 = 0
    private var lastDropped: UInt64 = 0
    private var calmWindows = 0

    /// Follows the link rather than hoping: frames the network had no room for are counted in the
    /// core, and a bitrate that produces them is one the link cannot carry.
    private func startAdapting(ceiling: Int) {
        ceilingBitsPerSecond = ceiling
        currentBitsPerSecond = ceiling
        let counts = stats()
        lastSent = counts.sent
        lastDropped = counts.dropped
        calmWindows = 0
        adapter?.invalidate()
        adapter = Timer.scheduledTimer(withTimeInterval: Self.adaptInterval, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.adapt() }
        }
    }

    private func adapt() {
        guard let encoder else { return }
        let counts = stats()
        let sent = counts.sent >= lastSent ? counts.sent - lastSent : 0
        let dropped = counts.dropped >= lastDropped ? counts.dropped - lastDropped : 0
        lastSent = counts.sent
        lastDropped = counts.dropped
        let total = sent + dropped
        guard total > 0 else { return }

        let lost = Double(dropped) / Double(total)
        if lost > 0.02 {
            // Down quickly: a backlog is already being paid for in latency, so there is nothing to
            // gain by easing off gently.
            let lowered = max(Self.floorBitsPerSecond, Int(Double(currentBitsPerSecond) * 0.75))
            guard lowered != currentBitsPerSecond else { return }
            currentBitsPerSecond = lowered
            encoder.setBitsPerSecond(lowered)
            calmWindows = 0
            DisplayLog.write("link dropped \(dropped) of \(total) frames — "
                + "\(lowered / 1_000_000) Mbit/s")
        } else if dropped == 0 {
            // Up slowly, and only after a few quiet windows: climbing back the moment one window
            // looks good is how a link ends up oscillating.
            calmWindows += 1
            guard calmWindows >= 3, currentBitsPerSecond < ceilingBitsPerSecond else { return }
            let raised = min(ceilingBitsPerSecond, Int(Double(currentBitsPerSecond) * 1.15))
            currentBitsPerSecond = raised
            encoder.setBitsPerSecond(raised)
            calmWindows = 0
            DisplayLog.write("the link is keeping up — \(raised / 1_000_000) Mbit/s")
        }
    }

    /// The tablet asked for a fresh start — after a stall, or having only just begun to decode.
    func requestKeyframe() {
        encoder?.requestKeyframe()
    }

    /// Stops in an order the capture queue can survive.
    ///
    /// Invalidating a VideoToolbox session while a frame is in flight is not safe, and at 60 fps a
    /// frame is nearly always in flight. So the gate shuts first, which stops new frames at once;
    /// then the stream is actually awaited; and only then is the encoder taken apart and the
    /// display handed back, so macOS moves the windows once and not twice.
    func stop() {
        adapter?.invalidate()
        adapter = nil
        gate.close()
        let capture = self.capture
        let encoder = self.encoder
        let display = self.display
        self.capture = nil
        self.encoder = nil
        self.display = nil
        Task { @MainActor in
            await capture?.stop()
            encoder?.finish()
            display?.invalidate()
        }
    }
}
