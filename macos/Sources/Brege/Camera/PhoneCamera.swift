import AppKit
import AVFoundation
import BregeCore
import SwiftUI

/// Phone camera on the Mac: a live window with switching, torch and recording. Also usable as a
/// webcam through screen sharing or OBS; Brêge's own camera extension needs the paid Developer
/// Program.
@MainActor
final class PhoneCameraModel: ObservableObject {
    @Published private(set) var state: CameraStateData?
    @Published private(set) var status: String = "Starting the camera…"
    @Published private(set) var recordingSince: Date?
    /// The camera state a recording started with: the movie cannot follow a turn or a new stream.
    private var recordingState: CameraStateData?
    @Published var mirrored = true
    @Published private(set) var videoSize: CGSize = .zero

    let decoder = ScreenVideoDecoder()
    private let recorder = CameraRecorder()
    private let receiver: CameraVideoReceiver
    private let router: CameraVideoRouter
    let deviceId: String
    private var open = false
    private let node: () -> BregeNode?
    private let presenter: NotificationPresenter
    private var front = UserDefaults.standard.object(forKey: "cameraFront") as? Bool ?? true

    static let recordingsFolder = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Brêge", isDirectory: true)

    init(deviceId: String, router: CameraVideoRouter, node: @escaping () -> BregeNode?, presenter: NotificationPresenter) {
        self.deviceId = deviceId
        self.router = router
        self.node = node
        self.presenter = presenter
        receiver = CameraVideoReceiver(decoder: decoder, recorder: recorder)
        Self.instances.add(self)
    }

    /// Every camera model alive, so recordings can be finished when Brêge quits.
    private static let instances = NSHashTable<PhoneCameraModel>.weakObjects()

    /// Whether any camera window is recording.
    static var isRecordingAny: Bool {
        instances.allObjects.contains { $0.recordingSince != nil }
    }

