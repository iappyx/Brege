import AppKit
import BregeCore
import Foundation

/// State of the Messages window. Data comes from the core's encrypted cache;
/// the phone keeps it up to date.
@MainActor
final class MessagesModel: ObservableObject {
    struct PendingMessage: Identifiable, Equatable {
        let id: String // client id
        let threadId: String
        let body: String
        let createdMs: Int64
        var status: MessageStatus
        var error: String
    }

    @Published private(set) var threads: [ThreadData] = []
    @Published private(set) var messages: [MessageData] = []
    @Published private(set) var pending: [PendingMessage] = []
    @Published private(set) var sims: [SimData] = []
    @Published private(set) var hasOlder = true
    @Published var selectedThreadId: String? {
        didSet { if selectedThreadId != oldValue, !skipLoading { openSelected() } }
    }
    private var skipLoading = false

    fileprivate func selectedThreadIdWithoutLoading(_ id: String) {
        skipLoading = true
        selectedThreadId = id
        skipLoading = false
    }
    @Published var errorMessage: String?
    /// A number to start a new message to (e.g. from a missed-call notification).
    @Published var composeNumber: String?
    /// Contact photos by address, fetched from the phone once per run and kept in memory only.
    @Published private(set) var photos: [String: NSImage] = [:]
    private var requestedPhotos = Set<String>()

    private var node: BregeNode?
    let deviceId: String
    private let pageSize: UInt32 = 50
    /// Older messages asked from the phone: thread, time they are older than, and an id so a
    /// timeout only ends its own request.
    private var historyRequest: (threadId: String, beforeMs: Int64, id: UUID)?

    var unreadCount: Int { threads.filter(\.unread).count }

    var selectedThread: ThreadData? { threads.first { $0.id == selectedThreadId } }

    init(deviceId: String) {
        self.deviceId = deviceId
    }

    func attach(node: BregeNode?) {
        guard self.node !== node else { return }
        self.node = node
        reloadThreads()
    }

    func reloadThreads() {
        guard let node else {
            threads = []
            return
        }
        threads = (try? node.messageThreads(deviceId: deviceId, limit: 500)) ?? []
        sims = (try? node.sims(deviceId: deviceId)) ?? []
        requestMissingPhotos()
    }

    func photo(for thread: ThreadData) -> NSImage? {
        thread.addresses.count == 1 ? photos[thread.addresses[0]] : nil
    }

    func photo(forNumber number: String) -> NSImage? {
        photos[number]
    }

    /// Asks the phone for photos of one-to-one threads not asked for yet; retried after a
    /// reconnect because failed requests are not remembered.
    private func requestMissingPhotos() {
        guard let node else { return }
        let wanted = Array(Set(threads.filter { $0.addresses.count == 1 }.map { $0.addresses[0] })
            .subtracting(requestedPhotos))
        for start in stride(from: 0, to: wanted.count, by: 25) {
            let batch = Array(wanted[start..<min(start + 25, wanted.count)])
            guard (try? node.requestContactPhotos(deviceId: deviceId, addresses: batch)) != nil else { return }
            requestedPhotos.formUnion(batch)
        }
    }

    func onContactPhotos(_ list: [ContactPhotoData]) {
        for photo in list where !photo.jpeg.isEmpty {
            if let image = NSImage(data: photo.jpeg) { photos[photo.address] = image }
        }
    }

    /// After a reconnect, photos that were requested while the phone was away are asked again.
    func resetPhotoRequests() {
        requestedPhotos = Set(photos.keys)
        requestMissingPhotos()
    }

    /// Called for `messagesUpdated`: refresh the list and, if needed, the open conversation.
    func onMessagesUpdated(threadIds: [String]) {
        reloadThreads()
        guard let selected = selectedThreadId, threadIds.contains(selected) else { return }
        reloadMessages(keepingCount: true)
        // The update may be a new message rather than the history: until older ones arrive, the
        // request stays open (its timeout ends it).
        if let request = historyRequest, request.threadId == selected,
           insertOlder(before: min(request.beforeMs, messages.first?.tsMs ?? request.beforeMs)) {
            historyRequest = nil
        }
        markSelectedRead()
    }

    func refreshFromPhone() {
        guard let node else { return }
        try? node.requestMessageSync(deviceId: deviceId)
    }

    private func openSelected() {
        hasOlder = true
        historyRequest = nil
        reloadMessages(keepingCount: false)
        markSelectedRead()
    }

    private func markSelectedRead() {
        guard let node, let thread = selectedThreadId else { return }
        try? node.markThreadRead(deviceId: deviceId, threadId: thread)
        if let index = threads.firstIndex(where: { $0.id == thread }), threads[index].unread {
            threads[index].unread = false
        }
    }

