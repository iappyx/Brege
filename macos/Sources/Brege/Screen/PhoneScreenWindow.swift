import AppKit
import AVFoundation
import SwiftUI

/// What a screen window shows: the phone display, one app on its own virtual display, or
/// Android's desktop mode on a large virtual display.
struct ScreenTarget: Codable, Hashable {
    let deviceId: String
    var package: String?
    var label: String?
    var desktop = false

    var usesVirtualDisplay: Bool { desktop || package != nil }
}

/// State of one phone-screen window.
@MainActor
final class PhoneScreenModel: ObservableObject {
    enum Phase: Equatable {
        case connecting(String)
        case streaming
        case adbMissing
        case wirelessDebuggingOff
        case needsPairing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .connecting("Connecting…")
    @Published private(set) var videoSize: CGSize = .zero
    @Published private(set) var phoneDisplayOff = false
    @Published private(set) var pairing = false

    let decoder = ScreenVideoDecoder()
    private let audio = ScreenAudioPlayer()
    private var session: ScreenSession?
    private var adb: Adb?
    private var phoneIP: String?
    private(set) var isVirtualDisplay = false
    private var displaySize: (width: Int, height: Int)?
    private var fittedToWindow = false
    /// Invalidates earlier "did not open in a window" checks.
    private var openCheck = 0

    func start(target: ScreenTarget) {
        guard session == nil else { return }
        let deviceId = target.deviceId
        guard let adb = Adb.locate() else {
            phase = .adbMissing
            return
        }
        guard let ip = AppModel.shared.phoneIP(deviceId: deviceId) else {
            phase = .failed(ScreenSession.Failure.notConnected.localizedDescription)
            return
        }
        self.adb = adb
        phoneIP = ip
        phase = .connecting("Connecting…")
        phoneDisplayOff = false

        var display: ScreenSession.VirtualDisplay?
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        if let package = target.package {
            guard AppModel.shared.isValidPackage(package) else {
                phase = .failed("“\(package)” is not a valid app.")
                return
            }
            let size = displaySize ?? (width: Int(420 * scale), height: Int(820 * scale))
            display = ScreenSession.VirtualDisplay(package: package, width: size.width, height: size.height, dpi: Int(200 * scale))
        }
        var desktop: ScreenSession.DesktopDisplay?
        if target.desktop {
            // One Android dp per Mac point, so the desktop feels like a Mac-sized screen. The
            // simulated display has a fixed size; the window keeps its aspect ratio.
            desktop = ScreenSession.DesktopDisplay(width: Int(Self.desktopSize.width * scale),
                                                   height: Int(Self.desktopSize.height * scale), dpi: Int(160 * scale))
        }
        isVirtualDisplay = display != nil
        fittedToWindow = false
        decoder.resetFrames()
        let session = ScreenSession(adb: adb, phoneIP: ip, display: display, desktop: desktop)
        session.switchOnWirelessDebugging = {
            DispatchQueue.main.sync { AppModel.shared.switchOnWirelessDebugging(deviceId: deviceId) }
        }
        let decoder = decoder
        let audio = audio
        decoder.onNeedsKeyFrame = { [weak session] in session?.send(ScreenControl.resetVideo()) }
        session.onStatus = { [weak self] status in
            Task { @MainActor in
                guard let self, case .connecting = self.phase else { return }
                if !status.isEmpty { self.phase = .connecting(status) }
            }
        }
        session.onVideoCodec = { codec in decoder.setCodec(codec) }
        session.onLargeScreen = { [weak self] in
            Task { @MainActor in self?.onWantsWindowSize?(Self.tabletAppSize) }
        }
        session.onVideoSize = { [weak self, weak session] size in
            Task { @MainActor in
                guard let self, let session, self.session === session else { return }
                self.videoSize = size
                self.phase = .streaming
                if let package = target.package, !decoder.hasFrame {
                    self.checkOpened(session: session, name: target.label ?? package)
                }
                // The window may have changed size while the app display was starting.
                if self.isVirtualDisplay, !self.fittedToWindow, let d = self.displaySize,
                   d.width != Int(size.width) || d.height != Int(size.height) {
                    self.fittedToWindow = true
                    self.send(ScreenControl.resizeDisplay(width: d.width, height: d.height))
                }
            }
        }
        session.onVideoPacket = { packet in decoder.decode(packet) }
        session.onPhoneDisplayTurnedOff = { [weak self] in
            Task { @MainActor in self?.phoneDisplayOff = true }
        }
        session.onAudio = { pcm in audio.append(pcm) }
        session.onClipboard = { text in
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                ClipboardMonitor.markOwnWrite()
            }
        }
        // Only for the current session: after stop() or a retry, the old session's end would
        // replace the window's message or drop the new session.
        let sessionID = session.id
        session.onEnd = { [weak self] error in
            Task { @MainActor in
                guard let self, self.session?.id == sessionID else { return }
                self.ended(error)
            }
        }
        self.session = session
        audio.start()
        session.start()
    }

