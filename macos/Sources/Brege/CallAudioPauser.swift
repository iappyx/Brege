import AppKit

/// Pauses music and video on the Mac while the phone rings or a call is active, and resumes what
/// it paused afterwards. Uses AppleScript, which Music, Spotify and TV support; browsers and
/// other players have no such interface.
@MainActor
final class CallAudioPauser {
    private static let players = ["com.apple.Music", "com.spotify.client", "com.apple.TV"]
    /// AppleScript waits for the player to answer, so it runs here, one script at a time and in
    /// order, instead of holding up the main thread.
    private let queue = DispatchQueue(label: "brege.call-audio")
    private let paused = PausedPlayers()

    func callStarted() {
        guard AppSettings.shared.pauseAudioDuringCalls else { return }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let candidates = Self.players.filter(running.contains)
        queue.async { [paused] in
            guard paused.players.isEmpty else { return }
            for player in candidates {
                let script = "tell application id \"\(player)\" to if player state is playing then\npause\nreturn true\nend if"
                var error: NSDictionary?
                if NSAppleScript(source: script)?.executeAndReturnError(&error).booleanValue == true {
                    paused.players.append(player)
                }
            }
        }
    }

    func callEnded() {
        queue.async { [paused] in
            let players = paused.players
            paused.players = []
            for player in players {
                var error: NSDictionary?
                NSAppleScript(source: "tell application id \"\(player)\" to play")?.executeAndReturnError(&error)
            }
        }
    }
}

/// Players paused for a call; only used on `CallAudioPauser.queue`.
private final class PausedPlayers: @unchecked Sendable {
    var players: [String] = []
}
