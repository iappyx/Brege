import AppKit
import BregeCore
import Foundation

/// The phone's whole photo library for the Photos window. Pages arrive newest first; thumbnails are
/// kept on disk so a second visit is instant and still works when the phone is away. A full photo or
/// video is only fetched when it is opened, dragged or saved.
@MainActor
final class PhotosModel: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id: String
        let name: String
        let takenMs: Int64
        let screenshot: Bool
        let mime: String
        let sizeBytes: UInt64
        let durationMs: UInt32
        let video: Bool
        var thumbnail: NSImage?
    }

    struct Album: Identifiable, Equatable {
        let id: String
        let name: String
        let count: UInt32
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var albums: [Album] = []
    @Published private(set) var loading = false
    @Published private(set) var reachedEnd = false
    @Published private(set) var permissionNeeded = false
    @Published private(set) var partialAccess = false
    @Published var album = "" { didSet { if album != oldValue { restart() } } }
    @Published var includeVideos = true { didSet { if includeVideos != oldValue { restart() } } }
    /// Media ids being fetched, with their request id, for the progress overlay.
    @Published private(set) var downloading: [String: String] = [:]

    let deviceId: String
    private let capture: PhoneCapture
    private let node: () -> BregeNode?
    private let pageSize: UInt32 = 60
    private var oldestMs: Int64 = 0
    private var files: [String: URL] = [:]
    private var waiting: [String: [(Result<URL, PhoneCapture.CaptureError>) -> Void]] = [:]
    private let cache: ThumbnailCache

    init(deviceId: String, capture: PhoneCapture, node: @escaping () -> BregeNode?) {
        self.deviceId = deviceId
        self.capture = capture
        self.node = node
        self.cache = ThumbnailCache(deviceId: deviceId)
    }

    // MARK: Pages

    /// Called when the window opens: shows what the cache has, then asks the phone.
    func start(_ device: Device?) {
        if items.isEmpty { items = cache.storedItems() }
        guard device?.connected == true else { return }
        if albums.isEmpty { try? node()?.requestMediaAlbums(deviceId: deviceId, includeVideos: includeVideos) }
        if items.isEmpty { loadMore(device) }
    }

    func restart() {
        items = []
        oldestMs = 0
        reachedEnd = false
        // A page still on its way belongs to the previous album; do not let it block the next one.
        loading = false
    }

    func loadMore(_ device: Device?) {
        guard device?.connected == true, !loading, !reachedEnd else { return }
        loading = true
        try? node()?.requestMediaLibrary(deviceId: deviceId, beforeMs: oldestMs, limit: pageSize,
                                         album: album, includeVideos: includeVideos)
        // A page that never arrives should not block the next attempt for ever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.loading = false }
    }

    func pageReceived(items new: [MediaItemData], end: Bool, album pageAlbum: String,
                      permissionNeeded: Bool, partialAccess: Bool) {
        guard pageAlbum == album else { return } // an answer for a view you already left
        loading = false
        self.permissionNeeded = permissionNeeded
        self.partialAccess = partialAccess
        reachedEnd = end
        for data in new {
            let thumbnail = data.thumbnailJpeg.isEmpty
                ? cache.image(for: data.id)
                : cache.store(data.thumbnailJpeg, for: data.id)
            let item = Item(id: data.id, name: data.name, takenMs: data.takenMs, screenshot: data.screenshot,
                            mime: data.mime, sizeBytes: data.sizeBytes, durationMs: data.durationMs,
                            video: data.video, thumbnail: thumbnail)
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index] = item
            } else {
                items.append(item)
            }
        }
        items.sort { $0.takenMs > $1.takenMs }
        if let oldest = items.last?.takenMs { oldestMs = oldest }
        cache.rememberItems(items)
    }

    func albumsReceived(_ albums: [MediaAlbumData]) {
        self.albums = albums.map { Album(id: $0.id, name: $0.name, count: $0.count) }
    }

    /// Items grouped by month, newest month first.
    var months: [(title: String, items: [Item])] {
        var groups: [(String, [Item])] = []
        for item in items {
            let title = Self.month(ms: item.takenMs)
            if groups.last?.0 == title {
                groups[groups.count - 1].1.append(item)
            } else {
                groups.append((title, [item]))
            }
        }
        return groups.map { (title: $0.0, items: $0.1) }
    }

    // MARK: Full photos and videos

    /// Big videos are only fetched when the window asked the user first.
    static let askBeforeBytes: UInt64 = 100 * 1024 * 1024

    func file(for item: Item, from device: Device,
              completion: @escaping (Result<URL, PhoneCapture.CaptureError>) -> Void) {
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

    func progress(_ item: Item, transfers: [AppModel.Transfer]) -> Double? {
        guard let requestId = downloading[item.id] else { return nil }
        guard let transferId = capture.transferId(forRequest: requestId),
              let transfer = transfers.first(where: { $0.id == transferId }), transfer.total > 0 else { return 0 }
        return Double(transfer.bytes) / Double(transfer.total)
    }

    private static func month(ms: Int64) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "LLLL yyyy"
        return formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
}

