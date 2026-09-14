import AVFoundation
import CoreMedia

/// Records the phone camera to a QuickTime movie: the phone's H.265 / H.264 video is written as
/// it arrives (no re-encoding), the phone microphone is encoded to AAC. Runs on its own queue.
final class CameraRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.brege.camera-recorder")
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var codec: ScreenSession.VideoCodec = .h265
    private var parameterSets: [Data] = []
    private var format: CMVideoFormatDescription?
    private var firstVideoPts: Int64?
    /// Host time (seconds) of the first video frame, to place audio on the same timeline.
    private var firstVideoHostTime: TimeInterval = 0
    /// Audio is placed by datagram sequence number (10 ms per frame), so lost or dropped frames
    /// leave their time behind instead of pulling later audio earlier.
    private var audioFirstSeq: UInt32?
    /// Sample position (48 kHz, from the first video frame) of `audioFirstSeq`.
    private var audioBase: Int64 = 0
    /// End of the audio written so far, in samples.
    private var audioSamples: Int64 = 0
    private var url: URL?
    private var rotation: Int = 0

    var isRecording: Bool { queue.sync { writer != nil } }

    /// Starts writing at the next key frame.
    func start(to url: URL, codec: ScreenSession.VideoCodec, rotation: Int) throws {
        try queue.sync {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            self.url = url
            self.codec = codec
            self.rotation = rotation
            firstVideoPts = nil
            audioSamples = 0
            audioFirstSeq = nil
            videoInput = nil
            audioInput = nil
        }
    }

    /// Finishes the movie; the completion gets its URL (or nil if nothing was recorded).
    func stop(completion: @escaping (URL?) -> Void) {
        queue.async { [self] in
            guard let writer else {
                completion(nil)
                return
            }
            let url = self.url
            self.writer = nil
            guard writer.status == .writing else {
                writer.cancelWriting()
                if let url { try? FileManager.default.removeItem(at: url) }
                completion(nil)
                return
            }
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            writer.finishWriting { completion(writer.status == .completed ? url : nil) }
        }
    }

    // Core thread → recorder queue.
    func appendVideo(flags: UInt8, ptsUs: UInt64, data: Data) {
        let arrival = ProcessInfo.processInfo.systemUptime
        queue.async { [self] in
            let units = ScreenVideoDecoder.nalUnits(in: data)
            var sets = units.filter { ScreenVideoDecoder.isParameterSet($0, codec: codec) }
            // The phone sends its parameter sets once, when the stream starts, which can be before
            // recording tells the codec; recognise them in config packets for either codec.
            let other: ScreenSession.VideoCodec = codec == .h265 ? .h264 : .h265
            if sets.isEmpty, flags & 1 != 0, case let otherSets = units.filter({ ScreenVideoDecoder.isParameterSet($0, codec: other) }), !otherSets.isEmpty {
                codec = other
                sets = otherSets
            }
            if !sets.isEmpty {
                parameterSets = sets
                format = ScreenVideoDecoder.formatDescription(from: sets, codec: codec)
            }
            guard let writer, flags & 1 == 0, let format else { return }
            let keyFrame = flags & 2 != 0

            if videoInput == nil {
                guard keyFrame else { return } // a movie starts with a key frame
                let video = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
                video.expectsMediaDataInRealTime = true
                video.transform = CGAffineTransform(rotationAngle: CGFloat(rotation) * .pi / 180)
                let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
                    AVEncoderBitRateKey: 128_000,
                ])
                audio.expectsMediaDataInRealTime = true
                guard writer.canAdd(video) else { return }
                writer.add(video)
                if writer.canAdd(audio) { writer.add(audio) }
                videoInput = video
                audioInput = audio
                writer.startWriting()
                writer.startSession(atSourceTime: .zero)
                firstVideoPts = Int64(ptsUs)
                firstVideoHostTime = arrival
            }
            guard let video = videoInput, let first = firstVideoPts, video.isReadyForMoreMediaData else { return }
            let pts = CMTime(value: Int64(ptsUs) - first, timescale: 1_000_000)
            guard pts.value >= 0 else { return }
            let sample = ScreenVideoDecoder.lengthPrefixed(units, codec: codec)
            guard !sample.isEmpty, let buffer = ScreenVideoDecoder.sampleBuffer(sample, format: format, pts: pts) else { return }
            if !keyFrame, let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true),
               CFArrayGetCount(attachments) > 0 {
                let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
                CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
            video.append(buffer)
        }
    }

    // Core thread: 10 ms of 48 kHz mono 16-bit PCM, numbered by the phone.
    func appendAudio(seq: UInt32, pcm: Data) {
        let arrival = ProcessInfo.processInfo.systemUptime
        queue.async { [self] in
            guard let writer, writer.status == .writing, let audio = audioInput, firstVideoPts != nil else { return }
            let frames = pcm.count / 2
            guard frames > 0 else { return }
            let arrivalSamples = Int64(max(0, arrival - firstVideoHostTime) * 48_000)
            var start: Int64
            if let first = audioFirstSeq, case let position = audioBase + Int64(Int32(bitPattern: seq &- first)) * Int64(frames),
               position >= audioSamples - 48_000, abs(position - arrivalSamples) <= 480_000 {
                start = position
            } else {
                // First frame, or the numbering restarted or jumped (the phone app restarted, audio
                // paused): follow arrival time.
                audioFirstSeq = seq
                audioBase = max(arrivalSamples, audioSamples)
                start = audioBase
            }
            guard start >= audioSamples else { return } // late or duplicate
            var samples = pcm
            // Fill short gaps (frames lost on the way or dropped while the writer was busy) with
            // silence, so the encoder stays continuous; the frame itself keeps its own time.
            let gap = start - audioSamples
            if gap > 0, gap <= 48_000, audioSamples > 0 {
                samples = Data(count: Int(gap) * 2) + pcm
                start = audioSamples
            }
            guard audio.isReadyForMoreMediaData,
                  let buffer = Self.pcmSampleBuffer(samples, frames: samples.count / 2, pts: CMTime(value: start, timescale: 48_000))
            else { return }
            if audio.append(buffer) { audioSamples = start + Int64(samples.count / 2) }
        }
    }

    private static func pcmSampleBuffer(_ pcm: Data, frames: Int, pts: CMTime) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                             magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: pcm.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: pcm.count, flags: 0, blockBufferOut: &block) == noErr,
              let block else { return nil }
        _ = pcm.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: pcm.count) }
        var sample: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: frames,
            presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &sample
        ) == noErr else { return nil }
        return sample
    }
}
