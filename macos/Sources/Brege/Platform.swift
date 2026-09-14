import AppKit
import BregeCore
import CoreBluetooth
import CoreWLAN
import os
import CoreImage.CIFilterBuiltins
import Network
import dnssd

// MARK: - Clipboard

/// Polls the pasteboard (macOS has no change notification) and writes clips from the phone.
final class ClipboardMonitor {
    var onChange: ((ClipData, UInt64) -> Void)?
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount

    private static let concealedTypes: [NSPasteboard.PasteboardType] = [
        .init("org.nspasteboard.ConcealedType"),
        .init("org.nspasteboard.TransientType"),
    ]
    private static let maxBytes = 10 * 1024 * 1024
    /// Marks clipboard contents Brêge wrote itself (codes, captures, screenshots, text from a
    /// phone), which are not sent on to the phones.
    static let ownWriteType = NSPasteboard.PasteboardType("app.brege.own-write")

    /// Call after writing to the general pasteboard.
    static func markOwnWrite(_ pasteboard: NSPasteboard = .general) {
        pasteboard.addTypes([ownWriteType], owner: nil)
        pasteboard.setData(Data(), forType: ownWriteType)
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.poll()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        let types = pasteboard.types ?? []
        if types.contains(where: Self.concealedTypes.contains) || types.contains(Self.ownWriteType) { return }

        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            onChange?(.text(text: text), UInt64(lastChangeCount))
        } else if let image = NSImage(pasteboard: pasteboard), let png = image.pngData(), png.count <= Self.maxBytes {
            onChange?(.png(data: png), UInt64(lastChangeCount))
        }
    }

    func write(_ clip: ClipData) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch clip {
        case let .text(text): pasteboard.setString(text, forType: .string)
        case let .png(data): pasteboard.setData(data, forType: .png)
        }
        // The core suppresses the echo by content, but skipping the poll is cheaper.
        lastChangeCount = pasteboard.changeCount
    }
}

private extension NSImage {
    func pngData() -> Data? {
        guard let tiff = tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}

// MARK: - Discovery

/// Registers `_brege._udp` for the port the Rust endpoint listens on, only on trusted networks
/// (network privacy plan). The service is named "Brêge", not after the Mac, the TXT record carries
/// only the paired phones' rotating keyed ids, and the SRV target is a random host name per
/// interface (a new one for every advertiser, i.e. whenever the ids or networks change) instead
/// of the Mac's own, stable host name.
final class BonjourAdvertiser {
    /// Called on the main queue with `true` when macOS denies Local Network access to Brêge,
    /// and `false` once registration succeeds.
    var onLocalNetworkDenied: ((Bool) -> Void)?

    private let port: UInt16
    let tokens: String
    let interfaces: [String]
    private var refs: [DNSServiceRef] = []
    /// Owns the random host names' address records; deallocating it removes them.
    private var connection: DNSServiceRef?

    init(port: UInt16, tokens: String, interfaces: [String]) {
        self.port = port
        self.tokens = tokens
        self.interfaces = interfaces
    }

