import AVFoundation
import BregeCore
import CoreAudio
import Foundation

/// Phone as microphone on the Mac. PCM frames from the phone are played into the
/// hidden "Brêge Microphone Feed" device; the Brêge HAL driver loops them to "Brêge Microphone",
/// which any app can select as its input.
final class PhoneMicrophone: AudioFrameListener, @unchecked Sendable {
    static let feedUID = "app.brege.microphone.feed"
    static let driverName = "BregeMicrophone.driver"
    static let installedDriver = URL(fileURLWithPath: "/Library/Audio/Plug-Ins/HAL/\(driverName)")

    private let sampleRate: Double = 48_000
    /// Audio waits this long before playback starts, absorbing Wi‑Fi jitter.
    private let prefillFrames = 2_880 // 60 ms
    private let capacity = 48_000 // 1 s

    private let lock = NSLock()
    private var ring: [Float]
    private var readIndex = 0
    private var writeIndex = 0
    private var buffered = 0
    private var playing = false
    private var lastSeq: UInt32?

    private var engine: AVAudioEngine?
    /// `engine != nil`, readable from the core thread (guarded by `lock`).
    private var running = false

    init() {
        ring = [Float](repeating: 0, count: capacity)
    }

    static var isDriverInstalled: Bool {
        FileManager.default.fileExists(atPath: installedDriver.path)
    }

    /// Copies the driver into /Library/Audio/Plug-Ins/HAL (asks for an administrator password)
    /// and restarts Core Audio so it appears.
    static func installDriver() throws {
        guard let source = Bundle.main.url(forResource: "BregeMicrophone", withExtension: "driver") else {
            throw NSError(domain: "Brege", code: 1, userInfo: [NSLocalizedDescriptionKey: "The driver is missing from Brêge.app."])
        }
        let quoted = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let target = installedDriver.path
        let command = [
            "rm -rf \(quoted(target))",
            "cp -R \(quoted(source.path)) \(quoted(target))",
            "chown -R root:wheel \(quoted(target))",
            "killall coreaudiod",
        ].joined(separator: " && ")
        try runAsAdministrator(command)
    }

    /// Removes the driver (asks for an administrator password) and restarts Core Audio.
    static func uninstallDriver() throws {
        let target = installedDriver.path
        try runAsAdministrator("rm -rf '\(target)' && killall coreaudiod")
    }

    private static func runAsAdministrator(_ command: String) throws {
        let script = "do shell script \"\(command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            throw NSError(domain: "Brege", code: 2, userInfo: [NSLocalizedDescriptionKey: error[NSAppleScript.errorMessage] as? String ?? "Cancelled."])
        }
    }

    // MARK: Playback

    func start() throws {
        guard engine == nil else { return }
        guard let device = Self.deviceID(uid: Self.feedUID) else {
            throw NSError(domain: "Brege", code: 3, userInfo: [NSLocalizedDescriptionKey: "The Brêge Microphone driver is not loaded. Install it, or restart the Mac."])
        }
        let engine = AVAudioEngine()
        let output = engine.outputNode
        guard let unit = output.audioUnit else {
            throw NSError(domain: "Brege", code: 4, userInfo: [NSLocalizedDescriptionKey: "No audio output unit."])
        }
        var deviceID = device
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else {
            throw NSError(domain: "Brege", code: 5, userInfo: [NSLocalizedDescriptionKey: "Could not select the microphone feed (\(status))."])
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let source = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, bufferList in
            guard let self else { return noErr }
            let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
            guard let data = buffers[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            self.render(into: data, frames: Int(frameCount))
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        self.engine = engine
        lock.lock()
        running = true
        lock.unlock()
        reset()
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
        engine?.stop()
        engine = nil
        reset()
    }

    var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func reset() {
        lock.lock()
        resetLocked()
        lock.unlock()
    }

    /// Call with `lock` held.
    private func resetLocked() {
        readIndex = 0
        writeIndex = 0
        buffered = 0
        playing = false
        lastSeq = nil
    }

    // Core thread: 16-bit LE mono PCM, 10 ms per frame.
    /// Also receives every frame (phone camera recordings use the microphone audio).
    var onFrame: ((String, UInt32, Data) -> Void)?
    /// Only this phone is played into the Brêge Microphone; another phone's camera audio is not.
    var playingFrom: String? {
        get { lock.lock(); defer { lock.unlock() }; return _playingFrom }
        set {
            lock.lock()
            // Another phone counts its sequence numbers from its own start.
            if newValue != _playingFrom { resetLocked() }
            _playingFrom = newValue
            lock.unlock()
        }
    }
    private var _playingFrom: String?

    func onMicFrame(from: String, seq: UInt32, pcm: Data) {
        onFrame?(from, seq, pcm)
        lock.lock()
        defer { lock.unlock() }
        guard running else { return }
        if let playing = _playingFrom, playing != from { return }
        if let last = lastSeq, seq <= last {
            // Far behind: the phone restarted its stream (numbering starts again).
            guard last - seq > 1_000 else { return } // late or duplicate datagram
        }
        lastSeq = seq
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for sample in samples {
                if buffered == capacity { // overflow: drop the oldest audio
                    readIndex = (readIndex + 1) % capacity
                    buffered -= 1
                }
                ring[writeIndex] = Float(Int16(littleEndian: sample)) / 32_768
                writeIndex = (writeIndex + 1) % capacity
                buffered += 1
            }
        }
        // Keep latency bounded: if more than 250 ms piled up, skip ahead to the prefill level.
        if buffered > 12_000 {
            let skip = buffered - prefillFrames
            readIndex = (readIndex + skip) % capacity
            buffered -= skip
        }
    }

    // Audio thread.
    private func render(into data: UnsafeMutablePointer<Float>, frames: Int) {
        lock.lock()
        defer { lock.unlock() }
        if !playing {
            if buffered < prefillFrames {
                data.update(repeating: 0, count: frames)
                return
            }
            playing = true
        }
        for i in 0..<frames {
            if buffered > 0 {
                data[i] = ring[readIndex]
                readIndex = (readIndex + 1) % capacity
                buffered -= 1
            } else {
                data[i] = 0
                playing = false // underrun: build up the prefill again
            }
        }
    }

    private static func deviceID(uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID = uid as CFString
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPointer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                       UInt32(MemoryLayout<CFString>.size), uidPointer, &size, &device)
        }
        return status == noErr && device != kAudioObjectUnknown ? device : nil
    }
}