    /// Some apps (such as Settings) refuse to run on a second display and never draw. Counted from
    /// the latest stream start (a retry with another codec starts again), not from connecting.
    private func checkOpened(session: ScreenSession, name: String) {
        openCheck += 1
        let check = openCheck
        DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self, weak session] in
            guard let self, let session, self.session === session, self.openCheck == check,
                  self.phase == .streaming, !self.decoder.hasFrame else { return }
            self.stop()
            self.phase = .failed("“\(name)” did not open in a window. Some apps only run on the phone's own screen.")
        }
    }

    func stop() {
        session?.stop()
        session = nil
        audio.stop()
    }

    func retry(target: ScreenTarget) {
        stop()
        start(target: target)
    }

    static let desktopSize = CGSize(width: 1280, height: 800)
    /// App windows for a tablet open this large; phone apps keep the scene's phone-sized default.
    static let tabletAppSize = CGSize(width: 1100, height: 760)
    /// Set by the window's view: grows the window once, before the app is shown.
    var onWantsWindowSize: ((CGSize) -> Void)?

    /// Virtual displays follow the window size (in pixels, even numbers).
    func windowResized(pixelWidth: Int, pixelHeight: Int) {
        guard isVirtualDisplay else { return }
        let size = (width: max(320, pixelWidth & ~1), height: max(320, pixelHeight & ~1))
        if let displaySize, displaySize == size { return }
        displaySize = size
        guard phase == .streaming else { return }
        send(ScreenControl.resizeDisplay(width: size.width, height: size.height))
    }

    func pair(code: String, target: ScreenTarget) {
        guard let adb, let phoneIP else { return }
        pairing = true
        Task.detached {
            let result = Result { try adb.pair(phoneIP: phoneIP, code: code) }
            await MainActor.run {
                self.pairing = false
                switch result {
                case .success: self.retry(target: target)
                case let .failure(error): self.phase = .failed(error.localizedDescription)
                }
            }
        }
    }

    private func ended(_ error: Error?) {
        session = nil
        audio.stop()
        switch error {
        case nil: phase = .failed("Screen sharing ended.")
        case Adb.Failure.wirelessDebuggingOff?: phase = .wirelessDebuggingOff
        case Adb.Failure.notPaired?: phase = .needsPairing
        case let error?: phase = .failed(error.localizedDescription)
        }
    }

    // MARK: Controls

    func send(_ message: Data) {
        session?.send(message)
    }

    func press(_ key: ScreenControl.Key) {
        send(ScreenControl.key(.down, key.rawValue))
        send(ScreenControl.key(.up, key.rawValue))
    }

    func togglePhoneDisplay() {
        phoneDisplayOff.toggle()
        send(ScreenControl.setDisplayPower(!phoneDisplayOff))
    }
}