    private func reloadMessages(keepingCount: Bool) {
        guard let node, let thread = selectedThreadId else {
            messages = []
            return
        }
        let count = keepingCount ? max(UInt32(messages.count), pageSize) : pageSize
        messages = (try? node.threadMessages(deviceId: deviceId, threadId: thread, beforeMs: Int64.max, limit: count)) ?? []
        // A message that arrived from the phone replaces its optimistic bubble (in its own thread).
        pending.removeAll { p in
            p.status != .failed && (p.threadId.isEmpty || p.threadId == thread)
                && messages.contains { $0.outgoing && $0.body == p.body && $0.tsMs >= p.createdMs - 60_000 }
        }
    }

    /// Shows older cached messages, and asks the phone for more when the cache runs out.
    func loadOlder() {
        guard let node, let thread = selectedThreadId, historyRequest?.threadId != thread else { return }
        let oldest = messages.first?.tsMs ?? Int64.max
        guard !insertOlder(before: oldest) else { return }
        // The cache has nothing older: ask the phone, and show what it sends when it arrives.
        guard thread.hasPrefix("sms:"),
              (try? node.requestMessageHistory(deviceId: deviceId, threadId: thread, beforeMs: oldest, limit: pageSize)) != nil else {
            hasOlder = false
            return
        }
        let id = UUID()
        historyRequest = (thread, oldest, id)
        // A phone that has nothing older may not answer at all.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.historyRequest?.id == id else { return }
            self.historyRequest = nil
            self.hasOlder = false
        }
    }

    /// Adds a page of cached messages older than `beforeMs` to the top; returns whether there were any.
    private func insertOlder(before beforeMs: Int64) -> Bool {
        guard let node, let thread = selectedThreadId else { return false }
        // "Up to and including" the oldest time, so messages sharing that second are not skipped;
        // the ones already shown are left out.
        let shown = Set(messages.map(\.id))
        let older = ((try? node.threadMessages(deviceId: deviceId, threadId: thread, beforeMs: beforeMs, limit: pageSize)) ?? [])
            .filter { !shown.contains($0.id) }
        guard !older.isEmpty else { return false }
        messages.insert(contentsOf: older, at: 0)
        return true
    }

    // MARK: Sending

    func send(body: String, to thread: ThreadData, subId: Int32) {
        guard let node else { return }
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            let clientId = try node.sendMessage(
                deviceId: deviceId, threadId: thread.id, address: thread.addresses.first ?? "", body: text, subId: subId
            )
            pending.append(PendingMessage(id: clientId, threadId: thread.id, body: text,
                                          createdMs: Int64(Date().timeIntervalSince1970 * 1000),
                                          status: .sending, error: ""))
        } catch {
            errorMessage = "\(error)"
        }
    }

    /// Starts a conversation with a number that may not have a thread yet.
    /// Opens the conversation with this number, or a new message to it.
    func compose(to number: String) {
        let digits = { (s: String) in String(s.filter(\.isNumber).suffix(9)) }
        if let thread = threads.first(where: { $0.addresses.count == 1 && digits($0.addresses[0]) == digits(number) }) {
            selectedThreadId = thread.id
        } else {
            composeNumber = number
        }
    }

    func sendNew(body: String, to number: String, subId: Int32) -> Bool {
        guard let node else { return false }
        do {
            _ = try node.sendMessage(deviceId: deviceId, threadId: "", address: number, body: body, subId: subId)
            return true
        } catch {
            errorMessage = "\(error)"
            return false
        }
    }

    func onSendStatus(clientId: String, status: MessageStatus, error: String) {
        guard let index = pending.firstIndex(where: { $0.id == clientId }) else { return }
        pending[index].status = status
        pending[index].error = error
        if status == .sent {
            // The provider entry arrives shortly after; keep the bubble until then.
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                self?.pending.removeAll { $0.id == clientId && $0.status == .sent }
            }
        }
    }

    func dismissPending(_ id: String) {
        pending.removeAll { $0.id == id }
    }
}

extension ThreadData {
    var displayName: String {
        if !title.isEmpty { return title }
        let labels = zip(addresses, names + Array(repeating: "", count: max(0, addresses.count - names.count)))
            .map { address, name in name.isEmpty ? address : name }
        return labels.isEmpty ? "Unknown" : labels.joined(separator: ", ")
    }

    var callableNumber: String? {
        kind == .sms && addresses.count == 1 && addresses[0].contains(where: \.isNumber) ? addresses[0] : nil
    }
}

extension MessagesModel {
    /// Made-up conversations for the README screenshots.
    func loadScreenshotData(threads: [ThreadData], messages: [MessageData], selected: String) {
        self.threads = threads
        self.messages = messages
        selectedThreadIdWithoutLoading(selected)
    }
}
