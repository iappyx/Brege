import Foundation

/// Android Debug Bridge access for the phone screen. Brêge uses the phone's
/// wireless debugging service, which the user turns on and pairs with this Mac once.
struct Adb {
    enum Failure: LocalizedError {
        case notInstalled
        case wirelessDebuggingOff
        case notPaired
        case pairingServiceNotFound
        case pairingFailed(String)
        case commandFailed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "Brêge needs Android platform-tools (adb). Install them with “brew install --cask android-platform-tools”."
            case .wirelessDebuggingOff:
                return "Wireless debugging is off on the phone, or the phone is on another network."
            case .notPaired:
                return "This Mac is not paired for wireless debugging yet."
            case .pairingServiceNotFound:
                return "The phone is not showing a pairing code. Tap “Pair device with pairing code” first."
            case let .pairingFailed(output):
                return "Pairing failed: \(output)"
            case let .commandFailed(output):
                return output
            }
        }
    }

    struct Service {
        let name: String
        let type: String
        let host: String
        let port: Int
    }

    let executable: URL

    static func locate() -> Adb? {
        let env = ProcessInfo.processInfo.environment
        var candidates = ["ANDROID_HOME", "ANDROID_SDK_ROOT"].compactMap { env[$0] }.map { "\($0)/platform-tools/adb" }
        candidates += [
            NSHomeDirectory() + "/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { Adb(executable: URL(fileURLWithPath: $0)) }
    }

    // MARK: Commands (blocking: call off the main thread)

    /// Runs adb and returns stdout and stderr. Output goes to a file, not a pipe: the adb server
    /// daemon started by the first command inherits the handle and would keep a pipe open.
    @discardableResult
    func run(_ arguments: [String], timeout: TimeInterval = 20) throws -> String {
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("brege-adb-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        try process.run()
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw Failure.commandFailed("adb \(arguments.first ?? "") timed out")
        }
        return (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
    }

    /// Starts a long-running adb command (the screen server); its output goes to `log`.
    func spawn(_ arguments: [String], log: URL) throws -> Process {
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { _ in try? handle.close() }
        try process.run()
        return process
    }

    func startServer() throws {
        try run(["start-server"])
    }

    func services() throws -> [Service] {
        try run(["mdns", "services"]).split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 3, fields[1].hasPrefix("_adb-tls-"),
                  let colon = fields[2].lastIndex(of: ":"), let port = Int(fields[2][fields[2].index(after: colon)...])
            else { return nil }
            return Service(name: fields[0], type: fields[1], host: String(fields[2][..<colon]), port: port)
        }
    }

    func devices() throws -> [(serial: String, state: String)] {
        try run(["devices"]).split(separator: "\n").dropFirst().compactMap { line in
            let fields = line.split(separator: "\t")
            return fields.count == 2 ? (String(fields[0]), String(fields[1])) : nil
        }
    }

    // MARK: Phone connection

    /// Returns the adb serial of the phone at `phoneIP`, connecting to its wireless-debugging
    /// service when needed. The service port changes whenever wireless debugging restarts.
    func connect(phoneIP: String) throws -> String {
        try startServer()
        var connectable: [Service] = []
        for attempt in 0..<8 {
            let all = try services().filter { $0.type.hasPrefix("_adb-tls-connect") }
            connectable = all.filter { $0.host == phoneIP }
            if !connectable.isEmpty { break }
            if let ready = try readySerial(phoneIP: phoneIP, names: []) { return ready }
            if attempt < 7 { Thread.sleep(forTimeInterval: 0.5) } // mDNS results arrive after the server starts
        }
        let names = Set(connectable.map { "\($0.name).\($0.type)".trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
        if let ready = try readySerial(phoneIP: phoneIP, names: names) { return ready }

        // Stale entries from an earlier port show as offline and confuse later commands.
        for device in try devices() where device.serial.hasPrefix(phoneIP + ":") && device.state != "device" {
            _ = try? run(["disconnect", device.serial])
        }
        guard let service = connectable.first else { throw Failure.wirelessDebuggingOff }
        let target = "\(service.host):\(service.port)"
        let output = try run(["connect", target], timeout: 15)
        guard output.contains("connected to") else { throw Failure.notPaired }
        for _ in 0..<10 {
            if try devices().contains(where: { $0.serial == target && $0.state == "device" }) { return target }
            Thread.sleep(forTimeInterval: 0.3)
        }
        throw Failure.notPaired
    }

    private func readySerial(phoneIP: String, names: Set<String>) throws -> String? {
        try devices().first { device in
            device.state == "device" && (device.serial.hasPrefix(phoneIP + ":") || names.contains(device.serial))
        }?.serial
    }

    /// Pairs with the phone while it shows “Pair device with pairing code”.
    func pair(phoneIP: String, code: String) throws {
        try startServer()
        var pairing: Service?
        for _ in 0..<20 {
            pairing = try services().first { $0.type.hasPrefix("_adb-tls-pairing") && $0.host == phoneIP }
            if pairing != nil { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        guard let pairing else { throw Failure.pairingServiceNotFound }
        let output = try run(["pair", "\(pairing.host):\(pairing.port)", code], timeout: 30)
        guard output.contains("Successfully paired") else {
            throw Failure.pairingFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
