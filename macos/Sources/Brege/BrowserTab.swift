import AppKit

/// "Send Tab": the page open in the browser you were just using. Safari and Chromium browsers
/// answer AppleScript; Firefox has no AppleScript support (Mozilla bugs 125419, 516502) and has
/// its own Send Tab to Device, so it falls back to a copied link.
@MainActor
final class BrowserTab {
    struct Tab {
        let url: String
        let title: String
    }

    enum Failure: Error {
        case noTab
        case notAllowed(browser: String)
    }

    private static let safari: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
    private static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "com.microsoft.edgemac",
        "com.brave.Browser", "company.thebrowser.Browser", "com.vivaldi.Vivaldi", "com.operasoftware.Opera",
    ]

    /// Apps in the order they were last active, most recent first (Brêge itself excluded).
    private var recentApps: [String] = []

    init() {
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier { note(front) }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard let id = app?.bundleIdentifier else { return }
            MainActor.assumeIsolated { self?.note(id) }
        }
    }

    private func note(_ bundleId: String) {
        guard bundleId != Bundle.main.bundleIdentifier else { return }
        recentApps.removeAll { $0 == bundleId }
        recentApps.insert(bundleId, at: 0)
        if recentApps.count > 20 { recentApps.removeLast() }
    }

    /// The front tab of the most recently used scriptable browser that is still running, else a
    /// link on the clipboard.
    func currentTab() -> Result<Tab, Failure> {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        if let browser = recentApps.first(where: { (Self.safari.contains($0) || Self.chromium.contains($0)) && running.contains($0) }) {
            let tab = Self.safari.contains(browser) ? "current tab of front window" : "active tab of front window"
            let title = Self.safari.contains(browser) ? "name" : "title"
            let source = "tell application id \"\(browser)\" to if (count of windows) > 0 then return {URL of \(tab), \(title) of \(tab)}"
            var error: NSDictionary?
            let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
            if let error {
                // -1743: the user has not allowed Brêge to control this browser.
                if (error[NSAppleScript.errorNumber] as? Int) == -1743 {
                    let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: browser)
                        .map { FileManager.default.displayName(atPath: $0.path) } ?? "the browser"
                    return .failure(.notAllowed(browser: name.replacingOccurrences(of: ".app", with: "")))
                }
            } else if let result, result.numberOfItems == 2,
                      let url = result.atIndex(1)?.stringValue, url.hasPrefix("http") {
                return .success(Tab(url: url, title: result.atIndex(2)?.stringValue ?? ""))
            }
        }
        if let string = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           let url = URL(string: string), url.scheme?.hasPrefix("http") == true {
            return .success(Tab(url: url.absoluteString, title: ""))
        }
        return .failure(.noTab)
    }
}
