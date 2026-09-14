import AppKit
import ServiceManagement

/// "Start Brêge at login" through the system login items (macOS 13+, no helper app needed).
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var enabled = false
    @Published private(set) var needsApproval = false
    @Published var error: String?

    /// Login items point at the app's location, so they only make sense from /Applications.
    var isInstalled: Bool {
        Bundle.main.bundlePath.hasPrefix("/Applications/")
    }

    init() {
        refresh()
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        enabled = status == .enabled
        needsApproval = status == .requiresApproval
    }

    func setEnabled(_ on: Bool) {
        error = nil
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
        if needsApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }
}
