import AppKit
import BregeCore
import Foundation
import SwiftUI

/// Shell state: a view over the core. All mutation happens on the main actor.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    struct PairingRequest: Identifiable, Equatable {
        let id: UInt64
        let deviceId: String
        let name: String
    }

    struct Transfer: Identifiable, Equatable {
        let id: String
        var name: String
        var bytes: UInt64
        var total: UInt64
        var incoming: Bool
        var done: Bool
        var failed: String?
    }

    @Published private(set) var devices: [Device] = []
    @Published private(set) var statuses: [String: StatusData] = [:]
    @Published private(set) var media: [String: MediaData] = [:]
    @Published private(set) var notifications: [StoredNotification] = []
    @Published private(set) var transfers: [Transfer] = []
    @Published private(set) var inviteURI: String?
    /// Name of the phone that just paired, shown in the pairing window before it closes.
    @Published private(set) var justPaired: String?
    @Published var pairingRequest: PairingRequest?
    @Published private(set) var startupError: String?
    @Published private(set) var lastOpenRequest: OpenRequestData?
    @Published private(set) var notificationsBlocked = false
    @Published private(set) var localNetworkDenied = false
    /// Last interface report sent to the core (network privacy plan).
    private var networkSnapshot: [NetworkInterfaceData]?
    /// Networks the Mac is on and tunnels that blocked a phone, for "Trust this network".
    @Published private(set) var networkPaths: [NetworkPathData] = []
    @Published private(set) var knownNetworks: [KnownNetworkData] = []
    private var bonjourTimer: Timer?

    private var node: BregeNode?
    private var listener: Listener?
    private let clipboard = ClipboardMonitor()
    private let presenter = NotificationPresenter()
    let live = OngoingActivitiesModel()
    private var cameras: [String: PhoneCameraModel] = [:]
    private lazy var videoRouter = CameraVideoRouter()
    private var recentPhotoModels: [String: RecentPhotosModel] = [:]
    private lazy var callAudio = CallAudioPauser()
    private lazy var batteryAlerts = BatteryAlerts(presenter: presenter)
    private(set) lazy var hotspot = PhoneHotspot(advertiser: ble, presenter: presenter) { [weak self] in self?.node }
    /// Import from phone (photo / document scan).
    private(set) lazy var capture = PhoneCapture(presenter: presenter) { [weak self] in self?.node }
    private var bonjour: BonjourAdvertiser?
    private let ble = PresenceAdvertiser()
    private let mediaControls = MediaControlsBridge()
    /// One Messages model per phone, created on first use.
    private var messageModels: [String: MessagesModel] = [:]
    private var callModels: [String: CallsModel] = [:]
    private var photoModels: [String: PhotosModel] = [:]
    private var appInventoryModels: [String: AppInventoryModel] = [:]
    private var conditionsModels: [String: ConditionsModel] = [:]
    private let callPanel = CallPanelController()
    private let drives = PhoneDriveController()
    let microphone = PhoneMicrophone()
    /// Ring, lock and volume, asked for by a phone or the watch behind it.
    let macActions = MacActions()
    /// Mirrored here because a view watches this model, not the one inside it.
    @Published private(set) var macRinging = false
    /// Device id whose microphone is in use, and a status line for the menu.
    @Published private(set) var micDevice: String? {
        didSet { microphone.playingFrom = micDevice }
    }
    @Published private(set) var micStatus: String?
    /// Phones whose drive is being opened in Finder.
    @Published private(set) var openingDrives: Set<String> = []
    @Published private(set) var activeCall: (deviceId: String, call: CallData)?
    /// Calls in progress per phone; the call panel shows `activeCall`.
    private var calls: [String: CallData] = [:]
    /// Unread conversations per phone.
    @Published private(set) var unreadMessages: [String: Int] = [:]
    /// The phone's controls (torch, sound, Do Not Disturb, alarm, storage, battery detail).
    @Published private(set) var phoneControls: [String: PhoneControlsData] = [:]
    /// Missed calls since the calls window was last opened, per phone.
    @Published private(set) var missedCalls: [String: Int] = [:]
    /// The phone used last from the menu or a window, for actions without a phone of their own
    /// (Services).
    private var lastUsedDevice: String?
    private var servicesWritten = false
    private var networkMonitor: NetworkChangeMonitor?
    private var transferNames: [String: String] = [:]

    static let defaultPort: UInt16 = 47400

    /// The core's error when the listening port is taken ("Address already in use", EADDRINUSE).
    private static func isAddressInUse(_ error: Error) -> Bool {
        let text = "\(error)"
        return text.contains("Address already in use") || text.contains("os error 48")
    }

    var anyConnected: Bool { devices.contains { $0.connected } }

    /// The core node is running (`start()` finished).
    var isStarted: Bool { node != nil }

    func device(_ id: String) -> Device? { devices.first { $0.id == id } }

    /// Remembers the phone an action was started for.
    func used(_ deviceId: String) { lastUsedDevice = deviceId }

    /// Tells the phones what this Mac wants them to do for it: lock when the watch leaves, pass
    /// alerts to the wrist, allow playback keys. Sent when it changes and after every connect.
    func publishWatchSettings() {
        guard let node else { return }
        let settings = AppSettings.shared
        _ = node.publishWatchSettings(settings: WatchSettingsData(
            lockWhenWatchAway: settings.lockWhenWatchAway,
            alertsOnWatch: settings.alertsOnWatch,
            keyControl: settings.watchKeyControl && macActions.canSendKeys
        ))
    }

    private var batteryWatch: Timer?
    private var warnedAboutOwnBattery = false

    /// Warns once per discharge about this Mac's own battery, on the wrist only.
    private func checkOwnBattery() {
        let state = macActions.state(name: "")
        guard state.hasBattery else { return }
        if state.charging || state.battery > 15 {
            warnedAboutOwnBattery = false
            return
        }
        guard !warnedAboutOwnBattery else { return }
        warnedAboutOwnBattery = true
        alertWatch("This Mac is low", "\(state.battery)% left, not charging")
    }

    /// Something worth a buzz on the wrist while you are away from this Mac.
    func alertWatch(_ title: String, _ body: String) {
        guard let node, AppSettings.shared.alertsOnWatch else { return }
        _ = node.publishMacAlert(alert: MacAlertData(title: title, body: body))
    }

    /// Tells the phones how this Mac stands, which is what the watch shows.
    func publishMacState() {
        guard let node else { return }
        _ = node.publishMacState(state: macActions.state(name: Host.current().localizedName ?? "Mac"))
    }

    // --- folded phones ---------------------------------------------------------------------
    // With three phones the menu grows taller than the screen, so a phone can be folded to its
    // name and battery. The choice is remembered between launches.

    @Published private(set) var foldedDevices: Set<String> =
        Set(UserDefaults.standard.stringArray(forKey: "menu.foldedDevices") ?? [])

    func isFolded(_ deviceId: String) -> Bool { foldedDevices.contains(deviceId) }

    /// From three phones on, the menu is taller than a laptop screen, so the ones you are not
    /// using start folded. Done once: after that the choice is yours.
    private func foldExtraPhones() {
        let key = "menu.foldsSeeded"
        guard devices.count >= 3, !UserDefaults.standard.bool(forKey: key) else { return }
        let keepOpen = defaultConnectedDevice?.id ?? devices.first?.id
        foldedDevices.formUnion(devices.map(\.id).filter { $0 != keepOpen })
        UserDefaults.standard.set(Array(foldedDevices), forKey: "menu.foldedDevices")
        UserDefaults.standard.set(true, forKey: key)
    }

    func toggleFolded(_ deviceId: String) {
        if foldedDevices.contains(deviceId) {
            foldedDevices.remove(deviceId)
        } else {
            foldedDevices.insert(deviceId)
            // Panels of a folded phone would keep taking room in the menu without being visible.
            if controlsOpenFor == deviceId { controlsOpenFor = nil }
            if conditionsOpenFor == deviceId { conditionsOpenFor = nil }
        }
        UserDefaults.standard.set(Array(foldedDevices), forKey: "menu.foldedDevices")
    }

    /// The phone for actions that do not name one (Services): the one used last if it is
    /// connected, else the first connected one.
    var defaultConnectedDevice: Device? {
        lastUsedDevice.flatMap(device).flatMap { $0.connected ? $0 : nil } ?? devices.first(where: \.connected)
    }

    var primaryStatus: StatusData? {
        devices.first(where: \.connected).flatMap { statuses[$0.id] }
    }

    func start() async {
        guard node == nil else { return }
        // The wrist is the only place you would see this while the Mac is across the room.
        batteryWatch = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.checkOwnBattery() }
        }
        adbIdleWatch = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor [weak self] in self?.checkAdbIdle() }
        }
        macActions.onStateChanged = { [weak self] in
            guard let self else { return }
            macRinging = macActions.ringing
            publishMacState()
        }
        do {
            let secrets = try Secrets.loadOrCreate()
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            ).appendingPathComponent("Brege", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            let downloads = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads/Brêge", isDirectory: true)

            let listener = Listener(model: self)
            self.listener = listener
            let options = { (port: UInt16) in
                NodeOptions(
                    name: Host.current().localizedName ?? "Mac",
                    platform: .macOs,
                    appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev",
                    identitySeed: secrets.identitySeed,
                    dbPath: support.appendingPathComponent("brege.db").path,
                    dbKey: secrets.databaseKey,
                    listenPort: port,
                    downloadDir: downloads.path,
                    // Nothing but loopback until the first interface report below.
                    restrictNetworkUntilReported: true
                )
            }
            let node: BregeNode
            do {
                node = try await BregeNode.start(options: options(Self.defaultPort), listener: listener)
            } catch {
                // Port taken by something other than Brêge (a second Brêge quits at launch):
                // fall back to any free port. Other errors would fail again.
                guard Self.isAddressInUse(error), AppDelegate.otherInstance() == nil else { throw error }
                node = try await BregeNode.start(options: options(0), listener: listener)
            }
            self.node = node

            restartBonjour()
            ble.start()
            clipboard.onChange = { [weak self] clip, changeId in
                _ = self?.node?.localClipboardChanged(clip: clip, changeId: changeId)
            }
            clipboard.start()
            presenter.onAction = { [weak self] deviceId, key, act in
                self?.act(deviceId: deviceId, key: key, act: act)
            }
            presenter.onOpenURL = { url in NSWorkspace.shared.open(url) }
            presenter.onCallAction = { [weak self] action, deviceId in self?.callAction(action, deviceId: deviceId) }
            presenter.onMissedCall = { [weak self] deviceId, number, message in
                guard let self else { return }
                if message {
                    self.openMessages(deviceId: deviceId, composingTo: number)
                } else {
                    self.dial(number: number, deviceId: deviceId)
                }
            }
            presenter.onHotspotConnect = { [weak self] deviceId in
                guard let self, let device = self.devices.first(where: { $0.id == deviceId }) else { return }
                self.hotspot.connect(device)
            }
            hotspot.offerDevice = { [weak self] in self?.devices.first { self?.hotspot.ssid(for: $0.id) != nil } }
            hotspot.onPendingChanged = { [weak self] in self?.restartBonjour() }
            hotspot.startMonitoring()
            _ = browserTab // start following which browser was used last
            node.setAudioListener(listener: microphone)
            node.setVideoListener(listener: videoRouter)
            microphone.onFrame = { [videoRouter] from, seq, pcm in videoRouter.audio(from: from, seq: seq, pcm: pcm) }
            presenter.requestAuthorization()
            mediaControls.onCommand = { [weak self] deviceId, command in
                try? self?.node?.sendCommand(deviceId: deviceId, command: command)
            }
            networkMonitor = NetworkChangeMonitor(
                onChange: { [weak self] in self?.networkChanged() },
                onSleep: { [weak self] in self?.withdrawBonjour() },
                onWake: { [weak self] in self?.networkChanged() }
            )
            hotspot.location.onChange = { [weak self] in self?.reportNetwork() }
            presenter.onNetworkDecision = { [weak self] fingerprint, use in
                self?.decideNetwork(fingerprint, use: use)
            }
            presenter.onNetworkQuestionOpened = { [weak self] fingerprint, label in
                self?.askNetworkQuestion(fingerprint: fingerprint, label: label)
            }
            reportNetwork()
            // The Bonjour ids rotate every 15 minutes.
            bonjourTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.restartBonjour() }
            }
            refresh()
            if pairingWanted { beginPairing() }
        } catch {
            startupError = "\(error)"
        }
    }

    /// Sends the interfaces to the core when they change. Path updates are frequent, and reading
    /// routers runs tools, so this happens off the main thread and only reports real changes.
    /// Snapshots can finish out of order; only the newest one is applied.
    private func reportNetwork(retries: Int = 2) {
        networkGeneration += 1
        let generation = networkGeneration
        Task.detached {
            let snapshot = NetworkSnapshot.current()
            await MainActor.run {
                guard let node = self.node, generation == self.networkGeneration else { return }
                if snapshot != self.networkSnapshot {
                    self.networkSnapshot = snapshot
                    node.setNetworkInterfaces(interfaces: snapshot)
                    self.refreshNetworkPaths()
                }
                self.awaitingSnapshot = false
                self.restartBonjour()
                // Right after joining, the router is often not in the ARP table yet; without its
                // hardware address the network cannot be recognised, so look again shortly.
                let routerUnknown = snapshot.contains {
                    ($0.kind == .wifi || $0.kind == .ethernet) && !$0.gateway.isEmpty && $0.gatewayHw.isEmpty
                }
                guard routerUnknown, retries > 0 else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    guard let self, self.networkGeneration == generation else { return }
                    self.reportNetwork(retries: retries - 1)
                }
            }
        }
    }

    /// Increments per snapshot started, so a slower older one is dropped.
    private var networkGeneration = 0
    /// The network changed (or the Mac slept) and the core has not heard the new interfaces yet:
    /// Bonjour stays off until it has, so it never announces on a network not decided on.
    private var awaitingSnapshot = true

    /// Called on the main queue for every path change.
    private func networkChanged() {
        withdrawBonjour()
        reportNetwork()
    }

    /// Stops announcing at once; the next snapshot registers again where allowed.
    private func withdrawBonjour() {
        networkGeneration += 1 // a snapshot taken before this no longer counts
        awaitingSnapshot = true
        bonjour?.stop()
        bonjour = nil
    }

    /// Announces on trusted networks only, with the current rotating ids; re-registers when
    /// either changes.
    private func restartBonjour(force: Bool = false) {
        guard let node, !awaitingSnapshot else { return }
        let reachable = Set(LocalAddresses.reachable().map(\.name))
        let interfaces = node.announceInterfaces().filter { reachable.contains($0) }
        let tokens = node.bonjourTokens()
        // Only a registration can tell whether macOS allows Local Network access. With nothing to
        // announce (an untrusted network) there is no answer, so an earlier "denied" is not kept
        // showing; the next registration on a trusted network reports it again if it still holds.
        if interfaces.isEmpty, localNetworkDenied { localNetworkDenied = false }
        if !force, let bonjour, bonjour.tokens == tokens, bonjour.interfaces == interfaces { return }
        bonjour?.stop()
        let advertiser = BonjourAdvertiser(port: node.listenPort(), tokens: tokens, interfaces: interfaces)
        advertiser.onLocalNetworkDenied = { [weak self] denied in self?.localNetworkDenied = denied }
        advertiser.start()
        bonjour = advertiser
    }

    // MARK: - Networks (network privacy plan)

    /// Networks asked about during this run, so each is asked once.
    private var askedNetworks = Set<String>()
    /// Hears a paired phone nearby, so the network question only pops up when it is useful.
    private lazy var nearbyScanner: PhoneNearbyScanner = {
        let scanner = PhoneNearbyScanner()
        scanner.match = { [weak self] uuid in self?.node?.matchPresenceUuid(uuid: uuid) }
        scanner.onNearby = { [weak self] _ in self?.askAboutNewNetwork() }
        return scanner
    }()

    func refreshNetworkPaths() {
        guard let node else { return }
        networkPaths = node.networkPaths()
        knownNetworks = (try? node.knownNetworks()) ?? []
        askAboutNewNetwork()
    }

    /// The Mac is on a network Brêge does not know and a phone is not connected. The menu always
    /// shows the question; a notification only when that phone is nearby (its Bluetooth presence),
    /// since otherwise it could not connect here anyway. Once per network per run.
    private func askAboutNewNetwork() {
        let disconnected = devices.filter { !$0.connected }
        let undecided = disconnected.isEmpty ? [] : networkPaths.filter { !$0.isVpn && !$0.trusted && !$0.declined }
        if let shown = shownNetworkQuestion, !undecided.contains(where: { $0.fingerprint == shown }) {
            presenter.removeNetworkQuestion()
            shownNetworkQuestion = nil
        }
        // Bluetooth scanning is only needed until the network has been asked about.
        guard let network = undecided.first(where: { !askedNetworks.contains($0.fingerprint) }) else {
            nearbyScanner.setScanning(false)
            return
        }
        nearbyScanner.setScanning(true)
        let nearby = disconnected.filter { nearbyScanner.isNearby($0.id) }
        guard !nearby.isEmpty else { return }
        askedNetworks.insert(network.fingerprint)
        nearbyScanner.setScanning(undecided.contains { !askedNetworks.contains($0.fingerprint) })
        // With Location access the question can name the Wi‑Fi network.
        hotspot.location.requestIfNeeded()
        presenter.showNetworkQuestion(fingerprint: network.fingerprint, label: network.label,
                                      phones: ListFormatter.localizedString(byJoining: nearby.map(\.name)))
        shownNetworkQuestion = network.fingerprint
    }

    /// The network the question notification is about, if one is shown.
    private var shownNetworkQuestion: String?

    /// The network question notification was clicked: ask in an alert.
    private func askNetworkQuestion(fingerprint: String, label: String) {
        let alert = NSAlert()
        alert.messageText = "Use Brêge on \(label)?"
        alert.informativeText = "Your phones cannot connect on a network Brêge does not know. Choose Use Here only for networks you trust."
        alert.addButton(withTitle: "Use Here")
        alert.addButton(withTitle: "Not Here")
        alert.addButton(withTitle: "Later")
        ModalAlert.show(alert) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn: self?.decideNetwork(fingerprint, use: true)
            case .alertSecondButtonReturn: self?.decideNetwork(fingerprint, use: false)
            default: break
            }
        }
    }

    func trustNetwork(_ fingerprint: String) {
        decideNetwork(fingerprint, use: true)
    }

    /// Use Brêge on a network or VPN from now on, or never ("Not Here").
    func decideNetwork(_ fingerprint: String, use: Bool) {
        do {
            if use {
                try node?.trustNetwork(fingerprint: fingerprint)
            } else {
                try node?.declineNetwork(fingerprint: fingerprint)
            }
        } catch {
            showError("Could not change the network setting", error)
        }
        if shownNetworkQuestion == fingerprint {
            presenter.removeNetworkQuestion()
            shownNetworkQuestion = nil
        }
        refreshNetworkPaths()
        restartBonjour()
    }

    func allowNetworkOnce(_ fingerprint: String) {
        node?.allowNetworkOnce(fingerprint: fingerprint)
        refreshNetworkPaths()
    }

    func forgetNetwork(_ fingerprint: String) {
        try? node?.forgetNetwork(fingerprint: fingerprint)
        refreshNetworkPaths()
        restartBonjour()
    }

    func openPhoneInFinder(_ device: Device) {
        guard let node, !openingDrives.contains(device.id) else { return }
        openingDrives.insert(device.id)
        Task {
            defer { openingDrives.remove(device.id) }
            do {
                try await drives.open(device: device, node: node)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Could not show \(device.name) in Finder"
                alert.informativeText = error.localizedDescription
                ModalAlert.show(alert)
            }
        }
    }

    // MARK: - Phone as microphone

    func toggleMicrophone(_ device: Device) {
        if micDevice == device.id {
            stopMicrophone()
            return
        }
        guard PhoneMicrophone.isDriverInstalled else {
            let alert = NSAlert()
            alert.messageText = "Install the Brêge Microphone?"
            alert.informativeText = "To use your phone as a microphone, Brêge adds a virtual audio device called “Brêge Microphone”. macOS asks for your administrator password once."
            alert.addButton(withTitle: "Install")
            alert.addButton(withTitle: "Cancel")
            ModalAlert.show(alert) { [weak self] response in
                guard let self, response == .alertFirstButtonReturn else { return }
                do {
                    try PhoneMicrophone.installDriver()
                } catch {
                    self.showError("Could not install the microphone", error)
                    return
                }
                self.startMicrophone(device)
            }
            return
        }
        startMicrophone(device)
    }

    private func startMicrophone(_ device: Device) {
        do {
            try microphone.start()
        } catch {
            // Core Audio may still be restarting right after installation.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self else { return }
                do { try self.microphone.start(); self.requestMic(device) } catch { self.showError("Could not start the microphone", error) }
            }
            return
        }
        requestMic(device)
    }

    // MARK: - Phone screen

    /// Launchable apps per phone; nil until the phone answered.
    @Published private(set) var phoneApps: [String: [PhoneApp]] = [:]

    func requestPhoneApps(deviceId: String, refresh: Bool) {
        guard refresh || phoneApps[deviceId] == nil else { return }
        if refresh { phoneApps[deviceId] = nil }
        try? node?.requestAppList(deviceId: deviceId)
    }

    func isValidPackage(_ package: String) -> Bool {
        node?.isValidPackageName(package: package) ?? false
    }

    // MARK: - Wireless debugging

    /// Wireless debugging stays on between sessions so the phone screen and the pointer start
    /// without a wait. Nothing needing adb for a while means it can go off again: the phone
    /// switches it back on by itself when the Mac next asks, over Brêge's own link.
    private static let adbIdleTimeout: TimeInterval = 300

    private var adbIdleWatch: Timer?
    private var adbIdleSince: Date?
    private var adbSwitchedOff = false

    private func checkAdbIdle() {
        guard AppSettings.shared.idleWirelessDebugging else { return }
        // Any screen, app or desktop window counts, not only the pointer: switching adb off under
        // a running session would cut it off mid-use.
        if ScreenSession.isUsingAdb || pointerSession != nil {
            adbIdleSince = nil
            adbSwitchedOff = false
            return
        }
        guard !adbSwitchedOff else { return }
        guard let since = adbIdleSince else { return adbIdleSince = Date() }
        guard Date().timeIntervalSince(since) >= Self.adbIdleTimeout else { return }
        switchOffWirelessDebugging()
        adbSwitchedOff = true
        adbIdleSince = nil
    }

    /// Asks every connected phone to switch wireless debugging off; one that has it off already
    /// does nothing. Only ever sent over a working link, which is also what switches it back on.
    private func switchOffWirelessDebugging() {
        for device in devices where device.connected {
            try? node?.sendCommand(deviceId: device.id, command: .disableWirelessDebugging)
        }
    }

    // MARK: - Phone pointer

    /// The phone currently holding this Mac's pointer and keyboard, if any.
    @Published private(set) var pointerDevice: String?
    /// True while the phone has the pointer, as opposed to only waiting at the edge.
    @Published private(set) var pointerCaptured = false

    private var pointerSession: PointerSession?
    private let pointerCapture = PointerCapture()

    /// Hands this Mac's pointer and keyboard to the phone, or gives them back.
    func togglePhonePointer(for device: Device) {
        if pointerDevice == device.id { return stopPhonePointer() }
        stopPhonePointer()
        guard macActions.canSendKeys else {
            showNotice("Brêge needs Accessibility access",
                       "Allow Brêge under Privacy & Security › Accessibility, then try again. "
                       + "Without it macOS does not let Brêge read the pointer and keys.")
            macActions.askForKeyControl()
            return
        }
        guard let adb = Adb.locate() else {
            showError("Could not reach the phone", Adb.Failure.notInstalled)
            return
        }
        guard let ip = phoneIP(deviceId: device.id) else {
            showNotice("The phone is not reachable", "Brêge needs the phone connected on this network.")
            return
        }
        let session = PointerSession(adb: adb, phoneIP: ip)
        session.switchOnWirelessDebugging = { [weak self] in
            DispatchQueue.main.sync { self?.switchOnWirelessDebugging(deviceId: device.id) ?? false }
        }
        session.onScreenSize = { [weak self] width, _ in
            Task { @MainActor in self?.pointerCapture.phoneWidth = width }
        }
        session.onReady = { [weak self, weak session] in
            Task { @MainActor in
                guard let self else { return }
                self.pointerCapture.send = { [weak session] report in session?.send(report) }
                self.pointerCapture.onCaptureChanged = { [weak self] capturing in
                    Task { @MainActor in self?.pointerCaptured = capturing }
                }
                self.pointerCapture.startWatchingEdge()
            }
        }
        session.onEnd = { [weak self] error in
            Task { @MainActor in
                guard let self, self.pointerDevice == device.id else { return }
                self.stopPhonePointer()
                if let error { self.showError("The phone pointer stopped", error) }
            }
        }
        pointerSession = session
        pointerDevice = device.id
        session.start()
    }

    func stopPhonePointer() {
        pointerCapture.endCapture()
        pointerCapture.stopWatchingEdge()
        pointerCapture.send = nil
        pointerSession?.stop()
        pointerSession = nil
        pointerDevice = nil
        pointerCaptured = false
    }

    /// Asks the phone to switch wireless debugging on (it can once the Mac granted it permission).
    func switchOnWirelessDebugging(deviceId: String) -> Bool {
        (try? node?.sendCommand(deviceId: deviceId, command: .enableWirelessDebugging)) != nil
    }

    /// The phone's current IP address while it is connected, for screen sharing.
    func phoneIP(deviceId: String) -> String? {
        node?.peerIp(deviceId: deviceId)
    }

    func uninstallMicrophone() {
        let alert = NSAlert()
        alert.messageText = "Remove the Brêge Microphone?"
        alert.informativeText = "The “Brêge Microphone” audio device is removed from this Mac. macOS asks for your administrator password. You can install it again with the Mic button."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        ModalAlert.show(alert) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            self.stopMicrophone()
            do {
                try PhoneMicrophone.uninstallDriver()
            } catch {
                self.showError("Could not remove the microphone", error)
            }
            self.objectWillChange.send()
        }
    }

    private func requestMic(_ device: Device) {
        // One phone at a time: the one used before stops recording.
        if let previous = micDevice, previous != device.id {
            try? node?.sendCommand(deviceId: previous, command: .micStop)
        }
        micDevice = device.id
        micStatus = "Starting on \(device.name)…"
        try? node?.sendCommand(deviceId: device.id, command: .micStart)
    }

    func stopMicrophone() {
        if let id = micDevice { try? node?.sendCommand(deviceId: id, command: .micStop) }
        microphone.stop()
        micDevice = nil
        micStatus = nil
    }

    private func showNotice(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        ModalAlert.show(alert)
    }

    private func showError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        ModalAlert.show(alert)
    }

    func stopSync() {
        if AppSettings.shared.idleWirelessDebugging, !ScreenSession.isUsingAdb, pointerSession == nil {
            switchOffWirelessDebugging()
        }
        stopMicrophone()
        drives.ejectAll(node: node)
        clipboard.stop()
        bonjour?.stop()
        ble.stop()
    }

    func refresh() {
        guard !Screenshots.isActive else { return } // made-up data only
        presenter.checkBlocked { [weak self] blocked in self?.notificationsBlocked = blocked }
        defer { syncMessageModels() }
        // The user may have just allowed Local Network access: re-register to find out.
        if localNetworkDenied { restartBonjour(force: true) }
        guard let node else { return }
        let paired = (try? node.devices()) ?? []
        if !servicesWritten || paired.map(\.id) != devices.map(\.id) || paired.map(\.name) != devices.map(\.name) {
            ServicesMenu.update(devices: paired)
            servicesWritten = true
        }
        devices = paired
        foldExtraPhones()
        // New or forgotten phones change the Bonjour ids.
        restartBonjour()
        refreshNetworkPaths()
        notifications = (try? node.recentNotifications(limit: 50)) ?? []
    }

    // MARK: - Pairing

    /// The window is found by SwiftUI's identifier, which starts with the scene id. `keyWindow`
    /// cannot be used: a menu-bar app is usually not active when the phone finishes pairing.
    static func closePairingWindow() {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix("pairing") == true }?.close()
    }

    /// The pairing window opened before the node started (restored at launch).
    private var pairingWanted = false

    func beginPairing() {
        justPaired = nil
        guard let node else {
            pairingWanted = true
            return
        }
        pairingWanted = false
        let addresses = LocalAddresses.ipv4().map { "\($0):\(node.listenPort())" }
        inviteURI = try? node.createPairingInvite(addresses: addresses)
        restartBonjour() // pairing may announce where Brêge otherwise does not
    }

    func endPairing() {
        pairingWanted = false
        node?.cancelPairing()
        inviteURI = nil
        restartBonjour()
    }

    func answerPairing(accept: Bool) {
        guard let request = pairingRequest else { return }
        node?.respondToPairing(requestId: request.id, accept: accept)
        pairingRequest = nil
    }

    /// Asks the user with a standalone alert, so it appears even if the QR window was closed
    /// or is behind other windows (a menu-bar app is never frontmost on its own).
    private func confirmPairing(_ request: PairingRequest) {
        pairingRequest = request
        let alert = NSAlert()
        alert.messageText = "Pair with “\(request.name)”?"
        alert.informativeText = "This phone scanned your pairing code. Only continue if it is your phone.\n\nPhone ID: \(request.deviceId.prefix(8))"
        alert.addButton(withTitle: "Pair")
        alert.addButton(withTitle: "Don’t Pair")
        alert.window.level = .floating
        ModalAlert.show(alert) { [weak self] response in
            // Answered by id: a newer request may have replaced this one while the alert was open.
            guard let self else { return }
            self.node?.respondToPairing(requestId: request.id, accept: response == .alertFirstButtonReturn)
            if self.pairingRequest == request { self.pairingRequest = nil }
        }
    }

    func forget(_ device: Device) {
        stopPhoneRequests(deviceId: device.id)
        Task {
            try? await node?.forgetDevice(deviceId: device.id)
            refresh()
        }
    }

    // MARK: - Messages and calls

    func messages(for deviceId: String) -> MessagesModel {
        if let model = messageModels[deviceId] { return model }
        let model = MessagesModel(deviceId: deviceId)
        messageModels[deviceId] = model
        return model
    }

    func camera(for deviceId: String) -> PhoneCameraModel {
        if let model = cameras[deviceId] { return model }
        let model = PhoneCameraModel(deviceId: deviceId, router: videoRouter, node: { [weak self] in self?.node }, presenter: presenter)
        cameras[deviceId] = model
        return model
    }

    func calls(for deviceId: String) -> CallsModel {
        if let model = callModels[deviceId] { return model }
        let model = CallsModel(deviceId: deviceId)
        callModels[deviceId] = model
        return model
    }

    /// The phone's SIMs, for the keypad and the calls list.
    func sims(for deviceId: String) -> [SimData] {
        (try? node?.sims(deviceId: deviceId)) ?? []
    }

    func openCalls(deviceId: String) {
        used(deviceId)
        let model = calls(for: deviceId)
        model.attach(node: node)
        model.reload()
        model.refreshFromPhone()
        openWindowAction?(id: "calls", value: deviceId)
        NSApp.activate(ignoringOtherApps: true)
    }

    func callsWindowOpened(deviceId: String) {
        guard !Screenshots.isActive else { return } // made-up data only
        let model = calls(for: deviceId)
        model.attach(node: node)
        model.reload()
        model.refreshFromPhone()
        missedCalls[deviceId] = 0
    }

    func photos(for deviceId: String) -> PhotosModel {
        if let model = photoModels[deviceId] { return model }
        let model = PhotosModel(deviceId: deviceId, capture: capture) { [weak self] in self?.node }
        photoModels[deviceId] = model
        return model
    }

    func conditions(for deviceId: String) -> ConditionsModel {
        if let model = conditionsModels[deviceId] { return model }
        let model = ConditionsModel(deviceId: deviceId) { [weak self] in self?.node }
        conditionsModels[deviceId] = model
        return model
    }

    func openConditions(deviceId: String) {
        used(deviceId)
        openWindowAction?(id: "conditions", value: deviceId)
        NSApp.activate(ignoringOtherApps: true)
    }

    func appInventory(for deviceId: String) -> AppInventoryModel {
        if let model = appInventoryModels[deviceId] { return model }
        let model = AppInventoryModel(deviceId: deviceId) { [weak self] in self?.node }
        appInventoryModels[deviceId] = model
        return model
    }

    func openAppInventory(deviceId: String) {
        used(deviceId)
        openWindowAction?(id: "installed-apps", value: deviceId)
        NSApp.activate(ignoringOtherApps: true)
    }

    func appsWindowOpened(deviceId: String) {
        guard !Screenshots.isActive else { return } // made-up data only
        appInventory(for: deviceId).refresh(device(deviceId))
    }

    func openNotificationHistory() {
        openWindowAction?(id: "notification-history", value: "")
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Cached phone notifications, filtered by `query` (empty shows the newest).
    func notificationHistory(matching query: String) -> [StoredNotification] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard let node else { return [] }
        if trimmed.isEmpty { return (try? node.recentNotifications(limit: 200)) ?? [] }
        return (try? node.searchNotifications(query: trimmed, limit: 200)) ?? []
    }

    func openPhotos(deviceId: String) {
        used(deviceId)
        openWindowAction?(id: "photos", value: deviceId)
        NSApp.activate(ignoringOtherApps: true)
    }

    func photosWindowOpened(deviceId: String) {
        guard !Screenshots.isActive else { return } // made-up data only
        photos(for: deviceId).start(device(deviceId))
    }

    func recentPhotos(for deviceId: String) -> RecentPhotosModel {
        if let model = recentPhotoModels[deviceId] { return model }
        let model = RecentPhotosModel(capture: capture) { [weak self] in self?.node }
        recentPhotoModels[deviceId] = model
        return model
    }

    private func syncMessageModels() {
        guard node != nil else { return }
        var unread: [String: Int] = [:]
        for device in devices {
            let model = messages(for: device.id)
            model.attach(node: node)
            unread[device.id] = model.unreadCount
        }
        messageModels = messageModels.filter { id, _ in unread[id] != nil }
        if unread != unreadMessages { unreadMessages = unread }
    }

    /// Set by a view: SwiftUI windows can only be opened through the environment.
    var openWindowAction: OpenWindowAction?

    func openMessages(deviceId: String, composingTo number: String? = nil) {
        used(deviceId)
        let model = messages(for: deviceId)
        model.attach(node: node)
        model.reloadThreads()
        openWindowAction?(id: "messages", value: deviceId)
        NSApp.activate(ignoringOtherApps: true)
        if let number {
            // Let the window appear before the sheet opens.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { model.compose(to: number) }
        }
    }

    func messagesWindowOpened(deviceId: String) {
        guard !Screenshots.isActive else { return } // made-up data only
        let model = messages(for: deviceId)
        model.attach(node: node)
        model.reloadThreads()
        unreadMessages[deviceId] = model.unreadCount
    }

    func dial(number: String, subId: Int32 = -1, deviceId: String) {
        do {
            try node?.callAction(deviceId: deviceId, action: .dial, number: number, subId: subId)
        } catch {
            presenter.showInfo(title: "Could not start the call", body: "\(error)")
        }
    }

    func callAction(_ action: CallActionKind, deviceId: String? = nil) {
        guard let deviceId = deviceId ?? activeCall?.deviceId ?? devices.first(where: \.connected)?.id else { return }
        try? node?.callAction(deviceId: deviceId, action: action, number: "", subId: -1)
    }

    private func handleCall(_ call: CallData, from deviceId: String) {
        let previous = calls[deviceId]
        calls[deviceId] = call.status == .ended ? nil : call
        // Music stays paused while any phone is ringing or on a call.
        if calls.isEmpty { callAudio.callEnded() } else { callAudio.callStarted() }
        switch call.status {
        case .ended:
            presenter.removeCall(deviceId: deviceId)
            guard activeCall == nil || activeCall?.deviceId == deviceId else { return }
            activeCall = nil
            callPanel.show(call: call, model: self)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.activeCall == nil else { return }
                self.showNextCallOrClose()
            }
        default:
            let wasRinging = previous?.callId == call.callId && previous?.status == .ringing
            // The panel stays with the phone it shows; a phone that starts ringing takes it over.
            if activeCall == nil || activeCall?.deviceId == deviceId || call.status == .ringing {
                activeCall = (deviceId, call)
                callPanel.show(call: call, model: self)
            }
            if call.status == .ringing && call.incoming {
                presenter.showIncomingCall(call, deviceId: deviceId, phoneName: deviceName(deviceId),
                                           photo: messageModels[deviceId]?.photo(forNumber: call.number))
            } else if wasRinging {
                presenter.removeCall(deviceId: deviceId)
            }
        }
    }

    /// A phone that disconnects cannot report the end of its call.
    private func endCalls(deviceId: String) {
        guard calls.removeValue(forKey: deviceId) != nil else { return }
        presenter.removeCall(deviceId: deviceId)
        if calls.isEmpty { callAudio.callEnded() }
        if activeCall?.deviceId == deviceId {
            activeCall = nil
            showNextCallOrClose()
        }
    }

    private func showNextCallOrClose() {
        if let (deviceId, call) = calls.first {
            activeCall = (deviceId, call)
            callPanel.show(call: call, model: self)
        } else {
            callPanel.close()
        }
    }

    // MARK: - Actions

    /// Changes a control on the phone (torch, sound, Do Not Disturb, buzz, clear notifications).
    func phoneControl(_ device: Device, _ kind: ControlKind, value: Int32, stream: VolumeStream? = nil) {
        used(device.id)
        do {
            try node?.sendPhoneControl(deviceId: device.id, kind: kind, value: value, stream: stream)
        } catch {
            presenter.showInfo(title: "Could not change that on the phone", body: "\(error)")
        }
    }

    /// Battery percentage the phone last reported, for the controls panel.
    func batteryPercent(_ deviceId: String) -> Int? {
        statuses[deviceId].map { Int($0.batteryPct) }
    }

    /// Which phone's controls are open in the menu.
    @Published var controlsOpenFor: String?
    /// The Conditions card is folded away until it is asked for, like the controls.
    @Published var conditionsOpenFor: String?

    func toggleConditions(_ device: Device) {
        if conditionsOpenFor == device.id {
            conditionsOpenFor = nil
            return
        }
        conditionsOpenFor = device.id
        used(device.id)
        conditions(for: device.id).refresh(device)
    }

    /// The controls panel opened: ask the phone for fresh state (it answers with a control update).
    func toggleControls(_ device: Device) {
        if controlsOpenFor == device.id {
            controlsOpenFor = nil
            return
        }
        controlsOpenFor = device.id
        controlsOpened(device)
    }

    func controlsOpened(_ device: Device) {
        used(device.id)
        // A vibrate of 0 ms is refused by the core, so ask with a harmless torch state request:
        // the phone publishes its state after every control, and on connect.
        try? node?.sendPhoneControl(deviceId: device.id, kind: .torch,
                                    value: phoneControls[device.id]?.torchOn == true ? 1 : 0, stream: nil)
    }

    func stopRing(_ device: Device) {
        try? node?.sendCommand(deviceId: device.id, command: .stopRing)
    }

    func ring(_ device: Device) {
        try? node?.sendCommand(deviceId: device.id, command: .ring)
    }

    func mediaCommand(_ device: Device, _ command: CommandKind) {
        try? node?.sendCommand(deviceId: device.id, command: command)
    }

    func sendFiles(to device: Device) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        ModalAlert.run { [weak self] in
            guard panel.runModal() == .OK else { return }
            for url in panel.urls {
                self?.send(file: url, to: device)
            }
        }
    }

    func send(file url: URL, to device: Device) {
        Task {
            do {
                let id = try await node?.sendFile(deviceId: device.id, path: url.path) ?? ""
                transferNames[id] = url.lastPathComponent
                upsertTransfer(id: id) { $0.name = url.lastPathComponent }
            } catch {
                presenter.showInfo(title: "Could not send \(url.lastPathComponent)", body: "\(error)")
            }
        }
    }

    private lazy var browserTab = BrowserTab()

    /// Opens the page from the browser you were just using (or a copied link) on the phone.
    func sendTab(to device: Device) {
        switch browserTab.currentTab() {
        case let .success(tab):
            do {
                try node?.sendUrl(deviceId: device.id, url: tab.url, title: tab.title)
                presenter.showInfo(title: "Opened on \(device.name)", body: tab.title.isEmpty ? tab.url : tab.title)
            } catch {
                presenter.showInfo(title: "Could not send the tab", body: error.localizedDescription)
            }
        case .failure(.noTab):
            presenter.showInfo(title: "No tab to send",
                               body: "Open a page in Safari, Chrome, Edge, Brave or Arc, or copy a link. In Firefox, use Send Tab to Device.")
        case let .failure(.notAllowed(browser)):
            presenter.showInfo(title: "Allow Brêge to read \(browser)'s tab",
                               body: "System Settings › Privacy & Security › Automation › Brêge › \(browser).")
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
        }
    }

    func act(deviceId: String, key: String, act: NotificationActKind) {
        try? node?.actOnNotification(deviceId: deviceId, key: key, act: act)
    }

    // MARK: - Events from the core

    fileprivate func handle(_ event: BregeEvent) {
        switch event {
        case let .pairingRequested(requestId, deviceId, name, _):
            confirmPairing(PairingRequest(id: requestId, deviceId: deviceId, name: name))
        case .pairingWaitingForConfirmation:
            break // Phone-side event.
        case let .devicePaired(device):
            inviteURI = nil
            justPaired = device.name
            refresh()
            // Close the pairing window shortly after showing the confirmation.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                Self.closePairingWindow()
                self?.justPaired = nil
                self?.restartBonjour()
            }
        case let .peerDisconnected(deviceId):
            clearLiveState(deviceId: deviceId)
            // Its captures can no longer arrive.
            capture.phoneDisconnected(deviceId)
            recentPhotoModels[deviceId]?.clear()
            refresh()
        case let .deviceForgotten(deviceId):
            // A forgotten phone may not report a disconnect first.
            clearLiveState(deviceId: deviceId)
            stopPhoneRequests(deviceId: deviceId)
            cameras[deviceId]?.close()
            cameras[deviceId] = nil
            recentPhotoModels[deviceId] = nil
            refresh()
        case .networkPathsChanged:
            refreshNetworkPaths()
            restartBonjour()
        case let .macActionRequested(_, kind, value):
            macActions.perform(kind, value: value)
            publishMacState()
        case let .macStateChanged(from, state):
            // Only a Mac acts on these; a phone would, but this is the Mac.
            _ = (from, state)
        case .watchSettingsChanged, .macAlertReceived:
            break // the phone acts on these, not the Mac
        case let .peerConnected(deviceId, _):
            refresh()
            // The watch shows this Mac's volume and battery, so a fresh state goes out at once.
            publishMacState()
            publishWatchSettings()
            messageModels[deviceId]?.resetPhotoRequests()
            // Recent calls, so the list and the missed badge are current without opening the window.
            let callsModel = calls(for: deviceId)
            callsModel.attach(node: node)
            callsModel.refreshFromPhone()
        case let .ongoingActivityUpdated(from, activity):
            live.updated(activity, from: from)
        case let .ongoingActivityEnded(from, key):
            live.ended(key: key, from: from)
        case let .appListReceived(from, apps):
            phoneApps[from] = apps.map { PhoneApp(package: $0.package, label: $0.label, icon: NSImage(data: $0.iconPng)) }
        case let .contactPhotosReceived(from, photos):
            messageModels[from]?.onContactPhotos(photos)
        case let .clipboardReceived(_, clip):
            clipboard.write(clip)
        case let .notificationPosted(from, notification):
            presenter.show(notification, from: from)
            refresh()
        case let .notificationRemoved(from, key):
            presenter.remove(key: key, from: from)
            refresh()
        case .notificationAction:
            break // Phone-side event.
        case let .statusUpdated(from, status):
            statuses[from] = status
            if let device = devices.first(where: { $0.id == from }) { batteryAlerts.update(status, device: device) }
        case let .cameraStateChanged(from, state):
            cameras[from]?.stateChanged(state)
        case let .recentMediaReceived(from, items, newScreenshot, permissionNeeded):
            if let device = device(from) {
                recentPhotos(for: from).received(items, newScreenshot: newScreenshot, permissionNeeded: permissionNeeded,
                                                 from: device)
            }
        case let .mediaUpdated(from, m):
            media[from] = m
            mediaControls.update(m, from: from)
        case let .openRequestReceived(from, request):
            lastOpenRequest = request
            presenter.showOpenRequest(request, from: deviceName(from))
        case let .commandReceived(_, command):
            if command == .ring { NSSound(named: "Glass")?.play() }
        case let .transferOffered(_, id, name, size):
            transferNames[id] = name
            upsertTransfer(id: id) { $0.name = name; $0.total = size; $0.incoming = true }
        case let .transferProgress(_, id, bytes, total, incoming):
            upsertTransfer(id: id) { $0.bytes = bytes; $0.total = total; $0.incoming = incoming }
        case let .transferCompleted(from, id, path, incoming):
            upsertTransfer(id: id) { $0.done = true; $0.bytes = $0.total }
            if incoming, !capture.transferCompleted(id: id, path: path, from: from) {
                presenter.showFileReceived(path: path)
                alertWatch("File arrived", (path as NSString).lastPathComponent)
            }
        case let .transferFailed(_, id, reason, _):
            upsertTransfer(id: id) { $0.failed = reason }
            capture.transferFailed(id: id, reason: reason)
        case let .captureResultReceived(_, requestId, status, transferId, detail):
            capture.resultReceived(requestId: requestId, status: status, transferId: transferId, detail: detail)
        case let .messagesUpdated(from, threadIds, _):
            if let model = messageModels[from] {
                model.onMessagesUpdated(threadIds: threadIds)
                unreadMessages[from] = model.unreadCount
            }
        case let .messageSendStatus(_, clientId, status, error):
            messageModels.values.forEach { $0.onSendStatus(clientId: clientId, status: status, error: error) }
        case let .simsUpdated(from, _):
            messageModels[from]?.reloadThreads()
        case let .callStateChanged(from, call):
            handleCall(call, from: from)
        case let .appInventoryReceived(from, apps, usageAccess):
            appInventoryModels[from]?.received(apps, usageAccess: usageAccess)
        case let .notificationSettingsReceived(from, settings):
            appInventoryModels[from]?.settingsReceived(settings)
        case let .mediaLibraryPage(from, items, end, album, permissionNeeded, partialAccess):
            photoModels[from]?.pageReceived(items: items, end: end, album: album,
                                            permissionNeeded: permissionNeeded, partialAccess: partialAccess)
        case let .mediaAlbumsReceived(from, albums):
            photoModels[from]?.albumsReceived(albums)
        case let .phoneControlsChanged(from, state):
            phoneControls[from] = state
        case .conditionsRequested:
            break // phone side only
        case let .conditionsChanged(from, conditions):
            self.conditions(for: from).received(conditions)
            ConditionsAutomation.apply(conditions, presenter: presenter)
        case let .callLogUpdated(from, newMissed):
            callModels[from]?.reload()
            if newMissed > 0 { missedCalls[from, default: 0] += Int(newMissed) }
        case let .micStateChanged(from, active, _, detail):
            if active, micDevice == nil {
                // Started from the phone app. Without the driver or a working feed this Mac cannot
                // play it, but the phone is left alone: another Mac may have started it.
                guard PhoneMicrophone.isDriverInstalled else {
                    // Say why nothing happens, but leave the phone alone: another Mac may use it.
                    presenter.showInfo(title: "Install the Brêge Microphone first",
                                       body: "Click Microphone on the phone in the Brêge menu once to install it.")
                    break
                }
                guard (try? microphone.start()) != nil else { break }
                micDevice = from
            }
            // Another phone is this Mac's microphone: one starting from its app is not stopped.
            guard from == micDevice else { break }
            if active {
                micStatus = "Microphone on — choose “Brêge Microphone” in your app"
            } else if detail.isEmpty {
                microphone.stop()
                micDevice = nil
                micStatus = nil
            } else {
                micStatus = detail
            }
        case .messageSyncRequested, .messageHistoryRequested, .messageSendRequested, .callActionRequested,
             .callLogRequested, .phoneControlRequested, .mediaLibraryRequested, .mediaAlbumsRequested,
             .appInventoryRequested, .appActionRequested, .notificationSettingsRequested,
             .notificationChannelUpdateRequested,
             .contactPhotosRequested, .appListRequested, .captureRequested, .recentMediaRequested, .mediaFetchRequested,
             .cameraRequested:
            break // Phone-side events.
        }
    }

    /// A hotspot request and captures for a phone that is being forgotten.
    private func stopPhoneRequests(deviceId: String) {
        if hotspot.isRequesting(for: deviceId) { hotspot.cancel() }
        capture.cancel(deviceId: deviceId)
    }

    /// What only exists while a phone is connected: media, ongoing activities, calls, microphone, drive.
    private func clearLiveState(deviceId: String) {
        mediaControls.clear(deviceId: deviceId)
        live.clear(deviceId: deviceId)
        endCalls(deviceId: deviceId)
        if micDevice == deviceId { stopMicrophone() }
        drives.eject(deviceId: deviceId, node: node)
        media[deviceId] = nil
    }

    private func deviceName(_ id: String) -> String {
        devices.first { $0.id == id }?.name ?? "phone"
    }

    private func upsertTransfer(id: String, _ update: (inout Transfer) -> Void) {
        if let index = transfers.firstIndex(where: { $0.id == id }) {
            update(&transfers[index])
        } else {
            var t = Transfer(id: id, name: transferNames[id] ?? "file", bytes: 0, total: 0,
                             incoming: false, done: false, failed: nil)
            update(&t)
            transfers.insert(t, at: 0)
            if transfers.count > 20 { transfers.removeLast() }
        }
    }
}

/// Bridges core callbacks (on a core thread) to the main actor.
private final class Listener: EventListener, @unchecked Sendable {
    weak var model: AppModel?

    init(model: AppModel) {
        self.model = model
    }

    func onEvent(event: BregeEvent) {
        Task { @MainActor [weak model] in
            model?.handle(event)
        }
    }
}

// MARK: - Screenshots

extension AppModel {
    /// Made-up phones for the README screenshots (`Screenshots`); never called otherwise.
    func loadScreenshotData(devices: [Device], statuses: [String: StatusData], media: [String: MediaData],
                            unread: [String: Int], transfers: [Transfer], networkPaths: [NetworkPathData],
                            knownNetworks: [KnownNetworkData], phoneApps: [String: [PhoneApp]]) {
        self.devices = devices
        self.statuses = statuses
        self.media = media
        unreadMessages = unread
        self.transfers = transfers
        self.networkPaths = networkPaths
        self.knownNetworks = knownNetworks
        self.phoneApps = phoneApps
        notificationsBlocked = false
        localNetworkDenied = false
    }
}