struct PhoneScreenWindow: View {
    let target: ScreenTarget
    private var deviceId: String { target.deviceId }
    @StateObject private var model = PhoneScreenModel()
    @EnvironmentObject private var app: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var code = ""

    var body: some View {
        ZStack {
            Color.black
            PhoneScreenRepresentable(model: model, desktop: target.desktop)
                .opacity(model.phase == .streaming ? 1 : 0)
            if model.phase != .streaming {
                overlay
                    .padding(24)
                    .frame(maxWidth: 360)
            }
        }
        .frame(minWidth: 280, minHeight: 400)
        .navigationTitle(title)
        .toolbar {
            ToolbarItemGroup {
                if target.desktop {
                    Button { model.press(.back) } label: { Label("Back", systemImage: "chevron.backward") }
                        .help("Back (right-click or Esc)")
                    Button { model.press(.home) } label: { Label("Home", systemImage: "circle") }
                        .help("Desktop home (middle-click)")
                    Button { model.press(.appSwitch) } label: { Label("Recent apps", systemImage: "square.on.square") }
                        .help("Recent apps")
                    Button { model.togglePhoneDisplay() } label: {
                        Label(model.phoneDisplayOff ? "Phone display on" : "Phone display off",
                              systemImage: model.phoneDisplayOff ? "iphone.slash" : "iphone")
                    }
                    .help(model.phoneDisplayOff ? "Turn the phone's own display back on" : "Keep the phone's own display dark")
                } else if target.package != nil {
                    Button { model.press(.back) } label: { Label("Back", systemImage: "chevron.backward") }
                        .help("Back (right-click or Esc)")
                    Button { model.togglePhoneDisplay() } label: {
                        Label(model.phoneDisplayOff ? "Phone display on" : "Phone display off",
                              systemImage: model.phoneDisplayOff ? "iphone.slash" : "iphone")
                    }
                    .help(model.phoneDisplayOff ? "Turn the phone's own display back on" : "Keep the phone's own display dark")
                } else {
                    mirrorControls
                }
            }
        }
        .onAppear { model.start(target: target) }
        .onDisappear { model.stop() }
    }

    private var title: String {
        let phone = app.devices.first { $0.id == deviceId }?.name ?? "Phone"
        if target.desktop { return "\(phone) — Desktop" }
        return target.label.map { "\($0) — \(phone)" } ?? phone
    }

    @ViewBuilder
    private var mirrorControls: some View {
        Group {
                Button { model.press(.back) } label: { Label("Back", systemImage: "chevron.backward") }
                    .help("Back (right-click or Esc)")
                Button { model.press(.home) } label: { Label("Home", systemImage: "circle") }
                    .help("Home")
                Button { model.press(.appSwitch) } label: { Label("Recent apps", systemImage: "square.on.square") }
                    .help("Recent apps")
                Button { model.send(ScreenControl.expandNotifications()) } label: { Label("Notifications", systemImage: "bell") }
                    .help("Open the phone's notifications")
                Button { model.send(ScreenControl.rotate()) } label: { Label("Rotate", systemImage: "rotate.right") }
                    .help("Rotate the phone screen")
                Button { model.togglePhoneDisplay() } label: {
                    Label(model.phoneDisplayOff ? "Phone display on" : "Phone display off",
                          systemImage: model.phoneDisplayOff ? "iphone.slash" : "iphone")
                }
                .help(model.phoneDisplayOff ? "Turn the phone's own display back on" : "Keep the phone's own display dark while you use it here")
                Button {
                    openWindow(id: "phone-apps", value: deviceId)
                } label: { Label("Apps", systemImage: "square.grid.3x3") }
                    .help("Open a phone app in its own window")
        }
    }

