import AVFoundation
import CoreMedia

/// Turns scrcpy's Annex-B H.265 / H.264 packets into sample buffers for an
/// AVSampleBufferDisplayLayer, which decodes them in hardware and shows each frame immediately.
final class ScreenVideoDecoder: @unchecked Sendable {
    let layer = AVSampleBufferDisplayLayer()
    /// Called when the decoder needs a fresh key frame.
    var onNeedsKeyFrame: (() -> Void)?

    private let frameLock = NSLock()
    private var frameEnqueued = false

    /// Whether any picture reached the screen (app windows stay black if the app refused to open).
    var hasFrame: Bool {
        frameLock.lock()
        defer { frameLock.unlock() }
        return frameEnqueued
    }

    /// Forgets earlier pictures, for a new session.
    func resetFrames() {
        frameLock.lock()
        frameEnqueued = false
        frameLock.unlock()
    }

    private var codec: ScreenSession.VideoCodec = .h265
    private var format: CMVideoFormatDescription?
    private var waitingForKeyFrame = true

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
    }

    func setCodec(_ codec: ScreenSession.VideoCodec) {
        self.codec = codec
    }

    // Session thread.
    func decode(_ packet: ScreenSession.VideoPacket) {
        let units = Self.nalUnits(in: packet.data)
        let parameterSets = units.filter { Self.isParameterSet($0, codec: codec) }
        if !parameterSets.isEmpty {
            makeFormat(from: parameterSets)
        }
        if packet.isConfig { return }
        guard let format else { return }
        if waitingForKeyFrame {
            guard packet.isKeyFrame else { return }
            waitingForKeyFrame = false
        }

        let sample = Self.lengthPrefixed(units, codec: codec)
        guard !sample.isEmpty, let buffer = Self.sampleBuffer(sample, format: format) else { return }

        if layer.status == .failed {
            layer.flush()
            waitingForKeyFrame = true
            onNeedsKeyFrame?()
            return
        }
        layer.enqueue(buffer)
        frameLock.lock()
        frameEnqueued = true
        frameLock.unlock()
    }

    static func isParameterSet(_ unit: Data, codec: ScreenSession.VideoCodec) -> Bool {
        guard let first = unit.first else { return false }
        switch codec {
        case .h265: return (32...34).contains((first >> 1) & 0x3F) // VPS, SPS, PPS
        case .h264: return [7, 8].contains(first & 0x1F) // SPS, PPS
        }
    }

    /// Frame data as 4-byte length-prefixed NAL units (what CoreMedia expects), without
    /// parameter sets.
    static func lengthPrefixed(_ units: [Data], codec: ScreenSession.VideoCodec) -> Data {
        var sample = Data()
        for unit in units where !isParameterSet(unit, codec: codec) {
            var length = UInt32(unit.count).bigEndian
            withUnsafeBytes(of: &length) { sample.append(contentsOf: $0) }
            sample.append(unit)
        }
        return sample
    }

    static func formatDescription(from sets: [Data], codec: ScreenSession.VideoCodec) -> CMVideoFormatDescription? {
        let joined = sets.reduce(Data(), +)
        var newFormat: CMFormatDescription?
        joined.withUnsafeBytes { raw in
            let base = raw.bindMemory(to: UInt8.self).baseAddress!
            var offset = 0
            var pointers: [UnsafePointer<UInt8>] = []
            for set in sets {
                pointers.append(base + offset)
                offset += set.count
            }
            let sizes = sets.map(\.count)
            switch codec {
            case .h265:
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &newFormat
                )
            case .h264:
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &newFormat
                )
            }
        }
        return newFormat
    }

    private func makeFormat(from sets: [Data]) {
        guard let newFormat = Self.formatDescription(from: sets, codec: codec) else { return }
        if let format, CMFormatDescriptionEqual(format, otherFormatDescription: newFormat) { return }
        // Rotation or a new capture session: start again at the next key frame.
        format = newFormat
        layer.flush()
        waitingForKeyFrame = true
    }

    static func sampleBuffer(_ data: Data, format: CMVideoFormatDescription, pts: CMTime? = nil) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: data.count, flags: 0, blockBufferOut: &block
        ) == noErr, let block else { return nil }
        let copied = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }
        guard copied == noErr else { return nil }

        var sample: CMSampleBuffer?
        var size = data.count
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts ?? .invalid, decodeTimeStamp: .invalid)
        let status = withUnsafePointer(to: &timing) { timingPointer in
            CMSampleBufferCreateReady(
                allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
                sampleTimingEntryCount: pts == nil ? 0 : 1, sampleTimingArray: pts == nil ? nil : timingPointer,
                sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample
            )
        }
        guard status == noErr, let sample else { return nil }
        guard pts == nil else { return sample } // recording: timed, not shown immediately
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    /// Splits an Annex-B stream at 3- and 4-byte start codes.
    static func nalUnits(in data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var units: [Data] = []
        var start: Int?
        var i = 0
        while i + 2 < bytes.count {
            if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                if let s = start {
                    var end = i
                    if end > s, bytes[end - 1] == 0 { end -= 1 } // 4-byte start code
                    units.append(Data(bytes[s..<end]))
                }
                i += 3
                start = i
            } else {
                i += 1
            }
        }
        if let s = start, s < bytes.count {
            units.append(Data(bytes[s...]))
        }
        return units
    }
}
