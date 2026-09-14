import Foundation

/// Preferences for the newer features, stored in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var copyCodesAutomatically: Bool { didSet { save(copyCodesAutomatically, "copyCodesAutomatically") } }
    @Published var showRecentPhotos: Bool { didSet { save(showRecentPhotos, "showRecentPhotos") } }
    @Published var copyNewScreenshots: Bool { didSet { save(copyNewScreenshots, "copyNewScreenshots") } }
    @Published var pauseAudioDuringCalls: Bool { didSet { save(pauseAudioDuringCalls, "pauseAudioDuringCalls") } }
    @Published var lowBatteryAlert: Bool { didSet { save(lowBatteryAlert, "lowBatteryAlert") } }
    @Published var lowBatteryThreshold: Int { didSet { save(lowBatteryThreshold, "lowBatteryThreshold") } }
    @Published var fullBatteryAlert: Bool { didSet { save(fullBatteryAlert, "fullBatteryAlert") } }

    /// For code that is not on the main actor (notification delivery).
    nonisolated static var copiesCodesAutomatically: Bool {
        UserDefaults.standard.object(forKey: "copyCodesAutomatically") as? Bool ?? true
    }

    private init() {
        let d = UserDefaults.standard
        copyCodesAutomatically = d.object(forKey: "copyCodesAutomatically") as? Bool ?? true
        showRecentPhotos = d.object(forKey: "showRecentPhotos") as? Bool ?? true
        copyNewScreenshots = d.object(forKey: "copyNewScreenshots") as? Bool ?? false
        pauseAudioDuringCalls = d.object(forKey: "pauseAudioDuringCalls") as? Bool ?? false
        lowBatteryAlert = d.object(forKey: "lowBatteryAlert") as? Bool ?? true
        lowBatteryThreshold = d.object(forKey: "lowBatteryThreshold") as? Int ?? 15
        fullBatteryAlert = d.object(forKey: "fullBatteryAlert") as? Bool ?? false
    }

    private func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
