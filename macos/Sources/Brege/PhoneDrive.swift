import AppKit
import BregeCore
import dnssd
import Foundation
import NetFS

/// Mounts a phone's shared folders as a network volume in Finder.
/// The core serves them over WebDAV on 127.0.0.1; no File Provider extension is needed.
@MainActor
final class PhoneDriveController {
    enum DriveError: LocalizedError {
        case nothingShared
        case mountFailed(Int32)
        case disconnected

        var errorDescription: String? {
            switch self {
            case .nothingShared:
                return "No folders are shared yet. On your phone, open Brêge and choose “Add folder” under “Phone folders on your Mac”."
            case let .mountFailed(code):
                return "macOS could not mount the phone (error \(code))."
            case .disconnected:
                return "The phone disconnected."
            }
        }
    }

    private var mounted: [String: URL] = [:] // device id → mount point
    private var hostnames: [String: LoopbackHostname] = [:] // device id → registered name
    /// Opens in progress; `eject` removes the entry, and the open then undoes what it started.
    private var opening: [String: UUID] = [:] // device id → open
    /// The node serving the mounted drives, to stop a drive the user ejected in Finder.
    private weak var node: BregeNode?
    private var unmountObserver: NSObjectProtocol?

    init() {
        unmountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let volume = notification.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return }
            Task { @MainActor in self?.volumeUnmounted(volume) }
        }
    }

    deinit {
        if let unmountObserver { NSWorkspace.shared.notificationCenter.removeObserver(unmountObserver) }
    }

    /// Ejected in Finder (or by another app): the server is no longer needed.
    private func volumeUnmounted(_ volume: URL) {
        let path = volume.standardizedFileURL.path
        guard let deviceId = mounted.first(where: { $0.value.standardizedFileURL.path == path })?.key else { return }
        mounted[deviceId] = nil
        node?.stopPhoneDrive(deviceId: deviceId)
        hostnames[deviceId] = nil
    }

    func open(device: Device, node: BregeNode) async throws {
        if let mountPoint = mounted[device.id], FileManager.default.fileExists(atPath: mountPoint.path) {
            NSWorkspace.shared.open(mountPoint)
            return
        }
        let token = UUID()
        opening[device.id] = token
        defer { if opening[device.id] == token { opening[device.id] = nil } }
        let ejected = { self.opening[device.id] != token }

        // Check first, so the user gets a helpful message instead of an empty volume.
        let shared = try await node.phoneFolder(deviceId: device.id, path: "/")
        if ejected() { throw DriveError.disconnected }
        if shared.isEmpty { throw DriveError.nothingShared }

        let info = try await node.startPhoneDrive(deviceId: device.id, volumeName: device.name)
        if ejected() {
            node.stopPhoneDrive(deviceId: device.id)
            throw DriveError.disconnected
        }
        guard var url = URL(string: info.url) else { throw DriveError.mountFailed(-1) }
        // Finder labels the volume's server by its host name: use the phone's name instead of 127.0.0.1.
        hostnames[device.id] = nil
        if let hostname = LoopbackHostname(label: device.name), var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.host = hostname.name
            if let named = components.url {
                url = named
                hostnames[device.id] = hostname
            }
        }
        let mountPoint: URL
        do {
            mountPoint = try await mount(url)
        } catch {
            // Nothing will use the server or the host name (eject already removed them if it ran).
            if !ejected() {
                node.stopPhoneDrive(deviceId: device.id)
                hostnames[device.id] = nil
            }
            throw error
        }
        if ejected() {
            _ = unmount(mountPoint.path, MNT_FORCE)
            node.stopPhoneDrive(deviceId: device.id)
            throw DriveError.disconnected
        }
        mounted[device.id] = mountPoint
        self.node = node
        NSWorkspace.shared.open(mountPoint)
    }

    private func mount(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let openOptions = NSMutableDictionary()
            openOptions[kNAUIOptionKey] = kNAUIOptionNoUI
            // The drive has no account; without guest access macOS refuses with -6600.
            // Access is protected by the random secret in the URL and the loopback-only server.
            openOptions[kNetFSUseGuestKey] = true
            let mountOptions = NSMutableDictionary()
            var request: AsyncRequestID?
            let status = NetFSMountURLAsync(
                url as CFURL, nil, nil, nil, openOptions, mountOptions, &request, DispatchQueue.main
            ) { status, _, mountPoints in
                if status == 0, let first = (mountPoints as? [String])?.first {
                    continuation.resume(returning: URL(fileURLWithPath: first))
                } else {
                    continuation.resume(throwing: DriveError.mountFailed(status))
                }
            }
            if status != 0 {
                continuation.resume(throwing: DriveError.mountFailed(status))
            }
        }
    }

    func isMounted(deviceId: String) -> Bool {
        mounted[deviceId].map { FileManager.default.fileExists(atPath: $0.path) } ?? false
    }

    /// Unmounts and stops the server, e.g. when the phone disconnects or Brêge quits.
    func eject(deviceId: String, node: BregeNode?) {
        opening[deviceId] = nil
        if let mountPoint = mounted.removeValue(forKey: deviceId) {
            _ = unmount(mountPoint.path, MNT_FORCE)
        }
        node?.stopPhoneDrive(deviceId: deviceId)
        hostnames[deviceId] = nil
    }

    func ejectAll(node: BregeNode?) {
        for id in Set(mounted.keys).union(opening.keys) { eject(deviceId: id, node: node) }
    }
}

/// A `<name>.local` host name that resolves to the loopback addresses on this Mac only
/// (a local-only Bonjour record, never announced on the network). Removed on deinit.
final class LoopbackHostname {
    let name: String
    private var connection: DNSServiceRef?

    init?(label: String) {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let words = label.map { allowed.contains($0) ? String($0) : " " }.joined()
            .split(separator: " ")
        let slug = String(words.joined(separator: "-").prefix(60))
        name = (slug.isEmpty ? "Phone" : slug) + ".local"

        guard DNSServiceCreateConnection(&connection) == kDNSServiceErr_NoError else { return nil }
        let ipv4: [UInt8] = [127, 0, 0, 1]
        let ipv6: [UInt8] = [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]
        for (type, address) in [(kDNSServiceType_A, ipv4), (kDNSServiceType_AAAA, ipv6)] {
            var record: DNSRecordRef?
            let status = address.withUnsafeBytes { bytes in
                DNSServiceRegisterRecord(
                    connection, &record, DNSServiceFlags(kDNSServiceFlagsUnique),
                    UInt32(kDNSServiceInterfaceIndexLocalOnly), name + ".", UInt16(type),
                    UInt16(kDNSServiceClass_IN), UInt16(bytes.count), bytes.baseAddress, 120,
                    { _, _, _, _, _ in }, nil
                )
            }
            if status != kDNSServiceErr_NoError {
                DNSServiceRefDeallocate(connection)
                connection = nil
                return nil
            }
        }
        DNSServiceSetDispatchQueue(connection, .main)
    }

    deinit {
        if let connection { DNSServiceRefDeallocate(connection) }
    }
}
