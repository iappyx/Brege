import AppKit
import BregeCore

/// Services menu entries per paired phone ("Take Photo with <phone name>"). Titles in an app's
/// Info.plist are fixed, so Brêge writes the entries into a service bundle in ~/Library/Services
/// from the `BregeServices` templates, each with its phone's id as user data. macOS delivers them
/// to that bundle's own process, the Brêge Phones helper, which passes them on to Brêge
/// (`CaptureServicesProvider`).
@MainActor
enum ServicesMenu {
    static let bundleURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Services/Brêge Phones.service", isDirectory: true)

    private static var infoURL: URL { bundleURL.appendingPathComponent("Contents/Info.plist") }
    private static var helperURL: URL { bundleURL.appendingPathComponent("Contents/MacOS/BregeServices") }
    private static let helperSource = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/BregeServices")

    /// Rewrites the entries when the paired phones or their names change.
    static func update(devices: [Device]) {
        let templates = Bundle.main.object(forInfoDictionaryKey: "BregeServices") as? [[String: Any]] ?? []
        guard !devices.isEmpty, !templates.isEmpty else {
            if FileManager.default.fileExists(atPath: bundleURL.path) {
                try? FileManager.default.removeItem(at: bundleURL)
                NSUpdateDynamicServices()
            }
            return
        }
        var entries: [[String: Any]] = []
        for device in devices.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            // A slash would turn the title into a submenu.
            let name = device.name.replacingOccurrences(of: "/", with: "-")
            for template in templates {
                var entry = template
                if let title = (template["NSMenuItem"] as? [String: String])?["default"] {
                    entry["NSMenuItem"] = ["default": title.replacingOccurrences(of: "with Phone", with: "with \(name)")]
                }
                entry["NSPortName"] = "Brêge Phones"
                entry["NSUserData"] = device.id
                entries.append(entry)
            }
        }
        let info: [String: Any] = [
            "CFBundleIdentifier": "app.brege.mac.phone-services",
            "CFBundleName": "Brêge Phones",
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": "BregeServices",
            "LSBackgroundOnly": true,
            "NSServices": entries,
        ]
        guard let data = try? PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0),
              let helper = try? Data(contentsOf: helperSource) else { return }
        let fileManager = FileManager.default
        guard data != (try? Data(contentsOf: infoURL)) || helper != (try? Data(contentsOf: helperURL)) else { return }
        do {
            try fileManager.createDirectory(at: helperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try helper.write(to: helperURL, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helperURL.path)
            try data.write(to: infoURL, options: .atomic)
            NSUpdateDynamicServices()
        } catch {
            NSLog("Brêge: could not write the Services entries: \(error)")
        }
    }
}
