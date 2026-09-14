import BregeCore
import SwiftUI

@main
struct BregeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(model)
        } label: {
            MenuBarLabel(status: model.primaryStatus, connected: model.anyConnected, live: model.live)
        }
        .menuBarExtraStyle(.window)

        WindowGroup("Messages", id: "messages", for: String.self) { $deviceId in
            if let deviceId {
                MessagesView(model: model.messages(for: deviceId))
                    .environmentObject(model)
            }
        }
        .defaultSize(width: 900, height: 620)

        WindowGroup("Phone Screen", id: "screen", for: ScreenTarget.self) { $target in
            if let target {
                PhoneScreenWindow(target: target)
                    .environmentObject(model)
            }
        }
        .defaultSize(width: 420, height: 880)

        WindowGroup("Phone Apps", id: "phone-apps", for: String.self) { $deviceId in
            if let deviceId {
                PhoneAppsWindow(deviceId: deviceId)
                    .environmentObject(model)
            }
        }
        .defaultSize(width: 520, height: 560)

        WindowGroup("Phone Camera", id: "phone-camera", for: String.self) { $deviceId in
            if let deviceId {
                PhoneCameraWindow(camera: model.camera(for: deviceId))
                    .environmentObject(model)
            }
        }
        .defaultSize(width: 640, height: 480)

        Window("Acknowledgements", id: "acknowledgements") {
            AcknowledgementsView()
        }
        .defaultSize(width: 820, height: 560)

        Window("Pair a Phone", id: "pairing") {
            PairingView()
                .environmentObject(model)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let services = CaptureServicesProvider()
    /// Another Brêge was already running at launch; this one only hands over and quits.
    private var isDuplicate = false

    /// A Brêge with the same bundle id other than this process.
    static func otherInstance() -> NSRunningApplication? {
        guard let bundleId = Bundle.main.bundleIdentifier else { return nil }
        let current = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .first { $0.processIdentifier != current && !$0.isTerminated }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Screenshots.isActive {
            // README images with made-up data: no core, no Keychain, no networks.
            DispatchQueue.main.async { Screenshots.run() }
            return
        }
        // Two instances would share the database and identity: keep the one already running. An
        // instance that is still quitting (e.g. just after an update) is not a duplicate, so wait
        // for it briefly before deciding.
        if Self.otherInstance() != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
                guard let other = Self.otherInstance() else { return launch() }
                isDuplicate = true
                other.activate(options: [])
                NSApp.terminate(nil)
                // terminate is not always honoured this early; never keep a second, idle instance.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { exit(0) }
            }
            return
        }
        launch()
    }

    @MainActor private func launch() {
        NSApp.servicesProvider = services
        PhoneCapture.cleanCache()
        NSUpdateDynamicServices()
        Task { @MainActor in
            await AppModel.shared.start()
        }
    }

    /// Phone camera recordings are finished (written out) before Brêge quits.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isDuplicate, !Screenshots.isActive, PhoneCameraModel.isRecordingAny else { return .terminateNow }
        PhoneCameraModel.finishAllRecordings {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !Screenshots.isActive, !isDuplicate else { return }
        AppModel.shared.stopSync()
        ScreenSession.restoreAllDesktopDisplays()
    }
}

private struct MenuBarLabel: View {
    let status: StatusData?
    let connected: Bool
    @ObservedObject var live: OngoingActivitiesModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        content.onAppear { AppModel.shared.openWindowAction = openWindow }
    }

    @ViewBuilder
    private var content: some View {
        if live.showInMenuBar, connected, let item = live.latest {
            // A running ongoing activity sits next to the battery.
            Image(systemName: live.symbol(item.data))
            Text(status.map { "\(live.compactText(item.data))  \($0.batteryPct)%" } ?? live.compactText(item.data))
        } else {
            batteryLabel
        }
    }

    @ViewBuilder
    private var batteryLabel: some View {
        if let status, connected {
            Image(systemName: batterySymbol(status))
            Text("\(status.batteryPct)%")
        } else {
            Image(systemName: connected ? "iphone.gen3" : "iphone.gen3.slash")
        }
    }

    private func batterySymbol(_ s: StatusData) -> String {
        if s.charging { return "battery.100percent.bolt" }
        switch s.batteryPct {
        case 0..<13: return "battery.0percent"
        case 13..<38: return "battery.25percent"
        case 38..<63: return "battery.50percent"
        case 63..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}
