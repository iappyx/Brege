import AVFoundation

/// Plays the phone's audio (48 kHz, 16-bit stereo PCM) during a screen session, with a short
/// buffer against Wi‑Fi jitter.
final class ScreenAudioPlayer: @unchecked Sendable {
    private let channels = 2
    private let prefillFrames = 3_840 // 80 ms
    private let maxBufferedFrames = 14_400 // 300 ms: skip ahead beyond this
    private let capacity = 48_000 // 1 s

    private let lock = NSLock()
    private var ring: [Float]
    private var readIndex = 0
    private var writeIndex = 0
    private var buffered = 0 // frames
    private var playing = false
    private var engine: AVAudioEngine?

    init() {
        ring = [Float](repeating: 0, count: capacity * channels)
    }

    func start() {
        guard engine == nil else { return }
        let engine = AVAudioEngine()
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: AVAudioChannelCount(channels))!
        let source = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, bufferList in
            self?.render(UnsafeMutableAudioBufferListPointer(bufferList), frames: Int(frameCount))
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
            self.engine = engine
        } catch {
            NSLog("Brêge screen audio: \(error)")
        }
    }

    func stop() {
        engine?.stop()
        engine = nil
        lock.lock()
        readIndex = 0
        writeIndex = 0
        buffered = 0
        playing = false
        lock.unlock()
    }

    // Session thread: interleaved little-endian Int16.
    func append(_ pcm: Data) {
        lock.lock()
        defer { lock.unlock() }
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            let frames = samples.count / channels
            for frame in 0..<frames {
                if buffered == capacity {
                    readIndex = (readIndex + 1) % capacity
                    buffered -= 1
                }
                for channel in 0..<channels {
                    ring[writeIndex * channels + channel] = Float(Int16(littleEndian: samples[frame * channels + channel])) / 32_768
                }
                writeIndex = (writeIndex + 1) % capacity
                buffered += 1
            }
        }
        if buffered > maxBufferedFrames {
            let skip = buffered - prefillFrames
            readIndex = (readIndex + skip) % capacity
            buffered -= skip
        }
    }

    // Audio thread: non-interleaved float output.
    private func render(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
        lock.lock()
        defer { lock.unlock() }
        let outputs = (0..<min(channels, buffers.count)).compactMap { buffers[$0].mData?.assumingMemoryBound(to: Float.self) }
        if !playing, buffered >= prefillFrames { playing = true }
        for i in 0..<frames {
            if playing, buffered > 0 {
                for (channel, output) in outputs.enumerated() {
                    output[i] = ring[readIndex * channels + channel]
                }
                readIndex = (readIndex + 1) % capacity
                buffered -= 1
            } else {
                outputs.forEach { $0[i] = 0 }
                playing = false
            }
        }
    }
}