    func start() {
        var txt = TXTRecordRef()
        TXTRecordCreate(&txt, 0, nil)
        TXTRecordSetValue(&txt, "v", 1, "2")
        // A TXT value holds at most 255 bytes: 19 ids of 12 digits with separators.
        let value = String(tokens.prefix(255))
        _ = value.withCString { TXTRecordSetValue(&txt, "k", UInt8(strlen($0)), $0) }
        defer { TXTRecordDeallocate(&txt) }
        let context = Unmanaged.passUnretained(self).toOpaque()
        if !interfaces.isEmpty {
            var connection: DNSServiceRef?
            let status = DNSServiceCreateConnection(&connection)
            if status == kDNSServiceErr_NoError, let connection {
                DNSServiceSetDispatchQueue(connection, .main)
                self.connection = connection
            } else {
                handleReply(status)
            }
        }
        for name in interfaces {
            let index = if_nametoindex(name)
            // Without its own host records the service would fall back to the Mac's host name.
            guard index != 0, let host = registerHost(interface: name, index: index, context: context) else { continue }
            var ref: DNSServiceRef?
            let status = DNSServiceRegister(
                &ref, 0, index, "Brêge", "_brege._udp", nil, host, port.bigEndian,
                TXTRecordGetLength(&txt), TXTRecordGetBytesPtr(&txt),
                { _, _, error, _, _, _, context in
                    guard let context else { return }
                    let advertiser = Unmanaged<BonjourAdvertiser>.fromOpaque(context).takeUnretainedValue()
                    advertiser.handleReply(error)
                },
                context
            )
            if status == kDNSServiceErr_NoError, let ref {
                DNSServiceSetDispatchQueue(ref, .main)
                refs.append(ref)
            } else {
                handleReply(status)
            }
        }
    }

    /// Registers A (and AAAA, for routable IPv6) records for a new random name on one interface
    /// and returns the name, or nil when none could be registered.
    private func registerHost(interface name: String, index: UInt32, context: UnsafeMutableRawPointer) -> String? {
        guard let connection else { return nil }
        let host = String(format: "brege-%08x.local.", UInt32.random(in: .min ... .max))
        let addresses = LocalAddresses.recordAddresses(of: name)
        let records = addresses.v4.map { (UInt16(kDNSServiceType_A), $0) } + addresses.v6.map { (UInt16(kDNSServiceType_AAAA), $0) }
        var registered = false
        for (type, rdata) in records {
            var record: DNSRecordRef?
            let status = rdata.withUnsafeBytes { bytes in
                DNSServiceRegisterRecord(
                    connection, &record, DNSServiceFlags(kDNSServiceFlagsUnique), index, host,
                    type, UInt16(kDNSServiceClass_IN), UInt16(bytes.count), bytes.baseAddress, 120,
                    { _, _, _, error, context in
                        guard let context else { return }
                        let advertiser = Unmanaged<BonjourAdvertiser>.fromOpaque(context).takeUnretainedValue()
                        advertiser.handleReply(error)
                    },
                    context
                )
            }
            if status == kDNSServiceErr_NoError {
                registered = true
            } else {
                handleReply(status)
            }
        }
        return registered ? host : nil
    }

    func stop() {
        refs.forEach { DNSServiceRefDeallocate($0) }
        refs = []
        // The records go with their connection.
        connection.map(DNSServiceRefDeallocate)
        connection = nil
    }

    deinit { stop() }

    private func handleReply(_ error: DNSServiceErrorType) {
        if error == kDNSServiceErr_PolicyDenied {
            NSLog("Brêge: Local Network access denied by macOS")
            onLocalNetworkDenied?(true)
        } else if error == kDNSServiceErr_NoError {
            onLocalNetworkDenied?(false)
        } else {
            NSLog("Brêge: Bonjour registration failed: \(error)")
        }
    }

    static func openLocalNetworkSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
    }
}

enum LocalAddresses {
    struct Interface {
        let name: String
        let ip: String
        let index: UInt32
    }

