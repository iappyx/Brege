import AppKit
import BregeCore

/// Import from phone: take a photo or scan a document on the phone and use it on the Mac. The phone sends the file as a normal transfer and
/// reports its transfer id in a `CaptureResult`; the two can arrive in either order.
@MainActor
final class PhoneCapture: ObservableObject {
    enum Delivery {
        /// Put the file on the clipboard and tell the user.
        case clipboard
        /// A Services request waits for the file.
        case service((Result<URL, CaptureError>) -> Void)
        /// Save into a folder chosen in Finder and select the file there.
        case folder(URL)
        /// Hand the file to a caller (dragging a recent photo), without any notice or preview.
        case file((Result<URL, CaptureError>) -> Void)
    }

    struct CaptureError: Error {
        let message: String
    }

    private struct Pending {
        let kind: CaptureKind
        let deviceId: String
        let delivery: Delivery
        /// Started by the user (not a recent-photo fetch): shown in the menu.
        let showsStatus: Bool
        var transferId: String?
        /// Recent photos: where the full photo is kept.
        var cacheFolder: URL? = nil
    }

    /// Shown in the menu on the phone's card while waiting, e.g. "Take the photo on Pixel…".
    @Published private(set) var statuses: [String: String] = [:] // device id

    private var pending: [String: Pending] = [:] // request id
    /// Transfers started by captures and recent photos: not listed under Transfers.
    private(set) var ownTransfers: Set<String> = []
    /// Incoming transfers that completed while a request from the same phone had no transfer id
    /// yet: its result may still claim them.
    private var finishedTransfers: [(id: String, path: String)] = []
    private let presenter: NotificationPresenter
    private let node: () -> BregeNode?
    private let shelf = CaptureShelf()

    init(presenter: NotificationPresenter, node: @escaping () -> BregeNode?) {
        self.presenter = presenter
        self.node = node
    }

    var isWaiting: Bool { !pending.isEmpty }

