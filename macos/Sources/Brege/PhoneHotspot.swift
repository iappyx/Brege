import AppKit
import BregeCore
import CoreBluetooth
import CoreLocation
import CoreWLAN
import Network
import os

/// Phone hotspot for the Mac. Android does not let apps turn
/// the hotspot on, so the Mac asks over Bluetooth LE (it has no network to the phone) and the
/// phone shows a notification; the user switches the hotspot on and the Mac joins the network it
/// already knows.
@MainActor
final class PhoneHotspot: ObservableObject {
    /// "Turn on the hotspot on Pixel…" while a request runs.
    @Published private(set) var status: String?
    /// Wi‑Fi networks this Mac remembers, for choosing the phone's hotspot.
    @Published private(set) var knownNetworks: [String] = []

    private let log = Logger(subsystem: "app.brege.mac", category: "hotspot")
    private let advertiser: PresenceAdvertiser
    private let presenter: NotificationPresenter
    private let node: () -> BregeNode?
    private var request: (device: Device, ssid: String, started: Date, ticks: Int)?
    private var timer: Timer?
    private let pathMonitor = NWPathMonitor()
    private var offlineSince: Date?
    private var offeredThisOutage = false

    /// macOS only reveals the Wi‑Fi network's name to apps with Location access.
    let location = LocationAccess()

    /// Who to offer the hotspot of when the Mac goes offline.
    var offerDevice: (() -> Device?)?
    /// Called when the hotspot network starts or stops being usable (Bonjour follows it).
    var onPendingChanged: (() -> Void)?
    /// Counts requests, so a grace period only ends the request it belongs to.
    private var generation = 0

    init(advertiser: PresenceAdvertiser, presenter: NotificationPresenter, node: @escaping () -> BregeNode?) {
        self.advertiser = advertiser
        self.presenter = presenter
        self.node = node
    }

    // MARK: Settings

    func ssid(for deviceId: String) -> String? {
        UserDefaults.standard.string(forKey: "hotspotSSID.\(deviceId)")
    }

    func setSSID(_ ssid: String?, for deviceId: String) {
        if ssid != nil { location.requestIfNeeded() }
        UserDefaults.standard.set(ssid, forKey: "hotspotSSID.\(deviceId)")
        objectWillChange.send()
    }

    func refreshKnownNetworks() {
        guard !Screenshots.isActive else { return } // made-up data only
        Task.detached {
            let networks = Self.preferredNetworks()
            await MainActor.run { self.knownNetworks = networks }
        }
    }

    // MARK: Request

    var isRequesting: Bool { request != nil }

    func isRequesting(for deviceId: String) -> Bool { request?.device.id == deviceId }

    func connect(_ device: Device) {
        guard let ssid = ssid(for: device.id) else {
            presenter.showInfo(title: "Choose the phone's hotspot first",
                               body: "In Brêge, open the phone's … menu › Phone Hotspot and pick its network.")
            return
        }
        cancel()
        location.requestIfNeeded()
        generation += 1
        request = (device, ssid, Date(), 0)
        // The hotspot is a new network: let Brêge announce and answer on it while asking.
        node()?.setHotspotPending(deviceId: device.id, ssid: ssid, pending: true)
        onPendingChanged?()
        status = "Turn on the hotspot on \(device.name)…"
        advertiseRequest()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    /// `joined`: the Mac is on the hotspot; the phone still needs a moment to connect over it,
    /// after which the network is remembered.
    func cancel(joined: Bool = false) {
        if let current = request {
            let (device, ssid) = (current.device, current.ssid)
            if joined {
                let token = generation
                DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
                    guard let self, self.generation == token, self.request == nil else { return }
                    self.node()?.setHotspotPending(deviceId: device.id, ssid: ssid, pending: false)
                    self.onPendingChanged?()
                }
            } else {
                node()?.setHotspotPending(deviceId: device.id, ssid: ssid, pending: false)
            }
        }
        timer?.invalidate()
        timer = nil
        let wasRequesting = request != nil
        request = nil
        status = nil
        advertiser.setHotspotRequest(nil)
        if wasRequesting { onPendingChanged?() }
    }

    private func advertiseRequest() {
        guard let request else { return }
        guard let uuid = try? node()?.hotspotRequestUuid(deviceId: request.device.id) else {
            log.error("no hotspot request id for the phone")
            return
        }
        if request.ticks == 0 { log.notice("advertising hotspot request \(uuid.prefix(8), privacy: .public)") }
        advertiser.setHotspotRequest(CBUUID(string: uuid)) // rotates every 15 minutes
    }

