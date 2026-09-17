import AppKit
import BregeCore
import SwiftUI
import UniformTypeIdentifiers

/// The phone's newest photos and screenshots in the menu: drag one into any app, or click to copy
/// it. Thumbnails come with the list; the full photo is fetched when needed (hover, drag, click).
@MainActor
final class RecentPhotosModel: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id: String
        let name: String
        let screenshot: Bool
        let mime: String
        let thumbnail: NSImage?
    }

    @Published private(set) var items: [Item] = []
    /// The phone app has no photo access yet.
    @Published private(set) var permissionNeeded = false
    private var deviceId: String?
    private var lastRequest = Date.distantPast
    /// Full photos already on the Mac, by media id.
    private var files: [String: URL] = [:]
    private var waiting: [String: [(Result<URL, PhoneCapture.CaptureError>) -> Void]] = [:]
    /// Media id → request id, while the full photo downloads.
    @Published private(set) var downloading: [String: String] = [:]

    private let capture: PhoneCapture
    private let node: () -> BregeNode?

    init(capture: PhoneCapture, node: @escaping () -> BregeNode?) {
        self.capture = capture
        self.node = node
    }

    /// Called when the menu opens; asks the phone at most every ten seconds.
    func refresh(_ device: Device?) {
        guard AppSettings.shared.showRecentPhotos, let device, device.connected else { return }
        if deviceId != device.id {
            deviceId = device.id
            items = []
            files = [:]
        }
        // Ask again right away while access is missing: the user may just have allowed it.
        guard permissionNeeded || Date().timeIntervalSince(lastRequest) > 10 else { return }
        lastRequest = Date()
        try? node()?.requestRecentMedia(deviceId: device.id, limit: 6)
    }

    func received(_ media: [MediaItemData], newScreenshot: Bool, permissionNeeded: Bool, from device: Device?) {
        guard let device, device.id == (deviceId ?? device.id) else { return }
        deviceId = device.id
        if !newScreenshot { self.permissionNeeded = permissionNeeded }
        let fresh = media.map {
            Item(id: $0.id, name: $0.name, screenshot: $0.screenshot, mime: $0.mime,
                 thumbnail: $0.thumbnailJpeg.isEmpty ? nil : NSImage(data: $0.thumbnailJpeg))
        }
        if newScreenshot {
            items = Array((fresh + items.filter { old in !fresh.contains { $0.id == old.id } }).prefix(6))
            if AppSettings.shared.copyNewScreenshots, let shot = fresh.first {
                copy(shot, from: device)
            }
        } else {
            items = fresh
        }
    }

    func clear() {
        items = []
        files = [:]
        deviceId = nil
    }

    // MARK: Full photos

    func file(for item: Item, from device: Device, completion: @escaping (Result<URL, PhoneCapture.CaptureError>) -> Void) {
        if let url = files[item.id], FileManager.default.fileExists(atPath: url.path) {
            PhoneCapture.markUsed(url)
            completion(.success(url))
            return
        }
        if waiting[item.id] != nil {
            waiting[item.id]?.append(completion)
            return
        }
        waiting[item.id] = [completion]
        let requestId = capture.fetchMedia(item.id, device: device, delivery: .file { [weak self] result in
            guard let self else { return }
            self.downloading[item.id] = nil
            if case let .success(url) = result { self.files[item.id] = url }
            let callbacks = self.waiting.removeValue(forKey: item.id) ?? []
            callbacks.forEach { $0(result) }
        })
        if let requestId, waiting[item.id] != nil { downloading[item.id] = requestId }
    }

    /// Download progress of a photo (0…1), `nil` when it is not downloading. Before the phone has
    /// started the transfer the value is 0.
    func progress(_ item: Item, transfers: [AppModel.Transfer]) -> Double? {
        guard let requestId = downloading[item.id] else { return nil }
        guard let transferId = capture.transferId(forRequest: requestId),
              let transfer = transfers.first(where: { $0.id == transferId }), transfer.total > 0 else { return 0 }
        return Double(transfer.bytes) / Double(transfer.total)
    }

    /// Starts fetching early (on hover), so a drag is instant.
    func prefetch(_ item: Item, from device: Device) {
        file(for: item, from: device) { _ in }
    }

    func copy(_ item: Item, from device: Device) {
        file(for: item, from: device) { [capture] result in
            guard case let .success(url) = result else { return }
            PhoneCapture.write(url, to: NSPasteboard.general)
            ClipboardMonitor.markOwnWrite()
            capture.showPreview(url)
        }
    }

    /// A drag that waits for the full photo if it is not on the Mac yet.
    func dragProvider(for item: Item, from device: Device) -> NSItemProvider {
        if let url = files[item.id], FileManager.default.fileExists(atPath: url.path),
           let provider = NSItemProvider(contentsOf: url) {
            PhoneCapture.markUsed(url)
            return provider
        }
        let provider = NSItemProvider()
        // Without a base name the drop target names the file after its type ("PNG image.png").
        provider.suggestedName = (item.name as NSString).deletingPathExtension
        let type = UTType(filenameExtension: (item.name as NSString).pathExtension) ?? UTType(mimeType: item.mime) ?? .jpeg
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            Task { @MainActor in
                self.file(for: item, from: device) { result in
                    switch result {
                    case let .success(url): completion(url, false, nil)
                    case let .failure(error): completion(nil, false, NSError(domain: "Brege", code: 1, userInfo: [NSLocalizedDescriptionKey: error.message]))
                    }
                }
            }
            return nil
        }
        return provider
    }
}

struct RecentPhotosStrip: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var photos: RecentPhotosModel
    @ObservedObject var settings = AppSettings.shared
    let device: Device

    var body: some View {
        if settings.showRecentPhotos, device.connected, photos.permissionNeeded {
            Label("To see recent photos here, open Brêge on your phone and allow photo access.", systemImage: "photo.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else if settings.showRecentPhotos || Screenshots.isActive, device.connected, !photos.items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Recent Photos").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button("All Photos…") { model.openPhotos(deviceId: device.id) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
                HStack(spacing: 6) {
                    ForEach(photos.items) { item in
                        thumbnail(item)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func thumbnail(_ item: RecentPhotosModel.Item) -> some View {
        Group {
            if let image = item.thumbnail {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: 48, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(.quaternary))
        .overlay {
            if let progress = photos.progress(item, transfers: model.transfers) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(.black.opacity(0.35))
                    Circle().stroke(.white.opacity(0.35), lineWidth: 3).frame(width: 22, height: 22)
                    Circle().trim(from: 0, to: max(0.05, progress))
                        .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 22, height: 22)
                }
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onHover { if $0 { photos.prefetch(item, from: device) } }
        .onTapGesture { photos.copy(item, from: device) }
        .onDrag { photos.dragProvider(for: item, from: device) }
        .help("\(item.screenshot ? "Screenshot" : "Photo") · drag into an app, or click to copy")
    }
}

extension RecentPhotosModel {
    /// Made-up photos for the README screenshots.
    func loadScreenshotData(_ items: [Item], deviceId: String) {
        self.deviceId = deviceId
        self.items = items
        permissionNeeded = false
    }
}