    @ViewBuilder
    private var overlay: some View {
        VStack(spacing: 14) {
            switch model.phase {
            case let .connecting(status):
                ProgressView()
                Text(status)
            case .streaming:
                EmptyView()
            case .adbMissing:
                Image(systemName: "wrench.and.screwdriver").font(.largeTitle)
                Text(Adb.Failure.notInstalled.localizedDescription).multilineTextAlignment(.center)
                Button("Try again") { model.retry(target: target) }
            case .wirelessDebuggingOff:
                Image(systemName: "wifi.exclamationmark").font(.largeTitle)
                Text("Turn on Wireless debugging").font(.headline)
                Text("On your phone: Settings › System › Developer options › Wireless debugging. If you don't see Developer options, tap Settings › About phone › Build number seven times.")
                    .multilineTextAlignment(.center)
                Button("Try again") { model.retry(target: target) }
            case .needsPairing:
                Image(systemName: "link").font(.largeTitle)
                Text("Pair this Mac once").font(.headline)
                Text("On your phone, open Settings › System › Developer options › Wireless debugging and tap “Pair device with pairing code”. Enter the six-digit code shown:")
                    .multilineTextAlignment(.center)
                TextField("Pairing code", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                    .multilineTextAlignment(.center)
                    .onSubmit(pair)
                Button(model.pairing ? "Pairing…" : "Pair", action: pair)
                    .disabled(model.pairing || code.filter(\.isNumber).count != 6)
            case let .failed(message):
                Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                Text(message).multilineTextAlignment(.center)
                Button("Try again") { model.retry(target: target) }
            }
        }
        .foregroundStyle(.white)
        .padding(20)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
    }

    private func pair() {
        let digits = code.filter(\.isNumber)
        guard digits.count == 6 else { return }
        model.pair(code: digits, target: target)
    }
}

private struct PhoneScreenRepresentable: NSViewRepresentable {
    let model: PhoneScreenModel
    let desktop: Bool

    func makeNSView(context: Context) -> PhoneScreenView {
        PhoneScreenView(model: model, desktop: desktop)
    }

    func updateNSView(_ view: PhoneScreenView, context: Context) {
        if model.phase == .streaming, view.window?.firstResponder !== view {
            view.window?.makeFirstResponder(view)
        }
    }
}

/// Shows the video and turns mouse, trackpad and keyboard input into phone input.
final class PhoneScreenView: NSView {
    private let model: PhoneScreenModel
    /// Read from the model on each event: SwiftUI does not update this view when it changes.
    private var videoSize: CGSize { model.videoSize }
    private var pressed = false

    private let desktop: Bool

    init(model: PhoneScreenModel, desktop: Bool) {
        self.model = model
        self.desktop = desktop
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = .black
        layer?.addSublayer(model.decoder.layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        if desktop, videoSize.width > 0, window?.contentAspectRatio != videoSize {
            window?.contentAspectRatio = videoSize
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        model.decoder.layer.frame = bounds
        CATransaction.commit()
        let pixels = convertToBacking(bounds).size
        model.windowResized(pixelWidth: Int(pixels.width), pixelHeight: Int(pixels.height))
    }

    private var sizedWindow = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
        // Desktop windows open Mac-screen sized; the scene's default size suits a phone.
        if desktop, !sizedWindow, let window {
            sizedWindow = true
            window.setContentSize(PhoneScreenModel.desktopSize)
            window.center()
        }
        model.onWantsWindowSize = { [weak self] size in
            guard let self, !self.sizedWindow, let window = self.window else { return }
            self.sizedWindow = true
            // Never larger than the screen the window is on.
            let visible = window.screen?.visibleFrame.size ?? size
            window.setContentSize(CGSize(width: min(size.width, visible.width - 40), height: min(size.height, visible.height - 60)))
            window.center()
        }
    }

    /// Maps a window location to video pixels, or nil outside the picture.
    private func videoPoint(_ event: NSEvent, clamp: Bool = false) -> CGPoint? {
        guard videoSize.width > 0 else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        let picture = AVMakeRect(aspectRatio: videoSize, insideRect: bounds)
        guard clamp || picture.contains(p) else { return nil }
        let x = (p.x - picture.minX) / picture.width * videoSize.width
        let y = (picture.maxY - p.y) / picture.height * videoSize.height
        return CGPoint(x: min(max(x, 0), videoSize.width - 1), y: min(max(y, 0), videoSize.height - 1))
    }

    // MARK: Mouse and trackpad

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let point = videoPoint(event) else { return }
        pressed = true
        model.send(ScreenControl.touch(.down, at: point, videoSize: videoSize))
    }