    func start(_ kind: CaptureKind, device: Device, delivery: Delivery) {
        guard device.connected, let node = node() else {
            fail(delivery, "\(device.name) is not connected.")
            return
        }
        do {
            let requestId = try node.requestCapture(deviceId: device.id, kind: kind)
            // The phone shows one capture notification and replaces it for a new request, so
            // only the newest request can still be answered.
            let replaced = pending.filter { $0.value.showsStatus && $0.value.deviceId == device.id }
            replaced.keys.forEach { pending[$0] = nil }
            replaced.values.forEach { fail($0.delivery, "Replaced by a newer request.", notify: false) }
            pending[requestId] = Pending(kind: kind, deviceId: device.id, delivery: delivery, showsStatus: true)
            statuses[device.id] = kind == .photo ? "Take the photo on \(device.name)…" : "Scan the document on \(device.name)…"
            // The phone's notification expires after three minutes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 200) { [weak self] in
                guard let self, let request = self.pending.removeValue(forKey: requestId) else { return }
                self.updateStatus()
                self.fail(request.delivery, "Nothing arrived from the phone.")
            }
        } catch {
            fail(delivery, error.localizedDescription)
        }
    }

    /// A recent photo from the phone (the menu strip): the phone answers like a capture.
    @discardableResult
    func fetchMedia(_ mediaId: String, device: Device, delivery: Delivery) -> String? {
        Self.cleanCacheHourly()
        let cacheFolder = Self.cacheFolder(mediaId: mediaId, deviceId: device.id)
        if case let .file(completion) = delivery, let cached = Self.cachedFile(in: cacheFolder) {
            completion(.success(cached))
            return nil
        }
        guard device.connected, let node = node() else {
            fail(delivery, "\(device.name) is not connected.")
            return nil
        }
        do {
            let requestId = try node.requestMedia(deviceId: device.id, mediaId: mediaId)
            pending[requestId] = Pending(kind: .photo, deviceId: device.id, delivery: delivery, showsStatus: false,
                                         cacheFolder: cacheFolder)
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
                guard let self, let request = self.pending.removeValue(forKey: requestId) else { return }
                self.updateStatus()
                self.fail(request.delivery, "The photo did not arrive.")
            }
            return requestId
        } catch {
            fail(delivery, error.localizedDescription)
            return nil
        }
    }

    /// The transfer carrying a request's file, once the phone has reported it.
    func transferId(forRequest requestId: String) -> String? {
        pending[requestId]?.transferId
    }

    /// Shows the draggable preview for a file that is already on the Mac.
    func showPreview(_ url: URL) {
        shelf.show(url)
    }

    /// Cancels the captures shown on a phone's card.
    func cancel(deviceId: String) {
        let requests = pending.filter { $0.value.showsStatus && $0.value.deviceId == deviceId }
        requests.keys.forEach { pending[$0] = nil }
        updateStatus()
        requests.values.forEach { fail($0.delivery, "Cancelled.", notify: false) }
    }

    /// Fails every request waiting on a phone that disconnected: its answer cannot arrive.
    func phoneDisconnected(_ deviceId: String) {
        let requests = pending.filter { $0.value.deviceId == deviceId }
        guard !requests.isEmpty else { return }
        requests.keys.forEach { pending[$0] = nil }
        updateStatus()
        requests.values.forEach { fail($0.delivery, "The phone disconnected before the file arrived.", notify: $0.showsStatus) }
    }

    // MARK: Events

    func resultReceived(requestId: String, status: CaptureStatus, transferId: String, detail: String) {
        guard var request = pending[requestId] else { return }
        switch status {
        case .sending:
            request.transferId = transferId
            ownTransfers.insert(transferId)
            pending[requestId] = request
            if request.showsStatus {
                statuses[request.deviceId] = request.kind == .photo ? "Receiving the photo…" : "Receiving the scan…"
            }
            if let index = finishedTransfers.firstIndex(where: { $0.id == transferId }) {
                let done = finishedTransfers.remove(at: index)
                deliver(requestId: requestId, path: done.path)
            }
        case .cancelled:
            pending[requestId] = nil
            updateStatus()
            fail(request.delivery, "Cancelled on the phone.", notify: false)
        case .failed:
            pending[requestId] = nil
            updateStatus()
            fail(request.delivery, detail.isEmpty ? "The phone could not capture." : detail)
        }
    }

    /// Returns true when the transfer belongs to a capture, or may (no "file received" notice then).
    func transferCompleted(id: String, path: String, from deviceId: String) -> Bool {
        if let requestId = pending.first(where: { $0.value.transferId == id })?.key {
            deliver(requestId: requestId, path: path)
            return true
        }
        // The phone's result may still be on its way: hold the file briefly, and only tell the
        // user about it if no request claims it.
        guard pending.values.contains(where: { $0.deviceId == deviceId && $0.transferId == nil }) else { return false }
        finishedTransfers.append((id, path))
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, let index = self.finishedTransfers.firstIndex(where: { $0.id == id }) else { return }
            self.finishedTransfers.remove(at: index)
            self.presenter.showFileReceived(path: path)
        }
        return true
    }

    func transferFailed(id: String, reason: String) {
        guard let requestId = pending.first(where: { $0.value.transferId == id })?.key,
              let request = pending.removeValue(forKey: requestId) else { return }
        updateStatus()
        fail(request.delivery, reason)
    }

    // MARK: Delivery

    private func deliver(requestId: String, path: String) {
        guard let request = pending.removeValue(forKey: requestId) else { return }
        updateStatus()
        let url = URL(fileURLWithPath: path)
        switch request.delivery {
        case let .service(completion):
            completion(.success(url))
            // Not every app accepts a Services result (Outlook ignores it): dragging always works.
            shelf.show(url)
        case let .file(completion):
            // Photos fetched for the menu strip are temporary: keep them out of Downloads.
            completion(.success(request.cacheFolder.map { Self.move(url, toCache: $0) } ?? url))
        case let .folder(directory):
            do {
                let target = Self.uniqueURL(for: url.lastPathComponent, in: directory)
                try FileManager.default.copyItem(at: url, to: target)
                NSWorkspace.shared.activateFileViewerSelecting([target])
            } catch {
                presenter.showInfo(title: "Could not save into the folder", body: error.localizedDescription)
            }
        case .clipboard:
            let pasteboard = NSPasteboard.general
            Self.write(url, to: pasteboard)
            ClipboardMonitor.markOwnWrite(pasteboard)
            shelf.show(url)
        }
    }

    static let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(Bundle.main.bundleIdentifier ?? "app.brege.mac")
        .appendingPathComponent("Recent Photos", isDirectory: true)

    /// Each photo gets its own folder (per phone and media id), so it keeps its original name and
    /// is downloaded only once.
    private static func cacheFolder(mediaId: String, deviceId: String) -> URL {
        let safe = { (s: String) in String(s.map { $0.isLetter || $0.isNumber ? $0 : "_" }) }
        return cacheDirectory.appendingPathComponent("\(safe(deviceId).prefix(16))-\(safe(mediaId))", isDirectory: true)
    }

    private static func cachedFile(in folder: URL) -> URL? {
        guard let file = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?.first
        else { return nil }
        markUsed(file)
        return file
    }

    /// Cache folders (by path) → when their photo was last used.
    private static var lastUsed: [String: Date] = [:]

    /// A cached photo is still in use (shown, copied or dragged): keep it through the next cleanings.
    static func markUsed(_ file: URL) {
        let folder = file.deletingLastPathComponent().standardizedFileURL
        guard folder.deletingLastPathComponent().path == cacheDirectory.standardizedFileURL.path else { return }
        lastUsed[folder.path] = Date()
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: folder.path)
    }

    private static func move(_ url: URL, toCache folder: URL) -> URL {
        let target = folder.appendingPathComponent(url.lastPathComponent)
        do {
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: url, to: target)
            markUsed(target)
            return target
        } catch {
            return url
        }
    }

    private static var lastCacheClean = Date()

    private static func cleanCacheHourly() {
        guard Date().timeIntervalSince(lastCacheClean) > 3_600 else { return }
        lastCacheClean = Date()
        cleanCache()
    }

    /// Removes cached photos older than a day (at launch, then at most hourly while fetching);
    /// photos used in the last hour stay, as they may still be on the clipboard or being dropped.
    static func cleanCache() {
        let cutoff = Date().addingTimeInterval(-86_400)
        let inUse = Date().addingTimeInterval(-3_600)
        lastUsed = lastUsed.filter { $0.value > inUse }
        let folders = (try? FileManager.default.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for folder in folders {
            let modified = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            if modified < cutoff, lastUsed[folder.standardizedFileURL.path] == nil {
                try? FileManager.default.removeItem(at: folder)
            }
        }
    }

    private static func uniqueURL(for name: String, in directory: URL) -> URL {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    /// The file itself plus its content, so both documents and file fields accept it.
    static func write(_ url: URL, to pasteboard: NSPasteboard) {
        // The legacy file-name list comes first: Mail and other WebKit editors turn it into an
        // attachment, and prefer it over the content types below.
        pasteboard.declareTypes([NSPasteboard.PasteboardType("NSFilenamesPboardType"), .fileURL], owner: nil)
        pasteboard.setPropertyList([url.path], forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))
        pasteboard.setString(url.absoluteString, forType: .fileURL)
        if url.pathExtension.lowercased() == "pdf" {
            if let data = try? Data(contentsOf: url) {
                pasteboard.addTypes([.pdf], owner: nil)
                pasteboard.setData(data, forType: .pdf)
            }
        } else if let image = NSImage(contentsOf: url), let tiff = image.tiffRepresentation {
            pasteboard.addTypes([.tiff], owner: nil)
            pasteboard.setData(tiff, forType: .tiff)
        }
    }


    private func fail(_ delivery: Delivery, _ message: String, notify: Bool = true) {
        switch delivery {
        case let .service(completion), let .file(completion):
            completion(.failure(CaptureError(message: message)))
        case .clipboard, .folder:
            if notify { presenter.showInfo(title: "Import from phone", body: message) }
        }
    }

    private func updateStatus() {
        let waiting = Set(pending.values.filter(\.showsStatus).map(\.deviceId))
        statuses = statuses.filter { waiting.contains($0.key) }
    }
}