/// Thumbnails on disk, per phone, so the window opens instantly and works offline.
/// Photos themselves are never kept here; those go to Downloads › Brêge when you open one.
final class ThumbnailCache {
    /// Everything together stays under this; the oldest files go first.
    static let maxBytes: UInt64 = 500 * 1024 * 1024

    private let folder: URL
    private let index: URL

    init(deviceId: String) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        folder = caches.appendingPathComponent("app.brege.mac/thumbnails/\(deviceId)", isDirectory: true)
        index = folder.appendingPathComponent("index.json")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func image(for id: String) -> NSImage? {
        NSImage(contentsOf: folder.appendingPathComponent("\(id).jpg"))
    }

    @discardableResult
    func store(_ jpeg: Data, for id: String) -> NSImage? {
        let url = folder.appendingPathComponent("\(id).jpg")
        try? jpeg.write(to: url)
        return NSImage(data: jpeg)
    }

    /// Keeps the list of what the library holds, so the window shows something before the phone answers.
    func rememberItems(_ items: [PhotosModel.Item]) {
        let stored = items.prefix(2_000).map { item in
            ["id": item.id, "name": item.name, "takenMs": String(item.takenMs), "mime": item.mime,
             "screenshot": item.screenshot ? "1" : "0", "video": item.video ? "1" : "0",
             "sizeBytes": String(item.sizeBytes), "durationMs": String(item.durationMs)]
        }
        if let data = try? JSONSerialization.data(withJSONObject: stored) { try? data.write(to: index) }
        prune()
    }

    func storedItems() -> [PhotosModel.Item] {
        guard let data = try? Data(contentsOf: index),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: String]] else { return [] }
        return rows.compactMap { row in
            guard let id = row["id"] else { return nil }
            return PhotosModel.Item(
                id: id, name: row["name"] ?? "", takenMs: Int64(row["takenMs"] ?? "") ?? 0,
                screenshot: row["screenshot"] == "1", mime: row["mime"] ?? "image/jpeg",
                sizeBytes: UInt64(row["sizeBytes"] ?? "") ?? 0, durationMs: UInt32(row["durationMs"] ?? "") ?? 0,
                video: row["video"] == "1", thumbnail: image(for: id)
            )
        }
    }

    /// Drops the oldest thumbnails once the folder grows past the limit.
    private func prune() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentAccessDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return }
        let sized = files.compactMap { url -> (URL, UInt64, Date)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), let size = values.fileSize else { return nil }
            return (url, UInt64(size), values.contentAccessDate ?? .distantPast)
        }
        var total = sized.reduce(UInt64(0)) { $0 + $1.1 }
        guard total > Self.maxBytes else { return }
        for (url, size, _) in sized.sorted(by: { $0.2 < $1.2 }) where total > Self.maxBytes {
            try? FileManager.default.removeItem(at: url)
            total -= size
        }
    }
}