    /// One interface's addresses as DNS record data (network byte order): IPv4 without
    /// link-local ones, and globally routable IPv6 (2000::/3) only.
    static func recordAddresses(of interface: String) -> (v4: [Data], v6: [Data]) {
        var v4: [Data] = []
        var v6: [Data] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return ([], []) }
        defer { freeifaddrs(ifaddr) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard String(cString: pointer.pointee.ifa_name) == interface, let addr = pointer.pointee.ifa_addr else { continue }
            switch Int32(addr.pointee.sa_family) {
            case AF_INET:
                let bytes = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin_addr) { Data($0) } }
                if !(bytes[0] == 169 && bytes[1] == 254) { v4.append(bytes) }
            case AF_INET6:
                let bytes = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin6_addr) { Data($0) } }
                if bytes[0] & 0xe0 == 0x20 { v6.append(bytes) }
            default:
                break
            }
        }
        return (v4, v6)
    }

    /// IPv4 addresses a phone on the same network can reach, for the pairing QR code.
    static func ipv4() -> [String] { reachable().map(\.ip) }

    /// Interfaces a phone can reach us on.
    ///
    /// Skips virtual-machine bridges, VPN tunnels and Apple-internal links. When the Mac has
    /// several addresses in one subnet (e.g. Wi‑Fi and Ethernet on the same router), only the one
    /// macOS sends from is kept: macOS cannot answer UDP from the address a packet arrived on, so a
    /// phone that dials the other address would get replies from an unexpected address and QUIC
    /// would drop them.
    static func reachable() -> [Interface] {
        let skippedPrefixes = ["lo", "bridge", "utun", "awdl", "llw", "anpi", "ap", "gif", "stf", "vmnet", "vboxnet", "feth"]
        var candidates: [(Interface, UInt32, UInt32)] = [] // interface, address, netmask (host order)
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            let name = String(cString: pointer.pointee.ifa_name)
            guard let addr = pointer.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  let mask = pointer.pointee.ifa_netmask,
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0,
                  !skippedPrefixes.contains(where: name.hasPrefix) else { continue }
            let v4 = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let m4 = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let ip = format(v4)
            if ip.hasPrefix("169.254.") { continue }
            candidates.append((Interface(name: name, ip: ip, index: if_nametoindex(name)), v4, m4))
        }
        return candidates.filter { interface, address, mask in
            let sameSubnet = candidates.filter { ($0.1 & $0.2) == (address & mask) }
            guard sameSubnet.count > 1 else { return true }
            // Several addresses in one subnet: keep the one the kernel picks as source.
            var probe = (address & mask) | 1
            if probe == address { probe += 1 }
            return sourceAddress(toward: probe) == interface.ip
        }.map(\.0)
    }

    /// The source address macOS uses for packets to `destination` (a connected UDP socket
    /// sends nothing; it only resolves the route).
    private static func sourceAddress(toward destination: UInt32) -> String? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var remote = sockaddr_in()
        remote.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        remote.sin_family = sa_family_t(AF_INET)
        remote.sin_port = in_port_t(9).bigEndian
        remote.sin_addr.s_addr = destination.bigEndian
        let connected = withUnsafePointer(to: &remote) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }
        var local = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard named == 0 else { return nil }
        return format(UInt32(bigEndian: local.sin_addr.s_addr))
    }

    private static func format(_ v4: UInt32) -> String {
        "\((v4 >> 24) & 0xff).\((v4 >> 16) & 0xff).\((v4 >> 8) & 0xff).\(v4 & 0xff)"
    }
}

/// The Mac's network interfaces for the core's path rules (network privacy plan): addresses,
/// kind, router and the router's hardware address (from the ARP table, no permission needed).
enum NetworkSnapshot {
    private static let tunnelPrefixes = ["utun", "ipsec", "ppp", "tun", "tap", "wg"]
    private static let skippedPrefixes = ["lo", "awdl", "llw", "anpi", "ap", "gif", "stf", "vmnet", "vboxnet", "feth"]