/// Services menu entries per phone ("Take Photo with <phone name>"). They are answered by the
/// Brêge Phones helper (`ServicesMenu`), which passes each request on through Brêge's relay
/// entries with the phone's id on the pasteboard; failures go back on the pasteboard too, so the
/// helper can show them in the app that asked. Services answer synchronously, so the call waits for
/// the phone while still handling Brêge's own events.
final class CaptureServicesProvider: NSObject {
    static let deviceType = NSPasteboard.PasteboardType("app.brege.service-device")
    static let errorType = NSPasteboard.PasteboardType("app.brege.service-error")

    @objc func takePhotoWithPhone(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        run(.photo, Request(pasteboard, userData, error))
    }

    @objc func scanDocumentWithPhone(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        run(.document, Request(pasteboard, userData, error))
    }

    // Finder: the selected folder (or the folder of the selected file) receives the result.
    @objc func takePhotoWithPhoneIntoFolder(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        saveIntoFolder(.photo, Request(pasteboard, userData, error))
    }

    @objc func scanDocumentWithPhoneIntoFolder(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        saveIntoFolder(.document, Request(pasteboard, userData, error))
    }

    private struct Request {
        let pasteboard: NSPasteboard
        let deviceId: String?
        let relayed: Bool
        let error: AutoreleasingUnsafeMutablePointer<NSString?>

