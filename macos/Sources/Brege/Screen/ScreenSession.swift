import Foundation

/// One phone-screen session: pushes the scrcpy server over adb and speaks its
/// protocol (scrcpy `doc/develop.md`) on three tunnelled sockets — video, audio and control.
/// A session mirrors the phone display, runs one app on a virtual display that follows the
/// window size, or shows Android's desktop mode on a simulated secondary display.
final class ScreenSession: @unchecked Sendable {
    static let serverVersion = "4.1"
    /// One jar per session: the server deletes its own jar (`cleanup=true`) shortly after start.
    private static func remoteJar(scid: String) -> String { "/data/local/tmp/brege-server-\(scid).jar" }
    private static let phonePackage = "app.brege"

    /// Only one session plays the phone's audio; the others would duplicate it.
    private static let audioLock = NSLock()
    private static var audioOwner: UUID?

    /// Identifies this session; unlike ObjectIdentifier it is never reused by a later session.
    let id = UUID()

    /// Initial virtual display for an app, resized to the window once it is shown.
    struct VirtualDisplay {
        let package: String
        var width: Int
        var height: Int
        var dpi: Int
    }

    /// Android only offers desktop windowing on displays it treats as external. Its virtual
    /// displays do not qualify ("desktop ineligible"); the developer option "Simulate secondary
    /// displays" (`overlay_display_devices`) does, so Desktop Mode streams that display.
    struct DesktopDisplay {
        var width: Int
        var height: Int
        var dpi: Int
    }

    /// The phone is a tablet: its apps are laid out for a larger window.
    var onLargeScreen: (() -> Void)?

    private static let overlaySetting = "overlay_display_devices"
    /// Phones with a simulated display from Brêge → the setting's value before, to restore.
    private static let desktopLock = NSLock()
    private static var desktopRestore: [String: (adb: Adb, previous: String)] = [:]

    enum VideoCodec: String {
        case h265, h264
    }

    struct VideoPacket {
        let data: Data
        let isConfig: Bool
        let isKeyFrame: Bool
    }

    enum Failure: LocalizedError {
        case notConnected
        case desktopAlreadyOpen
        case serverMissing
        case serverFailed(String)
        case unsupportedCodec(UInt32)

        var errorDescription: String? {
            switch self {
            case .notConnected: return "The phone is not connected to Brêge."
            case .desktopAlreadyOpen: return "Desktop Mode is already open for this phone."
            case .serverMissing: return "The screen server is missing from Brêge.app."
            case let .serverFailed(detail): return "The phone could not start screen sharing. \(detail)"
            case let .unsupportedCodec(id): return "Unsupported video stream (\(String(id, radix: 16)))."
            }
        }
    }

    // Callbacks run on the session's own threads.
    var onStatus: ((String) -> Void)?
    var onVideoCodec: ((VideoCodec) -> Void)?
    var onVideoSize: ((CGSize) -> Void)?
    var onVideoPacket: ((VideoPacket) -> Void)?
    var onAudio: ((Data) -> Void)?
    var onClipboard: ((String) -> Void)?
    /// The phone was asleep, so the session woke it and turned its own panel dark.
    var onPhoneDisplayTurnedOff: (() -> Void)?
    var onEnd: ((Error?) -> Void)?
    /// Asks the phone (over Brêge) to switch wireless debugging on; returns false if it could not ask.
    var switchOnWirelessDebugging: (() -> Bool)?

    private let adb: Adb
    private let phoneIP: String
    private let display: VirtualDisplay?
    private let desktop: DesktopDisplay?
    private let lock = NSLock()
    private var server: Process?
    private var serial: String?
    private var forwardPort: Int?
    private var sockets: [TunnelSocket] = []
    private var control: TunnelSocket?
    private var stopped = false
    private var ended = false
    /// Control messages are written here, in order, so input handlers never block on the socket.
    private let controlQueue = DispatchQueue(label: "app.brege.screen-control")
    /// Bytes waiting in `controlQueue` (guarded by `lock`).
    private var queuedControlBytes = 0
    private static let maxQueuedControlBytes = 1 << 20
    /// Whether the current attempt received a video frame (session thread only).
    private var videoFrameArrived = false

