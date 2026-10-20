import CoreMedia
import Foundation
import VideoToolbox

/// Turns captured display frames into a stream the tablet's decoder can take.
///
/// Set for latency rather than size: no frame reordering, so every frame can go on the wire the
/// moment it is encoded, and real-time mode so VideoToolbox would rather drop quality than hold a
/// frame back. The bytes come out as Annex-B with the parameter sets repeated on every keyframe,
/// which is what `MediaCodec` wants and what lets a tablet that joins late, or recovers from a
/// stall, start decoding at the next keyframe without being told anything.
final class DisplayEncoder {
    enum Codec {
        case h264
        case hevc

        var codecType: CMVideoCodecType {
            self == .h264 ? kCMVideoCodecType_H264 : kCMVideoCodecType_HEVC
        }

        var profile: CFString {
            self == .h264 ? kVTProfileLevel_H264_High_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel
        }
    }

    enum Failure: LocalizedError {
        case sessionFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case let .sessionFailed(status):
                return "The Mac's video encoder could not be started (\(status))."
            }
        }
    }

    struct EncodedFrame {
        /// The frame's own NAL units, Annex-B with start codes.
        let bytes: Data
        /// SPS/PPS (and VPS for H.265), on keyframes only. Sent as a config packet of its own, and
        /// written ahead of the frame when the bytes go to a file.
        let parameterSets: Data?
        /// The compressed frame as VideoToolbox made it, for writing a file without re-encoding.
        let sample: CMSampleBuffer
        let isKeyframe: Bool
        let presentationTime: CMTime
        /// How long VideoToolbox held this frame, in milliseconds.
        let encodeMilliseconds: Double
    }

    private var session: VTCompressionSession?
    private let onFrame: (EncodedFrame) -> Void
    private let codec: Codec
    private var submitted: [Int64: CFAbsoluteTime] = [:]
    private let lock = NSLock()
    private var wantsKeyframe = false

    init(width: Int, height: Int, codec: Codec = .h264, bitsPerSecond: Int, framesPerSecond: Int,
         onFrame: @escaping (EncodedFrame) -> Void) throws {
        self.onFrame = onFrame
        self.codec = codec

        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width), height: Int32(height),
            codecType: codec.codecType,
            encoderSpecification: nil, imageBufferAttributes: nil, compressedDataAllocator: nil,
            outputCallback: nil, refcon: nil,
            compressionSessionOut: &created
        )
        guard status == noErr, let session = created else { throw Failure.sessionFailed(status) }
        self.session = session

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        // No B-frames: a frame that waits for a later one to be decodable is latency on the wire.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering,
                             value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: codec.profile)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: bitsPerSecond))
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate,
                             value: NSNumber(value: framesPerSecond))
        // Keyframes are cheap insurance against loss, but not every second: the tablet can ask.
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: NSNumber(value: framesPerSecond * 4))
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    /// Changes the bitrate of a running session. VideoToolbox takes this between frames, so the
    /// next frame is already encoded to the new figure — no restart, and no gap in the picture.
    func setBitsPerSecond(_ rate: Int) {
        guard let session else { return }
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate,
                             value: NSNumber(value: rate))
    }

    /// The next frame will be a keyframe. Asked for by a tablet that has just joined or lost frames.
    func requestKeyframe() {
        lock.lock()
        wantsKeyframe = true
        lock.unlock()
    }

    func encode(_ pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        guard let session else { return }
        lock.lock()
        let forced = wantsKeyframe
        wantsKeyframe = false
        submitted[presentationTime.value] = CFAbsoluteTimeGetCurrent()
        lock.unlock()

        var properties: CFDictionary?
        if forced {
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue!] as CFDictionary
        }
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: presentationTime,
            duration: .invalid, frameProperties: properties, infoFlagsOut: nil
        ) { [weak self] status, _, sample in
            guard status == noErr, let sample, let self else { return }
            self.deliver(sample)
        }
    }

    func finish() {
        guard let session else { return }
        self.session = nil
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
    }

    private func deliver(_ sample: CMSampleBuffer) {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sample)
        lock.lock()
        let started = submitted.removeValue(forKey: presentationTime.value)
        lock.unlock()
        let elapsed = started.map { (CFAbsoluteTimeGetCurrent() - $0) * 1000 } ?? 0

        let isKeyframe = Self.isKeyframe(sample)
        var sets: Data?
        if isKeyframe, let format = CMSampleBufferGetFormatDescription(sample) {
            let parameters = Self.parameterSets(from: format, codec: codec)
            sets = parameters.isEmpty ? nil : parameters
        }
        let bytes = Self.annexB(from: sample, codec: codec)
        guard !bytes.isEmpty else { return }
        onFrame(EncodedFrame(bytes: bytes, parameterSets: sets, sample: sample, isKeyframe: isKeyframe,
                             presentationTime: presentationTime, encodeMilliseconds: elapsed))
    }

    private static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
                as? [[CFString: Any]], let first = attachments.first else { return false }
        // Absent means "not a sync sample" is false, i.e. it is one.
        return (first[kCMSampleAttachmentKey_NotSync] as? Bool) != true
    }

    /// SPS and PPS (plus VPS for HEVC), each behind a start code.
    private static func parameterSets(from format: CMFormatDescription, codec: Codec) -> Data {
        var data = Data()
        var count = 0
        let countStatus = codec == .h264
            ? CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            : CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: 0,
                parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        guard countStatus == noErr else { return data }

        for index in 0..<count {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = codec == .h264
                ? CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                : CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index,
                    parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            guard status == noErr, let pointer else { continue }
            data.append(contentsOf: [0, 0, 0, 1])
            data.append(pointer, count: size)
        }
        return data
    }

    /// VideoToolbox hands over length-prefixed NAL units; the wire wants start codes.
    private static func annexB(from sample: CMSampleBuffer, codec: Codec) -> Data {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return Data() }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &pointer) == noErr,
              let pointer else { return Data() }

        // The prefix is four bytes in everything VideoToolbox produces here, but read it rather
        // than assume: a three-byte prefix would otherwise shift every NAL unit by one.
        var headerLength: Int32 = 4
        if let format = CMSampleBufferGetFormatDescription(sample) {
            var count = 0
            // Asked of the right accessor: the H.264 one fails on an H.265 description, which would
            // leave the prefix length at a guess rather than what the encoder actually used.
            _ = codec == .h264
                ? CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                    parameterSetSizeOut: nil, parameterSetCountOut: &count,
                    nalUnitHeaderLengthOut: &headerLength)
                : CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: 0, parameterSetPointerOut: nil,
                    parameterSetSizeOut: nil, parameterSetCountOut: &count,
                    nalUnitHeaderLengthOut: &headerLength)
        }
        let prefix = Int(headerLength)
        guard prefix == 3 || prefix == 4 else { return Data() }

        var data = Data()
        var offset = 0
        let bytes = UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self)
        while offset + prefix <= length {
            var size = 0
            for index in 0..<prefix { size = (size << 8) | Int(bytes[offset + index]) }
            offset += prefix
            guard size > 0, offset + size <= length else { break }
            data.append(contentsOf: [0, 0, 0, 1])
            data.append(bytes + offset, count: size)
            offset += size
        }
        return data
    }
}