        init(_ pasteboard: NSPasteboard, _ userData: String?, _ error: AutoreleasingUnsafeMutablePointer<NSString?>) {
            self.pasteboard = pasteboard
            self.error = error
            let relayedId = pasteboard.string(forType: CaptureServicesProvider.deviceType)
            relayed = relayedId != nil
            deviceId = [userData, relayedId].compactMap { $0 }.first { !$0.isEmpty }
        }

        func fail(_ message: String) {
            if relayed {
                pasteboard.declareTypes([CaptureServicesProvider.errorType], owner: nil)
                pasteboard.setString(message, forType: CaptureServicesProvider.errorType)
            } else {
                error.pointee = message as NSString
            }
        }
    }

    /// Created at launch, which may have been for a Services request.
    private let launched = Date()

    /// The phone the entry was written for, else the phone used last.
    @MainActor
    private func device(for request: Request) -> Device? {
        let model = AppModel.shared
        let find = { request.deviceId.map { id in model.devices.first { $0.id == id } } ?? model.defaultConnectedDevice }
        // A request that launched Brêge arrives before the phone has connected: wait for it a moment.
        if !model.isStarted || Date().timeIntervalSince(launched) < 30 {
            let deadline = Date().addingTimeInterval(15)
            while find()?.connected != true, Date() < deadline {
                if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.1), inMode: .default, dequeue: true) {
                    NSApp.sendEvent(event)
                }
            }
        }
        let device = find()
        guard let device, device.connected else {
            let name = request.deviceId.flatMap { id in model.devices.first { $0.id == id }?.name } ?? "Your phone"
            request.fail("\(name) is not connected to Brêge.")
            return nil
        }
        return device
    }

    private func saveIntoFolder(_ kind: CaptureKind, _ request: Request) {
        let urls = request.pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard let selected = urls.first else {
            request.fail("Select a folder in Finder first.")
            return
        }
        let isFolder = (try? selected.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        let directory = isFolder ? selected : selected.deletingLastPathComponent()
        MainActor.assumeIsolated {
            guard let device = self.device(for: request) else { return }
            // Finder does not wait for a result, so this returns at once.
            AppModel.shared.capture.start(kind, device: device, delivery: .folder(directory))
        }
    }

    /// The Services entries' NSTimeout (200 s): answer well before the relay and the app that
    /// asked give up, including the time spent waiting for the phone to connect.
    private static let serviceAnswerTime: TimeInterval = 180

    private func run(_ kind: CaptureKind, _ request: Request) {
        MainActor.assumeIsolated {
            let started = Date()
            guard let device = self.device(for: request) else { return }
            var result: Result<URL, PhoneCapture.CaptureError>?
            AppModel.shared.capture.start(kind, device: device, delivery: .service { result = $0 })
            let deadline = started.addingTimeInterval(Self.serviceAnswerTime)
            while result == nil, Date() < deadline {
                // Handling events too (not only the run loop) keeps Brêge's menu and windows
                // usable while the phone takes the photo, including Cancel.
                if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.1), inMode: .default, dequeue: true) {
                    NSApp.sendEvent(event)
                }
            }
            switch result {
            case let .success(url)?:
                PhoneCapture.write(url, to: request.pasteboard)
            case let .failure(failure)?:
                request.fail(failure.message)
            case nil:
                request.fail("Nothing arrived from the phone.")
            }
        }
    }
}