    /// Blocking (runs `ipconfig` and `arp`): call off the main thread.
    static func current() -> [NetworkInterfaceData] {
        var byName: [String: [String]] = [:]
        var order: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            let name = String(cString: pointer.pointee.ifa_name)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, !skippedPrefixes.contains(where: name.hasPrefix),
                  let addr = pointer.pointee.ifa_addr, let mask = pointer.pointee.ifa_netmask,
                  let entry = format(address: addr, mask: mask) else { continue }
            if byName[name] == nil { order.append(name) }
            byName[name, default: []].append(entry)
        }
        let wifi = Set(CWWiFiClient.shared().interfaceNames() ?? [])
        return order.map { name in
            let kind: NetworkInterfaceKind
            if tunnelPrefixes.contains(where: name.hasPrefix) {
                kind = .vpn
            } else if wifi.contains(name) {
                kind = .wifi
            } else if name.hasPrefix("en") {
                kind = .ethernet
            } else {
                kind = .other
            }
            let gateway = kind == .vpn ? "" : router(of: name)
            // Only with Location access; otherwise nil and the router's hardware address identifies it.
            let ssid = kind == .wifi ? CWWiFiClient.shared().interface(withName: name)?.ssid() ?? "" : ""
            return NetworkInterfaceData(name: name, kind: kind, addresses: byName[name] ?? [],
                                        gateway: gateway, gatewayHw: gateway.isEmpty ? "" : hardwareAddress(of: gateway),
                                        ssid: ssid)
        }
    }

    /// "address/prefix", skipping link-local addresses (never a path to a phone).
    private static func format(address: UnsafeMutablePointer<sockaddr>, mask: UnsafeMutablePointer<sockaddr>) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
            guard getnameinfo(address, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { return nil }
            let ip = String(cString: host)
            guard !ip.hasPrefix("169.254.") else { return nil }
            let bits = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr.nonzeroBitCount }
            return "\(ip)/\(bits)"
        case AF_INET6:
            guard getnameinfo(address, socklen_t(MemoryLayout<sockaddr_in6>.size), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { return nil }
            let ip = String(cString: host)
            guard !ip.lowercased().hasPrefix("fe80") else { return nil }
            let bits = mask.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                withUnsafeBytes(of: pointer.pointee.sin6_addr) { $0.reduce(0) { $0 + $1.nonzeroBitCount } }
            }
            return "\(ip.split(separator: "%").first.map(String.init) ?? ip)/\(bits)"
        default:
            return nil
        }
    }

    private static func router(of interface: String) -> String {
        run("/usr/sbin/ipconfig", ["getoption", interface, "router"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "? (192.168.50.1) at aa:bb:cc:dd:ee:ff on en0 ifscope [ethernet]"
    private static func hardwareAddress(of ip: String) -> String {
        let output = run("/usr/sbin/arp", ["-n", ip])
        guard let at = output.range(of: " at ") else { return "" }
        let rest = output[at.upperBound...]
        let hw = rest.prefix { !$0.isWhitespace }
        return hw.contains(":") ? String(hw) : ""
    }

    private static func run(_ path: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Tells the core about network changes so it reconnects immediately. All callbacks run
/// on the main queue.
final class NetworkChangeMonitor {
    private let monitor = NWPathMonitor()
    private var observers: [NSObjectProtocol] = []

    init(onChange: @escaping () -> Void, onSleep: @escaping () -> Void, onWake: @escaping () -> Void) {
        monitor.pathUpdateHandler = { _ in DispatchQueue.main.async(execute: onChange) }
        monitor.start(queue: DispatchQueue(label: "brege.network"))
        // The Mac may wake up on another network; nothing is announced until it is known.
        let center = NSWorkspace.shared.notificationCenter
        observers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { _ in onSleep() },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in onWake() },
        ]
    }

    deinit {
        monitor.cancel()
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
    }
}

// MARK: - Phone nearby (network privacy plan)

/// Listens for the rotating Bluetooth LE id a paired phone advertises while it is not connected,
/// so Brêge only asks about a new network when a phone is actually nearby. Scans only while a
/// network has not been asked about yet.
final class PhoneNearbyScanner: NSObject, CBCentralManagerDelegate {
    private static let prefix = "B7E60003"
    /// Service UUID → paired phone's device id, if it is one.
    var match: ((String) -> String?)?
    /// Called on the main queue when a paired phone is seen.
    var onNearby: ((String) -> Void)?
    private var central: CBCentralManager?
    private var wanted = false
    private var lastSeen: [String: Date] = [:]
    /// Results per advertised id (they rotate every 15 minutes), so each is matched once.
    private var matched: [String: String?] = [:]

    func setScanning(_ on: Bool) {
        guard on != wanted else { return }
        wanted = on
        if on {
            if let central {
                if central.state == .poweredOn { start() }
            } else {
                central = CBCentralManager(delegate: self, queue: nil)
            }
        } else {
            central?.stopScan()
        }
    }

    func isNearby(_ deviceId: String) -> Bool {
        lastSeen[deviceId].map { Date().timeIntervalSince($0) < 120 } ?? false
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn, wanted { start() }
    }

    private func start() {
        central?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let uuids = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] else { return }
        for uuid in uuids where uuid.uuidString.hasPrefix(Self.prefix) {
            let key = uuid.uuidString
            if matched[key] == nil {
                if matched.count > 256 { matched.removeAll() }
                matched[key] = .some(match?(key))
            }
            guard let deviceId = matched[key] ?? nil else { continue }
            let first = !isNearby(deviceId)
            lastSeen[deviceId] = Date()
            if first { onNearby?(deviceId) }
        }
    }
}

// MARK: - BLE presence

/// Advertises the Brêge service UUID so the phone can create its CompanionDeviceManager
/// association and wake on proximity. While the Mac asks for the phone's hotspot it
/// advertises only the signed request UUID instead: three 128-bit UUIDs would not fit.
final class PresenceAdvertiser: NSObject, CBPeripheralManagerDelegate {
    static let serviceUUID = CBUUID(string: "B7E60001-5A1C-4E0B-9C43-8D2F6E1B7E60")
    private var manager: CBPeripheralManager?
    private var hotspotRequest: CBUUID?

    func setHotspotRequest(_ uuid: CBUUID?) {
        guard uuid != hotspotRequest else { return }
        hotspotRequest = uuid
        guard let manager, manager.state == .poweredOn else { return }
        manager.stopAdvertising()
        advertise(manager)
    }

    func start() {
        manager = CBPeripheralManager(delegate: self, queue: nil)
    }

    func stop() {
        manager?.stopAdvertising()
        manager = nil
    }

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        Logger(subsystem: "app.brege.mac", category: "ble").notice("peripheral state \(peripheral.state.rawValue, privacy: .public)")
        guard peripheral.state == .poweredOn else { return }
        advertise(peripheral)
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        let log = Logger(subsystem: "app.brege.mac", category: "ble")
        if let error {
            log.error("advertising failed: \(error.localizedDescription, privacy: .public)")
        } else {
            log.notice("advertising \(self.hotspotRequest == nil ? "presence" : "hotspot request", privacy: .public)")
        }
    }

    private func advertise(_ peripheral: CBPeripheralManager) {
        if let hotspotRequest {
            peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [hotspotRequest]])
        } else {
            peripheral.startAdvertising([
                CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
                CBAdvertisementDataLocalNameKey: "Brêge",
            ])
        }
    }
}

// MARK: - Alerts

/// Runs modal alerts and panels from a run-loop source instead of the calling code.
/// `runModal` inside a main-actor task or a main-queue block keeps the main queue busy until it
/// closes, which holds up core events and every other task; from a run-loop source the modal
/// loop keeps serving the main queue.
enum ModalAlert {
    static func run(_ body: @escaping @MainActor () -> Void) {
        RunLoop.main.perform {
            MainActor.assumeIsolated {
                NSApp.activate(ignoringOtherApps: true)
                body()
            }
        }
    }

    static func show(_ alert: NSAlert, then completion: @escaping @MainActor (NSApplication.ModalResponse) -> Void = { _ in }) {
        run { completion(alert.runModal()) }
    }
}

// MARK: - QR code

enum QRCode {
    static func image(for string: String, size: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}
