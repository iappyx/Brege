import AppKit
import BregeCore
import UserNotifications

/// Shows mirrored phone notifications as native macOS notifications.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    var onAction: ((String, String, NotificationActKind) -> Void)?
    var onOpenURL: ((URL) -> Void)?
    /// Action and the phone the call is on.
    var onCallAction: ((CallActionKind, String?) -> Void)?
    var onHotspotConnect: ((String) -> Void)?
    /// Network fingerprint and whether to use Brêge there (network privacy plan).
    var onNetworkDecision: ((String, Bool) -> Void)?
    /// The network question itself was clicked: fingerprint and label.
    var onNetworkQuestionOpened: ((String, String) -> Void)?
    /// Missed call: (number, send a message instead of calling).
    /// Device id, number, and whether to write a message instead of calling.
    var onMissedCall: ((String, String, Bool) -> Void)?
    private static func callIdentifier(_ deviceId: String) -> String { "brege.call.incoming.\(deviceId)" }

    private let maxCategories = 64
    private var categoryOrder: [String] = []
    private var categories: [String: UNNotificationCategory] = [:]
    private var iconCache: [String: URL] = [:]

    /// UserNotifications crashes when the process is not a bundled app (e.g. `swift run`).
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func requestAuthorization() {
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, error in
            if let error { NSLog("Brêge: notification authorization failed: \(error)") }
        }
    }

    /// True when macOS will not show Brêge's banners (denied, or alert style set to None).
    func checkBlocked(_ completion: @escaping (Bool) -> Void) {
        guard let center else { return completion(false) }
        center.getNotificationSettings { settings in
            let blocked = settings.authorizationStatus == .denied
                || (settings.authorizationStatus == .authorized && settings.alertSetting == .disabled)
            DispatchQueue.main.async { completion(blocked) }
        }
    }

    static func openSettings() {
        let id = Bundle.main.bundleIdentifier ?? "app.brege.mac"
        let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")!
        NSWorkspace.shared.open(url)
    }

    func show(_ n: NotificationData, from deviceId: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = n.title.isEmpty ? n.appLabel : n.title
        content.subtitle = n.title.isEmpty ? "" : n.appLabel
        content.body = n.bigText.isEmpty ? n.text : n.bigText
        content.threadIdentifier = n.groupKey.isEmpty ? n.package : n.groupKey
        content.userInfo = ["device": deviceId, "key": n.key]
        content.sound = .default
        let code = detectVerificationCode(text: [n.title, n.text, n.bigText].joined(separator: "\n"))
        if let code {
            // Like macOS for codes in Messages: one click (or nothing, when copied automatically).
            content.categoryIdentifier = codeCategory()
            content.userInfo["code"] = code
            if AppSettings.copiesCodesAutomatically {
                Self.copy(code)
                content.subtitle = "Code \(code) copied — paste with ⌘V"
            } else {
                content.subtitle = "Code \(code)"
            }
        } else if !n.callNumber.isEmpty {
            // The phone's own buttons open screens on the phone; the Mac handles these itself.
            content.categoryIdentifier = missedCallCategory()
            content.userInfo["number"] = n.callNumber
        } else if !n.actions.isEmpty {
            content.categoryIdentifier = registerCategory(for: n.actions)
        }
        // The sender's photo is more useful than the app icon when the app provides one.
        let icon = storedIcon(ref: n.iconRef, png: n.iconPng)
        if let image = temporaryImage(n.senderIcon) ?? icon.flatMap(temporaryCopy),
           let attachment = attachment("icon", image) {
            content.attachments = [attachment]
        }
        let request = UNNotificationRequest(identifier: identifier(deviceId, n.key), content: content, trigger: nil)
        center.add(request)
    }

    func remove(key: String, from deviceId: String) {
        center?.removeDeliveredNotifications(withIdentifiers: [identifier(deviceId, key)])
    }

    func showOpenRequest(_ openRequest: OpenRequestData, from name: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        switch openRequest {
        case let .url(url, title):
            content.title = "Open link from \(name)"
            content.body = title.isEmpty ? url : "\(title)\n\(url)"
            content.userInfo = ["open": url]
            content.categoryIdentifier = "open.url"
        case let .unsafeUrl(url):
            content.title = "Link from \(name)"
            content.body = url
        case let .text(text):
            content.title = "Text from \(name)"
            content.body = text
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            ClipboardMonitor.markOwnWrite()
            content.subtitle = "Copied to clipboard"
        case .file:
            return
        }
        ensureOpenRequestCategory()
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Incoming call banner with Answer / Decline. Answering picks up on the phone.
    func showIncomingCall(_ call: CallData, deviceId: String, phoneName: String, photo: NSImage? = nil) {
        guard let center else { return }
        if categories["call.incoming"] == nil {
            categories["call.incoming"] = UNNotificationCategory(
                identifier: "call.incoming",
                actions: [
                    UNNotificationAction(identifier: "call.answer", title: "Answer on phone", options: []),
                    UNNotificationAction(identifier: "call.decline", title: "Decline", options: [.destructive]),
                ],
                intentIdentifiers: [], options: []
            )
            pushCategories()
        }
        let content = UNMutableNotificationContent()
        content.title = call.contactName.isEmpty ? (call.number.isEmpty ? "Unknown caller" : call.number) : call.contactName
        content.body = "Incoming call on \(phoneName)"
        content.categoryIdentifier = "call.incoming"
        content.userInfo = ["call": call.callId, "device": deviceId]
        content.interruptionLevel = .timeSensitive
        content.sound = .default
        if let png = photo?.pngData, let url = temporaryImage(png), let attachment = attachment("photo", url) {
            content.attachments = [attachment]
        }
        center.add(UNNotificationRequest(identifier: Self.callIdentifier(deviceId), content: content, trigger: nil))
    }

    func removeCall(deviceId: String) {
        center?.removeDeliveredNotifications(withIdentifiers: [Self.callIdentifier(deviceId)])
    }

    func showFileReceived(path: String, title: String = "File received") {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = (path as NSString).lastPathComponent
        content.userInfo = ["reveal": path]
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    private static func copy(_ code: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        ClipboardMonitor.markOwnWrite()
    }

    private func codeCategory() -> String {
        if categories["code"] == nil {
            categories["code"] = UNNotificationCategory(
                identifier: "code",
                actions: [UNNotificationAction(identifier: "code.copy", title: "Copy Code", options: [])],
                intentIdentifiers: [], options: [.customDismissAction]
            )
            pushCategories()
        }
        return "code"
    }

    private func missedCallCategory() -> String {
        if categories["missed.call"] == nil {
            categories["missed.call"] = UNNotificationCategory(
                identifier: "missed.call",
                actions: [
                    UNNotificationAction(identifier: "missed.call", title: "Call Back", options: []),
                    UNNotificationAction(identifier: "missed.message", title: "Message", options: [.foreground]),
                ],
                intentIdentifiers: [], options: [.customDismissAction]
            )
            pushCategories()
        }
        return "missed.call"
    }

    /// The Mac went offline: offer the phone's hotspot.
    func showHotspotOffer(deviceId: String, phoneName: String) {
        guard let center else { return }
        if categories["hotspot.offer"] == nil {
            categories["hotspot.offer"] = UNNotificationCategory(
                identifier: "hotspot.offer",
                actions: [UNNotificationAction(identifier: "hotspot.connect", title: "Use Hotspot", options: [])],
                intentIdentifiers: [], options: []
            )
            pushCategories()
        }
        let content = UNMutableNotificationContent()
        content.title = "No internet — use \(phoneName)'s hotspot?"
        content.body = "Brêge asks your phone to turn on its hotspot; tap the notification there."
        content.categoryIdentifier = "hotspot.offer"
        content.userInfo = ["hotspot": deviceId]
        center.add(UNNotificationRequest(identifier: "hotspot.offer", content: content, trigger: nil))
    }

    /// "Use Brêge on ‘Café’?" for a network Brêge does not know, while a phone is not connected.
    func showNetworkQuestion(fingerprint: String, label: String, phones: String) {
        guard let center else { return }
        if categories["network.question"] == nil {
            categories["network.question"] = UNNotificationCategory(
                identifier: "network.question",
                actions: [
                    UNNotificationAction(identifier: "network.use", title: "Use Here", options: []),
                    UNNotificationAction(identifier: "network.decline", title: "Not Here", options: []),
                ],
                intentIdentifiers: [], options: []
            )
            pushCategories()
        }
        let content = UNMutableNotificationContent()
        content.title = "Use Brêge on \(label)?"
        content.body = "\(phones) cannot connect on a network Brêge does not know. Choose Use Here only for networks you trust."
        content.categoryIdentifier = "network.question"
        content.userInfo = ["network": fingerprint, "label": label]
        center.add(UNNotificationRequest(identifier: "network.question", content: content, trigger: nil))
    }

    func removeNetworkQuestion() {
        center?.removeDeliveredNotifications(withIdentifiers: ["network.question"])
    }

    func showInfo(title: String, body: String) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        defer { completionHandler() }
        let info = response.notification.request.content.userInfo
        if let network = info["network"] as? String {
            switch response.actionIdentifier {
            case "network.use": onNetworkDecision?(network, true)
            case "network.decline": onNetworkDecision?(network, false)
            case UNNotificationDefaultActionIdentifier:
                onNetworkQuestionOpened?(network, info["label"] as? String ?? "this network")
            default: break
            }
            return
        }
        if let device = info["hotspot"] as? String {
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier || response.actionIdentifier == "hotspot.connect" {
                onHotspotConnect?(device)
            }
            return
        }
        if info["call"] != nil {
            switch response.actionIdentifier {
            case "call.answer": onCallAction?(.answer, info["device"] as? String)
            case "call.decline": onCallAction?(.decline, info["device"] as? String)
            default: break
            }
            return
        }
        if let url = (info["open"] as? String).flatMap(URL.init(string:)) {
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier || response.actionIdentifier == "open" {
                onOpenURL?(url)
            }
            return
        }
        if let path = info["reveal"] as? String {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            return
        }
        if let code = info["code"] as? String, response.actionIdentifier == "code.copy" {
            Self.copy(code)
            return
        }
        if let number = info["number"] as? String, let device = info["device"] as? String {
            switch response.actionIdentifier {
            case "missed.call": onMissedCall?(device, number, false)
            case "missed.message": onMissedCall?(device, number, true)
            default: break
            }
            if response.actionIdentifier != UNNotificationDefaultActionIdentifier,
               response.actionIdentifier != UNNotificationDismissActionIdentifier { return }
        }
        guard let device = info["device"] as? String, let key = info["key"] as? String else { return }
        let id = response.actionIdentifier
        if id == UNNotificationDismissActionIdentifier {
            onAction?(device, key, .dismiss)
        } else if id.hasPrefix("reply."), let index = UInt32(id.dropFirst(6)),
                  let text = (response as? UNTextInputNotificationResponse)?.userText {
            onAction?(device, key, .reply(index: index, text: text))
        } else if id.hasPrefix("action."), let index = UInt32(id.dropFirst(7)) {
            onAction?(device, key, .action(index: index))
        }
    }

    // MARK: Categories

    /// One category per distinct action set, LRU-capped.
    private func registerCategory(for actions: [NotificationActionData]) -> String {
        let signature = actions.map { "\($0.label)|\($0.acceptsReply)" }.joined(separator: ";")
        // Stable across launches (Swift's hashValue is randomized per process), so notifications
        // still in the notification list keep their buttons after Brêge restarts.
        let identifier = "phone.\(signature.utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) })"
        if categories[identifier] == nil {
            let unActions: [UNNotificationAction] = actions.enumerated().map { index, action in
                if action.acceptsReply {
                    return UNTextInputNotificationAction(identifier: "reply.\(index)", title: action.label,
                                                         options: [], textInputButtonTitle: "Send",
                                                         textInputPlaceholder: "Message")
                }
                return UNNotificationAction(identifier: "action.\(index)", title: action.label, options: [])
            }
            categories[identifier] = UNNotificationCategory(identifier: identifier, actions: unActions,
                                                            intentIdentifiers: [], options: [.customDismissAction])
        }
        categoryOrder.removeAll { $0 == identifier }
        categoryOrder.append(identifier)
        while categoryOrder.count > maxCategories {
            categories.removeValue(forKey: categoryOrder.removeFirst())
        }
        pushCategories()
        return identifier
    }

    private func ensureOpenRequestCategory() {
        guard categories["open.url"] == nil else { return }
        categories["open.url"] = UNNotificationCategory(
            identifier: "open.url",
            actions: [UNNotificationAction(identifier: "open", title: "Open", options: [.foreground])],
            intentIdentifiers: [], options: []
        )
        pushCategories()
    }

    private func pushCategories() {
        center?.setNotificationCategories(Set(categories.values))
    }

    private func identifier(_ device: String, _ key: String) -> String { "\(device)/\(key)" }

    private static let iconDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("BregeIcons", isDirectory: true)
    /// One-off attachment files, apart from the stored app icons so old ones can be removed.
    private static let attachmentDirectory = iconDirectory.appendingPathComponent("Attachments", isDirectory: true)
    private var lastAttachmentCleanup = Date.distantPast

    /// Writes a one-off image for an attachment (macOS moves attachment files into its store).
    private func temporaryImage(_ data: Data) -> URL? {
        guard !data.isEmpty, let url = newAttachmentURL() else { return nil }
        return (try? data.write(to: url)) != nil ? url : nil
    }

    private func temporaryCopy(of stored: URL) -> URL? {
        guard let copy = newAttachmentURL() else { return nil }
        return (try? FileManager.default.copyItem(at: stored, to: copy)) != nil ? copy : nil
    }

    private func newAttachmentURL() -> URL? {
        let dir = Self.attachmentDirectory
        // Files macOS did not take (a failed attachment) are removed after an hour.
        if Date().timeIntervalSince(lastAttachmentCleanup) > 3_600 {
            lastAttachmentCleanup = Date()
            let cutoff = Date().addingTimeInterval(-3_600)
            for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if modified < cutoff { try? FileManager.default.removeItem(at: file) }
            }
        }
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return nil }
        return dir.appendingPathComponent("\(UUID().uuidString).png")
    }

    private func attachment(_ identifier: String, _ url: URL) -> UNNotificationAttachment? {
        if let attachment = try? UNNotificationAttachment(identifier: identifier, url: url, options: nil) { return attachment }
        try? FileManager.default.removeItem(at: url)
        return nil
    }

    /// Icons arrive once per app; keep them on disk and attach a copy (attachments are moved).
    private func storedIcon(ref: String, png: Data) -> URL? {
        guard !ref.isEmpty else { return nil }
        let dir = Self.iconDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stored = dir.appendingPathComponent("\(ref).png")
        if !png.isEmpty { try? png.write(to: stored) }
        return FileManager.default.fileExists(atPath: stored.path) ? stored : nil
    }
}

private extension NSImage {
    var pngData: Data? {
        guard let tiff = tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}
