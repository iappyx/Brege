import CoreMedia
import Foundation
import ScreenCaptureKit

/// Captures one display's pixels, for sending to the tablet that is standing in for it.
///
/// Only the display Brêge created is ever captured, never the Mac's own screens — but macOS cannot
/// tell those apart, so this needs Screen Recording in Privacy & Security, and the system's own
/// recording indicator appears while a session runs. That is the honest outcome and worth saying out
/// loud in the UI rather than letting someone discover the indicator and wonder.
@available(macOS 13.0, *)
final class DisplayCapture: NSObject, SCStreamOutput, @unchecked Sendable {
    enum Failure: LocalizedError {
        case notShareable
        case noPermission(Error)

        var errorDescription: String? {
            switch self {
            case .notShareable:
                return "macOS did not offer the second display for capture."
            case let .noPermission(underlying):
                // Not necessarily the permission: ScreenCaptureKit reports a refused grant and a
                // dozen other things the same way, so say which one it was.
                let error = underlying as NSError
                return "macOS would not list the displays for capture: \(error.domain) \(error.code)"
                    + " — \(error.localizedDescription). If this is the permission, Brêge needs"
                    + " Screen Recording in System Settings › Privacy & Security."
            }
        }
    }

    /// One captured frame, and whether macOS had anything new to put in it.
    struct Frame {
        let sample: CMSampleBuffer
        let isNew: Bool
        let size: CGSize
    }

    private let queue = DispatchQueue(label: "app.brege.display.capture")
    private let onFrame: (Frame) -> Void
    private var stream: SCStream?

    init(onFrame: @escaping (Frame) -> Void) {
        self.onFrame = onFrame
        super.init()
    }

    /// Starts capturing `displayID` at its own size. Throws when the permission is missing, which is
    /// the only failure worth telling the user about by name.
    func start(displayID: CGDirectDisplayID, width: Int, height: Int, framesPerSecond: Int) async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw Failure.noPermission(error)
        }
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw Failure.notShareable
        }

        let configuration = SCStreamConfiguration()
        configuration.width = width
        configuration.height = height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(framesPerSecond))
        configuration.queueDepth = 5
        // The tablet has no cursor of its own, so the Mac's has to be in the pixels.
        configuration.showsCursor = true
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange

        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                              configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        let stream = self.stream
        self.stream = nil
        try? await stream?.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        // ScreenCaptureKit keeps sending frames when nothing has changed; those carry no image and
        // must not be encoded, or a still screen would cost a stream's worth of bitrate.
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
            as? [[SCStreamFrameInfo: Any]]
        let raw = attachments?.first?[.status] as? Int
        let isNew = raw.flatMap(SCFrameStatus.init(rawValue:)) == .complete
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            onFrame(Frame(sample: sampleBuffer, isNew: false, size: .zero))
            return
        }
        let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        onFrame(Frame(sample: sampleBuffer, isNew: isNew, size: size))
    }
}
