import AppKit

// Brêge Phones: answers the per-phone Services entries ("Take Photo with <phone name>").
// macOS delivers a service to the process of the bundle that declares it, and Brêge's own
// Info.plist cannot name phones, so this helper lives in the generated service bundle in
// ~/Library/Services. It passes each request, with the phone's id, on to Brêge through Brêge's
// relay entries, and hands the result back to the app that asked.

let deviceType = NSPasteboard.PasteboardType("app.brege.service-device")
let errorType = NSPasteboard.PasteboardType("app.brege.service-error")

final class Relay: NSObject {
    private var quitTimer: Timer?

    /// Launched on demand by the Services system; quits when no longer used.
    func scheduleQuit() {
        quitTimer?.invalidate()
        quitTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: false) { _ in NSApp.terminate(nil) }
    }

    @objc func takePhotoWithPhone(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        forward("Brêge Relay Take Photo", pasteboard, userData, error, returnsResult: true)
    }

    @objc func scanDocumentWithPhone(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        forward("Brêge Relay Scan Document", pasteboard, userData, error, returnsResult: true)
    }

    @objc func takePhotoWithPhoneIntoFolder(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        forward("Brêge Relay Take Photo into Folder", pasteboard, userData, error, returnsResult: false)
    }

    @objc func scanDocumentWithPhoneIntoFolder(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        forward("Brêge Relay Scan Document into Folder", pasteboard, userData, error, returnsResult: false)
    }

    private func forward(_ service: String, _ pasteboard: NSPasteboard, _ deviceId: String?,
                         _ error: AutoreleasingUnsafeMutablePointer<NSString?>, returnsResult: Bool) {
        quitTimer?.invalidate()
        defer { scheduleQuit() }
        let relay = NSPasteboard.withUniqueName()
        defer { relay.releaseGlobally() }

        let item = NSPasteboardItem()
        item.setString(deviceId ?? "", forType: deviceType)
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if let folder = urls.first { item.setString(folder.absoluteString, forType: .fileURL) }
        relay.clearContents()
        relay.writeObjects([item])

        let ok = NSPerformService(service, relay)
        // Brêge reports failures on the pasteboard; the call itself then counts as failed.
        if let message = relay.string(forType: errorType) {
            error.pointee = message as NSString
            return
        }
        guard ok else {
            error.pointee = "Brêge did not answer. Open Brêge and try again." as NSString
            return
        }
        guard returnsResult else { return }
        let types = (relay.types ?? []).filter { $0 != deviceType && $0 != errorType }
        guard !types.isEmpty else {
            error.pointee = "Nothing arrived from the phone." as NSString
            return
        }
        pasteboard.declareTypes(types, owner: nil)
        for type in types {
            if let data = relay.data(forType: type) { pasteboard.setData(data, forType: type) }
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let relay = Relay()
app.servicesProvider = relay
NSRegisterServicesProvider(relay, "Brêge Phones")
relay.scheduleQuit()
app.run()
