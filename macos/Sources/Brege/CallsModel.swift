import BregeCore
import Foundation

/// Recent calls of one phone. The list comes from the core's encrypted cache, so it stays readable
/// while the phone is away; the phone pushes new calls and answers requests for older ones.
@MainActor
final class CallsModel: ObservableObject {
    @Published private(set) var calls: [CallLogData] = []
    @Published private(set) var hasOlder = true
    @Published private(set) var permissionNeeded = false

    let deviceId: String
    private var node: BregeNode?
    private let pageSize: UInt32 = 200
    private var loadingOlder = false

    init(deviceId: String) {
        self.deviceId = deviceId
    }

    func attach(node: BregeNode?) {
        guard self.node !== node else { return }
        self.node = node
        reload()
    }

    /// Reads the cache; call after every change event.
    func reload() {
        guard let node else { return }
        let cached = (try? node.recentCalls(deviceId: deviceId, limit: 1_000)) ?? []
        calls = cached
        if cached.isEmpty { hasOlder = false }
    }

    /// Asks the phone for calls that are newer than the cache.
    func refreshFromPhone() {
        try? node?.requestCallLog(deviceId: deviceId, limit: pageSize)
    }

    func loadOlder() {
        guard hasOlder, !loadingOlder else { return }
        loadingOlder = true
        let before = calls.count
        try? node?.requestOlderCalls(deviceId: deviceId, limit: pageSize)
        // If nothing arrives within a few seconds, stop offering more.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self else { return }
            self.loadingOlder = false
            if self.calls.count == before { self.hasOlder = false }
        }
    }

    /// Contact names by number, for the keypad's suggestions.
    var knownNames: [String: String] {
        var names: [String: String] = [:]
        for call in calls where !call.contactName.isEmpty {
            names[call.number] = call.contactName
        }
        return names
    }
}
