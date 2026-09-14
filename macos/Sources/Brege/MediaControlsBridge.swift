import BregeCore
import Foundation
import MediaPlayer

/// Shows the phone's playing media in the macOS media controls and forwards media keys, the system
/// media controls and headphone controls to the phone.
@MainActor
final class MediaControlsBridge {
    var onCommand: ((String, CommandKind) -> Void)?

    private let center = MPNowPlayingInfoCenter.default()
    private var deviceId: String?
    private var playing = false
    private var registered = false

    func update(_ media: MediaData, from deviceId: String) {
        guard !media.title.isEmpty else {
            clear(deviceId: deviceId)
            return
        }
        registerCommands()
        self.deviceId = deviceId
        playing = media.playing
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: media.title,
            MPMediaItemPropertyArtist: media.artist.isEmpty ? media.appLabel : media.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(media.positionMs) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: media.playing ? 1.0 : 0.0,
        ]
        if media.durationMs > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = Double(media.durationMs) / 1000
        }
        center.nowPlayingInfo = info
        // macOS requires the state to be set explicitly.
        center.playbackState = media.playing ? .playing : .paused
    }

    /// Clears the media controls when the phone stops or disconnects, so Brêge never keeps the media
    /// keys away from apps that actually play audio on the Mac.
    func clear(deviceId: String? = nil) {
        if let deviceId, deviceId != self.deviceId { return }
        self.deviceId = nil
        playing = false
        center.nowPlayingInfo = nil
        center.playbackState = .stopped
    }

    private func registerCommands() {
        guard !registered else { return }
        registered = true
        let commands = MPRemoteCommandCenter.shared()
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in self?.send(.mediaPlayPause) ?? .noActionableNowPlayingItem }
        // The phone only has a toggle; skip it when the phone is already in the requested state.
        commands.playCommand.addTarget { [weak self] _ in
            guard let self else { return .noActionableNowPlayingItem }
            return self.playing ? .success : self.send(.mediaPlayPause)
        }
        commands.pauseCommand.addTarget { [weak self] _ in
            guard let self else { return .noActionableNowPlayingItem }
            return self.playing ? self.send(.mediaPlayPause) : .success
        }
        commands.nextTrackCommand.addTarget { [weak self] _ in self?.send(.mediaNext) ?? .noActionableNowPlayingItem }
        commands.previousTrackCommand.addTarget { [weak self] _ in self?.send(.mediaPrevious) ?? .noActionableNowPlayingItem }
    }

    private func send(_ command: CommandKind) -> MPRemoteCommandHandlerStatus {
        guard let deviceId else { return .noActionableNowPlayingItem }
        onCommand?(deviceId, command)
        return .success
    }
}