    /// Stops and saves every recording; `completion` runs on the main queue once all movies are
    /// written, or after 5 seconds at most.
    static func finishAllRecordings(completion: @escaping () -> Void) {
        let recording = instances.allObjects.filter { $0.recordingSince != nil }
        guard !recording.isEmpty else {
            DispatchQueue.main.async { completion() }
            return
        }
        // Both run on the main queue, so `called` needs no lock.
        var called = false
        let finish = {
            guard !called else { return }
            called = true
            completion()
        }
        var remaining = recording.count
        for camera in recording {
            camera.stopRecording {
                remaining -= 1
                if remaining == 0 { finish() }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { finish() }
    }

    var isActive: Bool { state?.active == true }
    var isFront: Bool { state?.front ?? front }

    func start() {
        open = true
        router.set(receiver, for: deviceId)
        status = "Starting the camera…"
        request(start: true, front: front, torch: false)
    }

    func close() {
        guard open else { return }
        open = false
        if recordingSince != nil { stopRecording() }
        try? node()?.requestCamera(deviceId: deviceId, start: false, front: front, torch: false, audio: false)
        router.set(nil, for: deviceId)
        state = nil
    }

    func switchCamera() {
        front = !isFront
        UserDefaults.standard.set(front, forKey: "cameraFront")
        mirrored = front
        request(start: true, front: front, torch: false)
    }

    func toggleTorch() {
        request(start: true, front: isFront, torch: !(state?.torch ?? false))
    }

    private func request(start: Bool, front: Bool, torch: Bool) {
        guard open else { return }
        do {
            try node()?.requestCamera(deviceId: deviceId, start: start, front: front, torch: torch, audio: true)
        } catch {
            status = "The phone is not connected."
        }
    }

    func stateChanged(_ state: CameraStateData) {
        guard open else { return }
        let wasFront = self.state?.front
        self.state = state
        if state.active {
            decoder.setCodec(state.codec == "h264" ? .h264 : .h265)
            receiver.codec = state.codec == "h264" ? .h264 : .h265
            videoSize = CGSize(width: Int(state.width), height: Int(state.height))
            if wasFront != state.front { mirrored = state.front }
            status = ""
            if recordingSince != nil, let started = recordingState,
               started.rotation != state.rotation || started.codec != state.codec || started.front != state.front
               || started.width != state.width || started.height != state.height {
                stopRecording(title: "Recording saved — the camera turned or changed")
            }
        } else {
            status = state.detail.isEmpty ? "The camera stopped." : state.detail
            if recordingSince != nil { stopRecording() }
        }
    }

    // MARK: Recording

    func toggleRecording() {
        recordingSince == nil ? startRecording() : stopRecording()
    }

    private func startRecording() {
        guard let state, state.active else { return }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = Self.recordingsFolder.appendingPathComponent("Phone Camera \(stamp.string(from: Date())).mov")
        do {
            try recorder.start(to: url, codec: state.codec == "h264" ? .h264 : .h265, rotation: Int(state.rotation))
            recordingSince = Date()
            recordingState = state
        } catch {
            presenter.showInfo(title: "Could not start recording", body: error.localizedDescription)
        }
    }

    /// `finished` runs on the main queue once the movie is written (or discarded).
    private func stopRecording(title: String? = nil, finished: (() -> Void)? = nil) {
        recordingSince = nil
        recordingState = nil
        let presenter = presenter
        recorder.stop { url in
            DispatchQueue.main.async {
                defer { finished?() }
                if let url {
                    presenter.showFileReceived(path: url.path, title: title ?? "File received")
                } else {
                    presenter.showInfo(title: "Nothing was recorded", body: "The recording stopped before the first picture arrived.")
                }
            }
        }
    }
}

/// Core-thread side: packets go to the live view and, while recording, to the movie.
final class CameraVideoReceiver: VideoPacketListener, @unchecked Sendable {
    private let decoder: ScreenVideoDecoder
    private let recorder: CameraRecorder
    var codec: ScreenSession.VideoCodec = .h265

    init(decoder: ScreenVideoDecoder, recorder: CameraRecorder) {
        self.decoder = decoder
        self.recorder = recorder
    }

    func onVideoPacket(from: String, flags: UInt8, ptsUs: UInt64, data: Data) {
        decoder.decode(ScreenSession.VideoPacket(data: data, isConfig: flags & 1 != 0, isKeyFrame: flags & 2 != 0))
        recorder.appendVideo(flags: flags, ptsUs: ptsUs, data: data)
    }

    func onVideoEnd(from: String) {}

    func appendAudio(seq: UInt32, pcm: Data) {
        recorder.appendAudio(seq: seq, pcm: pcm)
    }
}

/// The core has one video listener: packets and phone microphone audio go to the camera of the
/// phone they came from.
final class CameraVideoRouter: VideoPacketListener, @unchecked Sendable {
    private let lock = NSLock()
    private var receivers: [String: CameraVideoReceiver] = [:]

    func set(_ receiver: CameraVideoReceiver?, for deviceId: String) {
        lock.lock()
        receivers[deviceId] = receiver
        lock.unlock()
    }

    private func receiver(_ deviceId: String) -> CameraVideoReceiver? {
        lock.lock()
        defer { lock.unlock() }
        return receivers[deviceId]
    }

    func onVideoPacket(from: String, flags: UInt8, ptsUs: UInt64, data: Data) {
        receiver(from)?.onVideoPacket(from: from, flags: flags, ptsUs: ptsUs, data: data)
    }

    func onVideoEnd(from: String) {
        receiver(from)?.onVideoEnd(from: from)
    }

    func audio(from: String, seq: UInt32, pcm: Data) {
        receiver(from)?.appendAudio(seq: seq, pcm: pcm)
    }
}

struct PhoneCameraWindow: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var camera: PhoneCameraModel
    private var deviceName: String? { app.device(camera.deviceId)?.name }

    var body: some View {
        ZStack {
            Color.black
            CameraLayerView(camera: camera, rotation: Int(camera.state?.rotation ?? 0))
                .opacity(camera.isActive ? 1 : 0)
            if !camera.isActive {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(camera.status).multilineTextAlignment(.center)
                }
                .foregroundStyle(.white)
                .padding(24)
            }
            if let since = camera.recordingSince {
                VStack {
                    HStack {
                        TimelineView(.periodic(from: since, by: 1)) { context in
                            Label(Self.elapsed(from: since, to: context.date), systemImage: "record.circle.fill")
                                .font(.callout.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(.red, in: Capsule())
                        }
                        Spacer()
                    }
                    Spacer()
                }
                .padding(12)
            }
        }
        .frame(minWidth: 320, minHeight: 240)
        .navigationTitle(deviceName.map { "\($0) Camera" } ?? "Phone Camera")
        .toolbar {
            ToolbarItemGroup {
                Button { camera.switchCamera() } label: {
                    Label("Switch Camera", systemImage: "arrow.triangle.2.circlepath.camera")
                }
                .disabled(camera.recordingSince != nil)
                .help(camera.recordingSince == nil ? "Switch between the front and back camera"
                      : "Stop recording to switch the camera: a recording keeps one camera")
                Button { camera.toggleTorch() } label: {
                    Label("Torch", systemImage: camera.state?.torch == true ? "flashlight.on.fill" : "flashlight.off.fill")
                }
                .disabled(camera.state?.torchAvailable != true)
                .help("Turn the phone's light on or off")
                Toggle(isOn: $camera.mirrored) { Label("Mirror", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                    .help("Mirror the picture (recordings are never mirrored)")
                Button { camera.toggleRecording() } label: {
                    Label(camera.recordingSince == nil ? "Record" : "Stop Recording",
                          systemImage: camera.recordingSince == nil ? "record.circle" : "stop.circle.fill")
                }
                .disabled(!camera.isActive)
                .help(camera.recordingSince == nil ? "Record video with sound to Movies › Brêge" : "Stop and save the recording")
                Button { NSWorkspace.shared.open(PhoneCameraModel.recordingsFolder) } label: {
                    Label("Recordings", systemImage: "folder")
                }
                .help("Show recordings in Finder")
            }
        }
        .onAppear { camera.start() }
        .onDisappear { camera.close() }
    }

    private static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// The video layer, turned upright and optionally mirrored.
private struct CameraLayerView: NSViewRepresentable {
    @ObservedObject var camera: PhoneCameraModel
    let rotation: Int

    func makeNSView(context: Context) -> CameraLayerHost {
        CameraLayerHost(layer: camera.decoder.layer)
    }

    func updateNSView(_ view: CameraLayerHost, context: Context) {
        view.rotation = rotation
        view.mirrored = camera.mirrored
        view.needsLayout = true
    }
}

final class CameraLayerHost: NSView {
    private let videoLayer: AVSampleBufferDisplayLayer
    var rotation = 0
    var mirrored = false

    init(layer: AVSampleBufferDisplayLayer) {
        videoLayer = layer
        super.init(frame: .zero)
        wantsLayer = true
        self.layer?.backgroundColor = .black
        self.layer?.addSublayer(videoLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let sideways = rotation % 180 != 0
        let size = sideways ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
        videoLayer.bounds = CGRect(origin: .zero, size: size)
        videoLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        // Layers turn counterclockwise for positive angles; the phone reports clockwise degrees.
        var transform = CATransform3DMakeRotation(-CGFloat(rotation) * .pi / 180, 0, 0, 1)
        // Mirror after turning, so the flip is always left–right on screen.
        if mirrored { transform = CATransform3DConcat(transform, CATransform3DMakeScale(-1, 1, 1)) }
        videoLayer.transform = transform
        CATransaction.commit()
    }
}