    init(adb: Adb, phoneIP: String, display: VirtualDisplay? = nil, desktop: DesktopDisplay? = nil) {
        self.adb = adb
        self.phoneIP = phoneIP
        self.display = display
        self.desktop = desktop
    }

    var hasAudio: Bool {
        Self.audioLock.lock()
        defer { Self.audioLock.unlock() }
        return Self.audioOwner == id
    }

    private func claimAudio() -> Bool {
        Self.audioLock.lock()
        defer { Self.audioLock.unlock() }
        if Self.audioOwner == nil { Self.audioOwner = id }
        return Self.audioOwner == id
    }

    private func releaseAudio() {
        Self.audioLock.lock()
        if Self.audioOwner == id { Self.audioOwner = nil }
        Self.audioLock.unlock()
    }

    /// Connects and starts streaming on a background thread; failures arrive through `onEnd`.
    func start(maxSize: Int = 1920) {
        Thread.detachNewThread { [self] in
            // stop() only cleans up what was acquired before it; release what came after.
            defer { if isStopped { teardown() } }
            do {
                do {
                    try run(codec: .h265, maxSize: maxSize)
                } catch Failure.serverFailed where !isStopped {
                    // Some phones have no usable H.265 encoder (it fails before the codec header,
                    // or when configured or started, before the first frame).
                    teardown()
                    try run(codec: .h264, maxSize: maxSize)
                }
            } catch {
                finish(error)
            }
        }
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        teardown()
        finish(nil)
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    // MARK: Control messages

    /// Queues a control message; safe to call from the main thread.
    func send(_ message: Data) {
        lock.lock()
        let control = control
        lock.unlock()
        guard let control else { return }
        send(message, via: control)
    }

    /// Writes on the control queue, in order. If the phone stops reading and messages pile up,
    /// new ones are dropped rather than growing without bound.
    private func send(_ message: Data, via control: TunnelSocket) {
        lock.lock()
        if queuedControlBytes > 0, queuedControlBytes + message.count > Self.maxQueuedControlBytes {
            lock.unlock()
            return
        }
        queuedControlBytes += message.count
        lock.unlock()
        controlQueue.async { [self] in
            try? control.write(message)
            lock.lock()
            queuedControlBytes -= message.count
            lock.unlock()
        }
    }

    // MARK: Connection

    private func run(codec: VideoCodec, maxSize: Int) throws {
        guard let jar = Bundle.main.url(forResource: "scrcpy-server", withExtension: "jar") else { throw Failure.serverMissing }
        onStatus?("Connecting to wireless debugging…")
        let serial = try connectSwitchingOn()
        guard !isStopped else { return }
        // Lets the phone switch wireless debugging back on by itself next time (see WirelessDebugging.kt).
        _ = try? adb.run(["-s", serial, "shell", "pm", "grant", Self.phonePackage, "android.permission.WRITE_SECURE_SETTINGS"], timeout: 10)

        onStatus?("Starting screen sharing…")
        // Secondary displays only draw while the phone is awake.
        var phoneAsleep = false
        if display != nil, Self.isLargeScreen(try adb.run(["-s", serial, "shell", "wm size; wm density"])) {
            onLargeScreen?()
        }
        if display != nil || desktop != nil {
            phoneAsleep = try !adb.run(["-s", serial, "shell", "dumpsys", "power"]).contains("mWakefulness=Awake")
        }
        var desktopDisplayID: Int?
        if let desktop {
            onStatus?("Starting Desktop Mode…")
            lock.lock()
            self.serial = serial
            lock.unlock()
            desktopDisplayID = try createDesktopDisplay(serial: serial, desktop)
        }
        let scid = String(format: "%08x", UInt32.random(in: 1..<0x7FFF_FFFF))
        let remoteJar = Self.remoteJar(scid: scid)
        try adb.run(["-s", serial, "push", jar.path, remoteJar], timeout: 60)
        guard !isStopped else { return }
        let forward = try adb.run(["-s", serial, "forward", "tcp:0", "localabstract:scrcpy_\(scid)"])
        guard let port = Int(forward.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw Failure.serverFailed(forward)
        }
        lock.lock()
        self.serial = serial
        forwardPort = port
        lock.unlock()
        guard !isStopped else { return }

        let log = FileManager.default.temporaryDirectory.appendingPathComponent("brege-screen-\(scid).log")
        // Only one session plays the phone's audio; the others would duplicate it.
        let withAudio = claimAudio()
        var arguments = [
            "-s", serial, "shell",
            "CLASSPATH=\(remoteJar)", "app_process", "/", "com.genymobile.scrcpy.Server", Self.serverVersion,
            "scid=\(scid)", "log_level=info", "tunnel_forward=true",
            "video_codec=\(codec.rawValue)", "max_fps=60",
            "audio=\(withAudio)", "audio_codec=raw",
            "control=true", "clipboard_autosync=false", "cleanup=true",
        ]
        if let desktopDisplayID {
            arguments += ["display_id=\(desktopDisplayID)", "video_bit_rate=16000000", "keep_active=true", "power_on=\(phoneAsleep)"]
        } else if let display {
            // The app starts with a START_APP control message once connected.
            arguments += [
                "new_display=\(display.width)x\(display.height)/\(display.dpi)", "flex_display=true", "video_bit_rate=8000000",
                // System decorations must stay on: without them the Pixel renders no frames.
                "display_ime_policy=hide", "keep_active=true", "power_on=\(phoneAsleep)",
            ]
        } else {
            arguments += ["max_size=\(maxSize)", "video_bit_rate=8000000", "stay_awake=true", "power_on=true"]
        }
        let server = try adb.spawn(arguments, log: log)
        lock.lock()
        self.server = server
        lock.unlock()

        // The forward tunnel accepts connections even before the server listens; the server's
        // dummy byte on the first socket shows that it really accepted.
        let video = try connectFirstSocket(port: port, server: server, log: log)
        let audio = withAudio ? try TunnelSocket(port: port) : nil
        let control = try TunnelSocket(port: port)
        lock.lock()
        sockets = [video, control] + (audio.map { [$0] } ?? [])
        self.control = control
        lock.unlock()
        guard !isStopped else { return }

        let videoCodecID: UInt32
        let audioCodecID: UInt32?
        do {
            _ = try video.read(64) // device name
            videoCodecID = try video.readUInt32()
            audioCodecID = try audio?.readUInt32()
        } catch where !isStopped {
            // A server without a usable encoder closes the sockets before the codec header.
            let deadline = Date().addingTimeInterval(2)
            while server.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            throw Failure.serverFailed(Self.lastError(in: log) ?? "The video encoder failed.")
        }
        switch videoCodecID {
        case 0x6832_3635: onVideoCodec?(.h265)
        case 0x6832_3634: onVideoCodec?(.h264)
        case 0, 1: throw Failure.serverFailed(Self.lastError(in: log) ?? "The video encoder failed.")
        default: throw Failure.unsupportedCodec(videoCodecID)
        }
        onStatus?("")
        if phoneAsleep || desktop != nil {
            // Keep the phone dark: only the Mac window shows the display. In Desktop Mode the
            // simulated display also floats over the phone's own screen.
            send(ScreenControl.setDisplayPower(false), via: control)
            onPhoneDisplayTurnedOff?()
        }
        if let package = display?.package {
            Thread.detachNewThread { [self] in
                startApp(package, serial: serial, log: log, control: control)
            }
        }

        if let audio, audioCodecID == 0x0072_6177 { // "raw": 48 kHz, 16-bit stereo PCM
            Thread.detachNewThread { [self] in
                try? readAudio(audio)
            }
        }
        Thread.detachNewThread { [self] in
            readDeviceMessages(control)
        }
        videoFrameArrived = false
        do {
            try readVideo(video)
            finish(nil)
        } catch {
            guard !isStopped else {
                finish(nil)
                return
            }
            if codec == .h265, !videoFrameArrived {
                // The encoder can also fail after the codec header, when it is configured or
                // started: the server then logs an error and exits. Let start() retry with H.264.
                let deadline = Date().addingTimeInterval(2)
                while server.isRunning, Date() < deadline, !isStopped { Thread.sleep(forTimeInterval: 0.1) }
                if let detail = Self.lastError(in: log), !isStopped {
                    throw Failure.serverFailed(detail)
                }
            }
            finish(isStopped ? nil : Failure.serverFailed(Self.lastError(in: log) ?? "The connection ended."))
        }
    }

    /// Starts the app filling its display. Tablets with desktop windowing on other displays
    /// would open it as a small floating window, often partly outside the display, so the app is
    /// started in fullscreen mode (`am start --windowingMode 1`) where possible; otherwise with
    /// scrcpy's start-app message.
    private func startApp(_ package: String, serial: String, log: URL, control: TunnelSocket) {
        // The server logs the display only once the encoder is configured and the display
        // created, which is after the codec header.
        var displayID = Self.displayID(in: log)
        let deadline = Date().addingTimeInterval(3)
        while displayID == nil, Date() < deadline {
            guard !isStopped else { return }
            Thread.sleep(forTimeInterval: 0.1)
            displayID = Self.displayID(in: log)
        }
        guard !isStopped else { return }
        if let displayID,
           let resolved = try? adb.run(["-s", serial, "shell", "cmd", "package", "resolve-activity", "--brief",
                                        "-a", "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER", package]),
           let component = resolved.split(separator: "\n").last.map({ $0.trimmingCharacters(in: .whitespaces) }),
           component.hasPrefix(package + "/"),
           component.range(of: #"^[A-Za-z0-9_.]+/[A-Za-z0-9_.$]+$"#, options: .regularExpression) != nil,
           !isStopped,
           let started = try? adb.run(["-s", serial, "shell", "am", "start", "--display", String(displayID),
                                       "--windowingMode", "1", "-n", "'\(component)'"]),
           started.contains("Starting:"), !started.contains("Error") {
            return
        }
        send(ScreenControl.startApp(package), via: control)
    }

    /// The virtual display's id, from the server's "New display: 1680x1640/320 (id=15)" line.
    private static func displayID(in log: URL) -> Int? {
        guard let text = try? String(contentsOf: log, encoding: .utf8),
              let match = text.range(of: #"New display: .*\(id=(\d+)\)"#, options: .regularExpression) else { return nil }
        let line = text[match]
        guard let open = line.range(of: "(id="), let close = line.lastIndex(of: ")") else { return nil }
        return Int(line[open.upperBound..<close])
    }

    /// Tablets (smallest width of 600 dp or more), from `wm size; wm density`.
    static func isLargeScreen(_ output: String) -> Bool {
        func last(_ label: String) -> String? {
            output.split(separator: "\n").last { $0.contains(label) }
                .flatMap { $0.split(separator: ":").last }
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }
        let size = (last("Override size") ?? last("Physical size"))?.split(separator: "x").compactMap { Int($0) } ?? []
        guard size.count == 2, let density = Int(last("Override density") ?? last("Physical density") ?? ""), density > 0
        else { return false }
        return min(size[0], size[1]) * 160 / density >= 600
    }

    /// Sets up the simulated display and returns its id once Android has added it.
    private func createDesktopDisplay(serial: String, _ desktop: DesktopDisplay) throws -> Int {
        Self.desktopLock.lock()
        if Self.desktopRestore[serial] != nil {
            Self.desktopLock.unlock()
            throw Failure.desktopAlreadyOpen
        }
        Self.desktopLock.unlock()
        let previous = try adb.run(["-s", serial, "shell", "settings", "get", "global", Self.overlaySetting])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        Self.desktopLock.lock()
        Self.desktopRestore[serial] = (adb, previous)
        Self.desktopLock.unlock()
        try adb.run(["-s", serial, "shell", "settings", "put", "global", Self.overlaySetting,
                     "\(desktop.width)x\(desktop.height)/\(desktop.dpi)"])
        let pattern = try NSRegularExpression(pattern: #"^Display id (\d+):.*uniqueId "overlay:1""#, options: .anchorsMatchLines)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, !isStopped {
            let displays = try adb.run(["-s", serial, "shell", "cmd", "display", "get-displays"])
            if let match = pattern.firstMatch(in: displays, range: NSRange(displays.startIndex..., in: displays)),
               let range = Range(match.range(at: 1), in: displays), let id = Int(displays[range]) {
                return id
            }
            Thread.sleep(forTimeInterval: 0.3)
        }
        throw Failure.serverFailed("Android did not create the desktop display.")
    }

    /// Removes the simulated display for one phone (apps on it move to the phone screen).
    private static func restoreDesktopDisplay(serial: String) {
        desktopLock.lock()
        let entry = desktopRestore.removeValue(forKey: serial)
        desktopLock.unlock()
        guard let entry else { return }
        let arguments = entry.previous.isEmpty || entry.previous == "null"
            ? ["-s", serial, "shell", "settings", "delete", "global", overlaySetting]
            // adb shell joins its arguments into one command line: quote the stored value.
            : ["-s", serial, "shell", "settings", "put", "global", overlaySetting,
               "'" + entry.previous.replacingOccurrences(of: "'", with: "'\\''") + "'"]
        _ = try? entry.adb.run(arguments, timeout: 5)
    }

    /// On quit: remove every simulated display Brêge created.
    static func restoreAllDesktopDisplays() {
        desktopLock.lock()
        let serials = Array(desktopRestore.keys)
        desktopLock.unlock()
        serials.forEach { restoreDesktopDisplay(serial: $0) }
    }

    /// Connects over adb; if wireless debugging is off, asks the phone to switch it on and waits.
    private func connectSwitchingOn() throws -> String {
        do {
            return try adb.connect(phoneIP: phoneIP)
        } catch Adb.Failure.wirelessDebuggingOff {
            guard switchOnWirelessDebugging?() == true else { throw Adb.Failure.wirelessDebuggingOff }
            onStatus?("Switching on wireless debugging…")
            let deadline = Date().addingTimeInterval(12)
            while Date() < deadline, !isStopped {
                Thread.sleep(forTimeInterval: 1)
                if let serial = try? adb.connect(phoneIP: phoneIP) { return serial }
            }
            throw Adb.Failure.wirelessDebuggingOff
        }
    }

    private func connectFirstSocket(port: Int, server: Process, log: URL) throws -> TunnelSocket {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !isStopped {
            if !server.isRunning {
                throw Failure.serverFailed(Self.lastError(in: log) ?? "")
            }
            let socket = try TunnelSocket(port: port)
            if (try? socket.read(1)) != nil { return socket }
            socket.close()
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw Failure.serverFailed(Self.lastError(in: log) ?? "The phone did not respond.")
    }

    private func readVideo(_ socket: TunnelSocket) throws {
        while true {
            let header = try socket.read(12)
            let flags = header.bigEndianUInt64(at: 0)
            if flags & (1 << 63) != 0 {
                let size = CGSize(width: CGFloat(header.bigEndianUInt32(at: 4)), height: CGFloat(header.bigEndianUInt32(at: 8)))
                onVideoSize?(size)
                continue
            }
            let length = Int(header.bigEndianUInt32(at: 8))
            let payload = try socket.read(length)
            if flags & (1 << 62) == 0 { videoFrameArrived = true }
            onVideoPacket?(VideoPacket(data: payload, isConfig: flags & (1 << 62) != 0, isKeyFrame: flags & (1 << 61) != 0))
        }
    }

    private func readAudio(_ socket: TunnelSocket) throws {
        while true {
            let header = try socket.read(12)
            let payload = try socket.read(Int(header.bigEndianUInt32(at: 8)))
            if header.bigEndianUInt64(at: 0) & (1 << 62) == 0 { onAudio?(payload) }
        }
    }

    private func readDeviceMessages(_ socket: TunnelSocket) {
        while let type = try? socket.read(1).first {
            switch type {
            case 0: // clipboard text
                guard let length = try? socket.readUInt32(), let text = try? socket.read(Int(length)) else { return }
                if let string = String(data: text, encoding: .utf8) { onClipboard?(string) }
            case 1: // clipboard acknowledgement
                guard (try? socket.read(8)) != nil else { return }
            default:
                return // unknown message: its length is unknown, stop reading
            }
        }
    }

    private func teardown() {
        lock.lock()
        let sockets = sockets
        let server = server
        let serial = serial
        let port = forwardPort
        self.sockets = []
        control = nil
        self.server = nil
        forwardPort = nil
        lock.unlock()

        sockets.forEach { $0.close() }
        server?.terminate()
        releaseAudio()
        if desktop != nil, let serial {
            Self.restoreDesktopDisplay(serial: serial)
        }
        if let serial, let port {
            _ = try? adb.run(["-s", serial, "forward", "--remove", "tcp:\(port)"], timeout: 5)
        }
    }

    private func finish(_ error: Error?) {
        lock.lock()
        if ended {
            lock.unlock()
            return
        }
        ended = true
        lock.unlock()
        teardown()
        onEnd?(error)
    }

    private static func lastError(in log: URL) -> String? {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").last { $0.contains("ERROR") }
            .map { $0.replacingOccurrences(of: "[server] ERROR: ", with: "") }
    }
}

/// A blocking TCP socket to the adb tunnel on 127.0.0.1.
final class TunnelSocket: @unchecked Sendable {
    private let fd: Int32

    init(port: Int) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            Darwin.close(fd)
            throw POSIXError(.ECONNREFUSED)
        }
    }

    func read(_ count: Int) throws -> Data {
        var data = Data(count: count)
        var filled = 0
        while filled < count {
            let n = data.withUnsafeMutableBytes { buffer in
                recv(fd, buffer.baseAddress! + filled, count - filled, 0)
            }
            guard n > 0 else { throw POSIXError(.ECONNRESET) }
            filled += n
        }
        return data
    }

    func readUInt32() throws -> UInt32 {
        try read(4).bigEndianUInt32(at: 0)
    }

    func write(_ data: Data) throws {
        var sent = 0
        while sent < data.count {
            let n = data.withUnsafeBytes { buffer in
                send(fd, buffer.baseAddress! + sent, data.count - sent, 0)
            }
            guard n > 0 else { throw POSIXError(.EPIPE) }
            sent += n
        }
    }

    /// Unblocks readers; the descriptor is released on deinit.
    func close() {
        shutdown(fd, SHUT_RDWR)
    }

    deinit {
        Darwin.close(fd)
    }
}

extension Data {
    func bigEndianUInt32(at offset: Int) -> UInt32 {
        self[startIndex + offset..<startIndex + offset + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }

    func bigEndianUInt64(at offset: Int) -> UInt64 {
        self[startIndex + offset..<startIndex + offset + 8].reduce(0) { $0 << 8 | UInt64($1) }
    }
}