    override func mouseDragged(with event: NSEvent) {
        guard pressed, let point = videoPoint(event, clamp: true) else { return }
        model.send(ScreenControl.touch(.move, at: point, videoSize: videoSize))
    }

    override func mouseUp(with event: NSEvent) {
        guard pressed, let point = videoPoint(event, clamp: true) else { return }
        pressed = false
        model.send(ScreenControl.touch(.up, at: point, videoSize: videoSize))
    }

    override func rightMouseDown(with event: NSEvent) {
        model.send(ScreenControl.backOrScreenOn(.down))
        model.send(ScreenControl.backOrScreenOn(.up))
    }

    override func otherMouseDown(with event: NSEvent) {
        model.press(.home)
    }

    override func scrollWheel(with event: NSEvent) {
        guard let point = videoPoint(event, clamp: true) else { return }
        // Trackpads report pixels, mouse wheels report lines.
        let scale = event.hasPreciseScrollingDeltas ? 1.0 / 24 : 1.0
        let vertical = Double(event.scrollingDeltaY) * scale
        let horizontal = -Double(event.scrollingDeltaX) * scale
        guard vertical != 0 || horizontal != 0 else { return }
        model.send(ScreenControl.scroll(at: point, videoSize: videoSize, horizontal: horizontal, vertical: vertical))
    }

    // MARK: Keyboard

    private static let keyMap: [UInt16: ScreenControl.Key] = [
        36: .enter, 76: .enter, 51: .delete, 117: .forwardDelete, 48: .tab, 53: .back,
        123: .dpadLeft, 124: .dpadRight, 125: .dpadDown, 126: .dpadUp,
        115: .moveHome, 119: .moveEnd, 116: .pageUp, 121: .pageDown,
    ]

    private func metaState(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var meta: UInt32 = 0
        if flags.contains(.shift) { meta |= 0x41 } // META_SHIFT_ON | META_SHIFT_LEFT_ON
        if flags.contains(.option) { meta |= 0x12 } // META_ALT_ON | META_ALT_LEFT_ON
        if flags.contains(.control) { meta |= 0x3000 } // META_CTRL_ON | META_CTRL_LEFT_ON
        return meta
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            super.keyDown(with: event)
            return
        }
        if let key = Self.keyMap[event.keyCode] {
            model.send(ScreenControl.key(.down, key.rawValue, repeatCount: event.isARepeat ? 1 : 0, metaState: metaState(event.modifierFlags)))
            return
        }
        guard let characters = event.characters, !characters.isEmpty,
              !event.modifierFlags.contains(.control),
              characters.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F && !(0xF700...0xF8FF).contains($0.value) })
        else { return }
        model.send(ScreenControl.text(characters))
    }

    override func keyUp(with event: NSEvent) {
        guard !event.modifierFlags.contains(.command), let key = Self.keyMap[event.keyCode] else { return }
        model.send(ScreenControl.key(.up, key.rawValue, metaState: metaState(event.modifierFlags)))
    }

    /// ⌘V: paste the Mac clipboard into the focused field on the phone.
    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        model.send(ScreenControl.setClipboard(text, paste: true))
    }

    /// ⌘C: copy the phone's selection to the Mac clipboard.
    @objc func copy(_ sender: Any?) {
        model.send(ScreenControl.getClipboard(copyKey: 1))
    }

    /// ⌘X: cut the phone's selection to the Mac clipboard.
    @objc func cut(_ sender: Any?) {
        model.send(ScreenControl.getClipboard(copyKey: 2))
    }
}
