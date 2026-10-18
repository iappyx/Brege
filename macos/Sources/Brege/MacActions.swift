import AppKit
import ApplicationServices
import AudioToolbox
import BregeCore
import CoreAudio
import IOKit.ps

/// What a phone — or the watch behind it — may ask of this Mac: ring so you can find it, lock it,
/// change its volume, or just say how it stands.
///
/// Everything here uses what any app may do: no accessibility permission, no synthetic keystrokes.
@MainActor
final class MacActions: ObservableObject {
    /// A ring that is never stopped would go on forever, so it stops by itself.
    private static let maxRingSeconds: TimeInterval = 60
    /// Loud and bright, because the point is to be heard from another room. The first one that
    /// exists is used.
    private static let ringSounds = ["Sosumi", "Glass", "Submarine"]
    /// How often the sound starts again; shorter than it is, so it beeps rather than drifts.
    private static let ringEvery: TimeInterval = 1.2
    /// A Mac you are looking for is no use at a polite volume.
    private static let ringVolume: Float = 0.85

    @Published private(set) var ringing = false

    private var sound: NSSound?
    private var volumeBeforeRing: Float?
    private var mutedBeforeRing = false
    private var stopTimer: Timer?
    private var repeatTimer: Timer?
    /// Called when something changed that the phones should hear about.
    var onStateChanged: (() -> Void)?

    // --- acting ---------------------------------------------------------------------------

    func perform(_ kind: MacActionKind, value: Int32) {
        switch kind {
        case .ring: value != 0 ? ring() : stopRinging()
        case .lock: lock()
        case .volume: setVolume(Float(value) / 100)
        case .mute: setMuted(value != 0)
        case .state: break // the state goes out either way
        case .mediaPlayPause: sendKey(.playPause)
        case .mediaNext: sendKey(.next)
        case .mediaPrevious: sendKey(.previous)
        case .slideNext: sendKey(.rightArrow)
        case .slidePrevious: sendKey(.leftArrow)
        }
        onStateChanged?()
    }

    // --- keys, for media and slides ----------------------------------------------------------

    /// macOS only lets an app press keys for you once you allow it under Accessibility, so these
    /// actions are offered on the watch only while that is granted.
    var canSendKeys: Bool { AXIsProcessTrusted() }

    /// Shows the macOS prompt that leads to the Accessibility list.
    func askForKeyControl() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    private enum Key {
        case playPause, next, previous, rightArrow, leftArrow
    }

    private func sendKey(_ key: Key) {
        guard canSendKeys else { return }
        switch key {
        case .playPause: mediaKey(NX_KEYTYPE_PLAY)
        case .next: mediaKey(NX_KEYTYPE_NEXT)
        case .previous: mediaKey(NX_KEYTYPE_PREVIOUS)
        case .rightArrow: arrowKey(124)
        case .leftArrow: arrowKey(123)
        }
    }

    /// Media keys are not ordinary keys: they travel as a system-defined event, the same one a
    /// keyboard's play button sends, so whatever is playing reacts, not only the front app.
    private func mediaKey(_ key: Int32) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: UInt(down ? 0xA00 : 0xB00))
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: Int((key << 16) | ((down ? 0xA : 0xB) << 8)),
                data2: -1
            ) else { continue }
            event.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    /// Slide forward and back are the arrow keys, which go to whatever is in front.
    private func arrowKey(_ code: CGKeyCode) {
        let source = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true)?
            .post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false)?
            .post(tap: .cghidEventTap)
    }

    /// Plays a sound until it is stopped, loud enough to be heard from the next room.
    func ring() {
        guard !ringing else { return }
        // A Mac left muted or quiet is no use to find, so the volume goes up and back afterwards.
        volumeBeforeRing = volume()
        mutedBeforeRing = muted()
        setMuted(false)
        setVolume(Self.ringVolume)

        sound = Self.ringSounds
            .lazy
            .map { URL(fileURLWithPath: "/System/Library/Sounds/\($0).aiff") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
            .flatMap { NSSound(contentsOf: $0, byReference: true) }
        sound?.volume = 1
        ringing = true
        beep()
        // Restarting it beats looping: the file's own silent tail would make it drift apart.
        repeatTimer = Timer.scheduledTimer(withTimeInterval: Self.ringEvery, repeats: true) { _ in
            Task { @MainActor in self.beep() }
        }
        stopTimer = Timer.scheduledTimer(withTimeInterval: Self.maxRingSeconds, repeats: false) { _ in
            Task { @MainActor in self.stopRinging() }
        }
    }

    private func beep() {
        guard let sound else {
            // A system without those files still has the alert beep.
            NSSound.beep()
            return
        }
        sound.stop()
        sound.play()
    }

    func stopRinging() {
        guard ringing else { return }
        sound?.stop()
        sound = nil
        repeatTimer?.invalidate()
        repeatTimer = nil
        stopTimer?.invalidate()
        stopTimer = nil
        if let restore = volumeBeforeRing {
            setVolume(restore)
            volumeBeforeRing = nil
        }
        setMuted(mutedBeforeRing)
        ringing = false
        onStateChanged?()
    }

    /// Puts the display to sleep. Whether that locks the Mac is the user's own setting, which is
    /// why the watch calls this "Sleep & lock" rather than promising something it cannot do.
    private func lock() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        task.arguments = ["displaysleepnow"]
        try? task.run()
    }

    // --- how this Mac stands ----------------------------------------------------------------

    func state(name: String) -> MacStateData {
        let power = batteryState()
        return MacStateData(
            name: name,
            volume: UInt32((volume() * 100).rounded().clamped(to: 0...100)),
            muted: muted(),
            hasBattery: power != nil,
            battery: UInt32(power?.percent ?? 0),
            charging: power?.charging ?? false,
            ringing: ringing,
            keyControl: canSendKeys
        )
    }

    // --- the default output device ----------------------------------------------------------

    private func outputDevice() -> AudioDeviceID? {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    private func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    func volume() -> Float {
        guard let device = outputDevice() else { return 0 }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = volumeAddress()
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return 0
        }
        return value
    }

    func setVolume(_ value: Float) {
        guard let device = outputDevice() else { return }
        var level = Float32(value.clamped(to: 0...1))
        var address = volumeAddress()
        guard AudioObjectHasProperty(device, &address) else { return }
        AudioObjectSetPropertyData(device, &address, 0, nil,
                                   UInt32(MemoryLayout<Float32>.size), &level)
    }

    private func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    func muted() -> Bool {
        guard let device = outputDevice() else { return false }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = muteAddress()
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }

    func setMuted(_ muted: Bool) {
        guard let device = outputDevice() else { return }
        var value = UInt32(muted ? 1 : 0)
        var address = muteAddress()
        guard AudioObjectHasProperty(device, &address) else { return }
        AudioObjectSetPropertyData(device, &address, 0, nil,
                                   UInt32(MemoryLayout<UInt32>.size), &value)
    }

    // --- this Mac's own battery ---------------------------------------------------------------

    private func batteryState() -> (percent: Int, charging: Bool)? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                as? [String: Any],
                let capacity = info[kIOPSCurrentCapacityKey] as? Int,
                let max = info[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            let charging = (info[kIOPSIsChargingKey] as? Bool) ?? false
            return (Int((Double(capacity) / Double(max) * 100).rounded()), charging)
        }
        return nil
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
