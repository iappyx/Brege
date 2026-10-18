import Foundation

/// A scrcpy session with neither video nor audio: only the control socket, used to register the
/// virtual pointer and keyboard on the phone and to feed them reports.
///
/// The phone's own screen stays as it is — nothing is mirrored and no window opens. What the Mac
/// sends arrives as movement from a real input device, so the phone draws its own pointer.
final class PointerSession: @unchecked Sendable {
    enum Failure: LocalizedError {
        case serverMissing
        case serverFailed(String)

        var errorDescription: String? {
            switch self {
            case .serverMissing:
                return "The phone-control helper is missing from this copy of Brêge."
            case let .serverFailed(detail):
                return detail.isEmpty ? "The phone did not accept the connection." : detail
            }
        }
    }

    private static let serverVersion = ScreenSession.serverVersion
    private static let phonePackage = "app.brege"

    private let adb: Adb
    private let phoneIP: String
    private let lock = NSLock()
    private let controlQueue = DispatchQueue(label: "app.brege.pointer.control")

    private var server: Process?
    private var control: TunnelSocket?
    private var serial: String?
    private var forwardPort: Int?
    private var stopped = false

    var onStatus: ((String) -> Void)?
    var onReady: (() -> Void)?
    /// The phone's screen in pixels, so the Mac can tell when the pointer reaches its far side.
    var onScreenSize: ((Int, Int) -> Void)?
    var onEnd: ((Error?) -> Void)?
    /// Asks the phone to switch wireless debugging on, as the screen session does.
    var switchOnWirelessDebugging: (() -> Bool)?

    init(adb: Adb, phoneIP: String) {
        self.adb = adb
        self.phoneIP = phoneIP
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    /// Connects on a background thread; failures arrive through `onEnd`.
    func start() {
        Thread.detachNewThread { [self] in
            do {
                try run()
            } catch {
                teardown()
                finish(error)
            }
        }
    }

    func stop() {
        lock.lock()
        let hadControl = control != nil
        stopped = true
        lock.unlock()
        // Let the phone drop the virtual devices before the socket closes, so no key stays down.
        if hadControl {
            send(UhidInput.keys(modifiers: 0, down: []))
            send(UhidInput.destroy(UhidInput.keyboardID))
            send(UhidInput.destroy(UhidInput.pointerID))
            controlQueue.sync {}
        }
        teardown()
        finish(nil)
    }

    /// Queues a control message; safe to call from the main thread.
    func send(_ message: Data) {
        lock.lock()
        let control = control
        lock.unlock()
        guard let control else { return }
        controlQueue.async { try? control.write(message) }
    }

    private func run() throws {
        guard let jar = Bundle.main.url(forResource: "scrcpy-server", withExtension: "jar") else {
            throw Failure.serverMissing
        }
        onStatus?("Connecting to wireless debugging…")
        let serial = try connectSwitchingOn()
        guard !isStopped else { return }
        // Lets the phone switch wireless debugging back on by itself next time (see WirelessDebugging.kt).
        _ = try? adb.run(["-s", serial, "shell", "pm", "grant", Self.phonePackage,
                          "android.permission.WRITE_SECURE_SETTINGS"], timeout: 10)

        if let size = try? Self.screenSize(adb: adb, serial: serial) {
            onScreenSize?(size.width, size.height)
        }

        let scid = String(format: "%08x", UInt32.random(in: 1..<0x7FFF_FFFF))
        let remoteJar = "/data/local/tmp/brege-pointer-\(scid).jar"
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

        let log = FileManager.default.temporaryDirectory.appendingPathComponent("brege-pointer-\(scid).log")
        let server = try adb.spawn([
            "-s", serial, "shell",
            "CLASSPATH=\(remoteJar)", "app_process", "/", "com.genymobile.scrcpy.Server", Self.serverVersion,
            "scid=\(scid)", "log_level=info", "tunnel_forward=true",
            "video=false", "audio=false", "control=true", "cleanup=true",
        ], log: log)
        lock.lock()
        self.server = server
        lock.unlock()

        let control = try connectControl(port: port, server: server, log: log)
        lock.lock()
        self.control = control
        lock.unlock()
        guard !isStopped else { return }

        // The devices themselves are registered only while the pointer is actually on the phone,
        // so its cursor does not linger on screen in between (see PointerCapture).
        onStatus?("")
        onReady?()

        // Hold the session open until the server exits or stop() is called.
        while !isStopped, server.isRunning { Thread.sleep(forTimeInterval: 0.25) }
        guard !isStopped else { return }
        teardown()
        finish(Failure.serverFailed(Self.lastError(in: log) ?? ""))
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

    /// The forward tunnel accepts connections before the server listens; with no video or audio the
    /// control socket is the first one, and the server's dummy byte shows it really accepted.
    private func connectControl(port: Int, server: Process, log: URL) throws -> TunnelSocket {
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !isStopped {
            if !server.isRunning { throw Failure.serverFailed(Self.lastError(in: log) ?? "") }
            let socket = try TunnelSocket(port: port)
            if (try? socket.read(1)) != nil { return socket }
            socket.close()
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw Failure.serverFailed(Self.lastError(in: log) ?? "The phone did not respond.")
    }

    private func teardown() {
        lock.lock()
        let control = control
        let server = server
        let serial = serial
        let port = forwardPort
        self.control = nil
        self.server = nil
        self.forwardPort = nil
        lock.unlock()

        control?.close()
        server?.terminate()
        if let serial, let port {
            _ = try? adb.run(["-s", serial, "forward", "--remove", "tcp:\(port)"], timeout: 5)
        }
    }

    private func finish(_ error: Error?) {
        guard let onEnd else { return }
        self.onEnd = nil
        DispatchQueue.main.async { onEnd(error) }
    }

    /// `wm size` prints the physical size, and an override below it when one is set.
    private static func screenSize(adb: Adb, serial: String) throws -> (width: Int, height: Int)? {
        let output = try adb.run(["-s", serial, "shell", "wm", "size"], timeout: 10)
        let line = output.split(separator: "\n").last { $0.contains("size:") }
        guard let pair = line?.split(separator: ":").last?.trimmingCharacters(in: .whitespaces) else { return nil }
        let parts = pair.split(separator: "x")
        guard parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) else { return nil }
        return (width, height)
    }

    private static func lastError(in log: URL) -> String? {
        guard let text = try? String(contentsOf: log, encoding: .utf8) else { return nil }
        return text.split(separator: "\n").last { $0.contains("ERROR") }.map(String.init)
    }
}
