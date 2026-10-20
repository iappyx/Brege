import Foundation

/// Notes from the second display, in `~/Library/Logs/brege-display.log`.
///
/// `NSLog` from this app reaches nothing — not the unified log, and not a terminal, since the app is
/// launched by the user rather than from a shell. A file is the only way to see what a session
/// actually did, and the phone has had exactly this for the same reason (`UptimeLog`).
enum DisplayLog {
    static let file = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/brege-display.log")

    /// Lines beyond this and the file is trimmed to its second half, so a long session cannot grow
    /// without bound.
    private static let maxBytes = 512 * 1024
    private static let lock = NSLock()
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    static func write(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "\(stamp.string(from: Date()))  \(text)\n"
        guard let data = line.data(using: .utf8) else { return }
        guard let handle = try? FileHandle(forWritingTo: file) else {
            try? data.write(to: file)
            return
        }
        defer { try? handle.close() }
        if (try? handle.seekToEnd()) ?? 0 > UInt64(maxBytes),
           let existing = try? String(contentsOf: file, encoding: .utf8) {
            try? Data(existing.suffix(maxBytes / 2).utf8).write(to: file)
            return
        }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