    private func tick() {
        guard var current = request else { return }
        current.ticks += 1
        request = current
        let (ssid, name) = (current.ssid, current.device.name)
        if Date().timeIntervalSince(current.started) > 180 {
            cancel()
            presenter.showInfo(title: "\(name)'s hotspot did not appear", body: "Check that the hotspot is on, then try again.")
            return
        }
        advertiseRequest()
        let tryJoin = current.ticks % 3 == 0
        let phoneIP = node()?.peerIp(deviceId: current.device.id)
        let canReadName = location.isAllowed
        Task.detached {
            let router = Self.wifiRouter()
            // With Location access the network's name is known. Without it macOS hides the name,
            // and joining counts once the phone itself is the Wi‑Fi router.
            let ssidNow = canReadName ? Self.wifiSSID() : Self.currentSSID()
            let joined = ssidNow == ssid || (router != nil && router == phoneIP)
            // Joining again while on some network would interrupt it; join only when not on one.
            if !joined, tryJoin, router == nil || ssidNow != nil { Self.join(ssid) }
            await MainActor.run {
                guard joined, self.request?.ssid == ssid else { return }
                self.cancel(joined: true)
                self.presenter.showInfo(title: "Connected to \(name)'s hotspot", body: ssid)
            }
        }
    }

    // MARK: Offer when offline

    func startMonitoring() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.pathChanged(online: path.status == .satisfied) }
        }
        pathMonitor.start(queue: .main)
    }

    private func pathChanged(online: Bool) {
        if online {
            offlineSince = nil
            offeredThisOutage = false
            return
        }
        guard offlineSince == nil else { return }
        let since = Date()
        offlineSince = since
        // Short drops (switching networks, waking up) are not worth a notification.
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.offlineSince == since, !self.offeredThisOutage, !self.isRequesting,
                  let device = self.offerDevice?(), self.ssid(for: device.id) != nil else { return }
            self.offeredThisOutage = true
            self.presenter.showHotspotOffer(deviceId: device.id, phoneName: device.name)
        }
    }

    // MARK: System tools (no Location permission needed)

    nonisolated private static func wifiInterface() -> String {
        let ports = shell("/usr/sbin/networksetup", ["-listallhardwareports"])
        let lines = ports.components(separatedBy: "\n")
        for (i, line) in lines.enumerated() where line.hasSuffix(": Wi-Fi") && i + 1 < lines.count {
            return lines[i + 1].replacingOccurrences(of: "Device: ", with: "").trimmingCharacters(in: .whitespaces)
        }
        return "en0"
    }

    nonisolated private static func preferredNetworks() -> [String] {
        shell("/usr/sbin/networksetup", ["-listpreferredwirelessnetworks", wifiInterface()])
            .components(separatedBy: "\n")
            .dropFirst() // "Preferred networks on en0:"
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// The Wi‑Fi network's name through CoreWLAN, which needs Location access.
    nonisolated private static func wifiSSID() -> String? {
        CWWiFiClient.shared().interface()?.ssid() ?? currentSSID()
    }

    /// The Wi‑Fi network's name, or nil when unknown or hidden by macOS ("<redacted>").
    nonisolated private static func currentSSID() -> String? {
        shell("/usr/sbin/ipconfig", ["getsummary", wifiInterface()])
            .components(separatedBy: "\n")
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("SSID : ") }
            .map { $0.trimmingCharacters(in: .whitespaces).dropFirst("SSID : ".count) }
            .map(String.init)
            .flatMap { $0 == "<redacted>" ? nil : $0 }
    }

    /// The router address of the Wi‑Fi network the Mac is on, if any. On a phone hotspot this is
    /// the phone.
    nonisolated private static func wifiRouter() -> String? {
        let router = shell("/usr/sbin/ipconfig", ["getoption", wifiInterface(), "router"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return router.isEmpty ? nil : router
    }

    /// Joins a remembered network; the password comes from the system keychain.
    nonisolated private static func join(_ ssid: String) {
        _ = shell("/usr/sbin/networksetup", ["-setairportnetwork", wifiInterface(), ssid])
    }

    nonisolated private static func shell(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Location access, which macOS requires before it tells an app the Wi‑Fi network's name.
@MainActor
final class LocationAccess: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var status: CLAuthorizationStatus
    private let manager = CLLocationManager()

    override init() {
        status = manager.authorizationStatus
        super.init()
        manager.delegate = self
    }

    var isAllowed: Bool { status == .authorizedAlways }
    var isDenied: Bool { status == .denied || status == .restricted }

    /// Shows macOS's prompt once; after a denial only System Settings can change it.
    func requestIfNeeded() {
        if status == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    static func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
    }

    /// Called when access changes, e.g. to read Wi‑Fi names again.
    var onChange: (() -> Void)?

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard self.status != status else { return }
            self.status = status
            self.onChange?()
        }
    }
}
