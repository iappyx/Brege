import BregeCore
import SwiftUI

/// Keeps the window title on the selected tab's name, as in System apps.
private final class SettingsTabs: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        // The controller resets the title while it resizes the window: set it afterwards.
        let title = tabViewItem?.label ?? "Settings"
        DispatchQueue.main.async { [weak self] in self?.view.window?.title = title }
    }
}

/// Brêge Settings: a standard macOS settings window with toolbar tabs, built with AppKit so it
/// opens reliably from a menu-bar app (SwiftUI's Settings scene cannot be opened from outside a
/// view on macOS 14+).
@MainActor
enum SettingsOpener {
    private static var controller: NSWindowController?

    static func open() {
        if controller == nil {
            controller = NSWindowController(window: makeWindow())
        }
        NSApp.activate(ignoringOtherApps: true)
        controller?.showWindow(nil)
        controller?.window?.makeKeyAndOrderFront(nil)
    }

    /// The Settings window, also used for the README screenshots (`Screenshots`).
    static func makeWindow(tab: Int = 0) -> NSWindow {
        let tabs = SettingsTabs()
        tabs.tabStyle = .toolbar
        tabs.transitionOptions = [.allowUserInteraction]
        func add(_ title: String, _ symbol: String, _ view: some View) {
            let host = NSHostingController(rootView: view.environmentObject(AppModel.shared).frame(width: 540))
            host.sizingOptions = [.preferredContentSize]
            let item = NSTabViewItem(viewController: host)
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        add("General", "gearshape", GeneralSettings())
        add("Phones", "iphone.gen3", PhoneSettings())
        add("Notifications", "bell.badge", NotificationSettings())
        add("Calls & Audio", "phone", CallsSettings())
        add("About", "info.circle", AboutSettings())

        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        tabs.selectedTabViewItemIndex = tab
        window.title = tabs.tabViewItems[tab].label
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @StateObject private var loginItem = LoginItem()
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var live = AppModel.shared.live

    var body: some View {
        Form {
            Section {
                Toggle("Start Brêge at login", isOn: Binding(
                    get: { loginItem.enabled || loginItem.needsApproval },
                    set: { loginItem.setEnabled($0) }
                ))
                .disabled(!loginItem.isInstalled)
            } footer: {
                if !loginItem.isInstalled {
                    Caption("Available when Brêge is in the Applications folder.")
                } else if loginItem.needsApproval {
                    Caption("Allow Brêge in System Settings › General › Login Items.")
                } else if let error = loginItem.error {
                    Caption(error)
                }
            }

            Section("Menu Bar") {
                Toggle("Show ongoing activities next to the battery", isOn: $live.showInMenuBar)
                Toggle("Show recent photos in the menu", isOn: $settings.showRecentPhotos)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { loginItem.refresh() }
    }
}

// MARK: - Phones

private struct PhoneSettings: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var hotspot = AppModel.shared.hotspot

    var body: some View {
        Form {
            if model.devices.isEmpty {
                Section {
                    ContentUnavailable(symbol: "iphone.gen3.badge.plus", title: "No phone paired",
                                       detail: "Open Brêge on your Android phone and scan the pairing code.")
                }
            }
            ForEach(model.devices, id: \.id) { device in
                PhoneSection(device: device, hotspot: hotspot)
            }
            if !model.devices.isEmpty {
                Section {
                    if model.knownNetworks.isEmpty {
                        Text("None yet. The network you pair on is added, and Brêge asks about others.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.knownNetworks, id: \.fingerprint) { network in
                        LabeledContent {
                            Button("Forget") { model.forgetNetwork(network.fingerprint) }
                                .help(network.trusted ? "Stop using this network; Brêge asks again next time" : "Brêge asks again next time")
                        } label: {
                            Label(network.label, systemImage: network.isVpn ? "lock.shield" : network.trusted ? "wifi" : "wifi.slash")
                            if !network.trusted { Text("Not used") }
                        }
                    }
                } header: {
                    Text("Networks")
                } footer: {
                    Caption("Brêge only announces itself, connects and answers on the networks and VPNs you use it on. Elsewhere it stays silent, so others on the network cannot see it. Location access lets Brêge show Wi‑Fi names.")
                }
            }
            Section {
                LabeledContent("Add another phone") {
                    Button("Pair a Phone…") {
                        model.openWindowAction?(id: "pairing")
                        NSApp.activate(ignoringOtherApps: true)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { if !Screenshots.isActive { hotspot.refreshKnownNetworks() } }
    }
}

private struct PhoneSection: View {
    @EnvironmentObject private var model: AppModel
    let device: Device
    @ObservedObject var hotspot: PhoneHotspot
    @ObservedObject private var location = AppModel.shared.hotspot.location
    @State private var confirmForget = false

    var body: some View {
        Section {
            HStack(spacing: 12) {
                Image(systemName: "iphone.gen3")
                    .font(.system(size: 28))
                    .foregroundStyle(device.connected ? Color.accentColor : .secondary)
                    .frame(width: 36)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name).font(.headline)
                    Text(status).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Forget…") { confirmForget = true }
            }
            .padding(.vertical, 4)

            Picker("Hotspot network", selection: Binding(
                get: { hotspot.ssid(for: device.id) ?? "" },
                set: { hotspot.setSSID($0.isEmpty ? nil : $0, for: device.id) }
            )) {
                Text("None").tag("")
                if !networks.isEmpty { Divider() }
                ForEach(networks, id: \.self) { Text($0).tag($0) }
            }
            if hotspot.ssid(for: device.id) != nil, !location.isAllowed {
                LabeledContent {
                    if location.isDenied {
                        Button("Open System Settings") { LocationAccess.openSettings() }
                    } else {
                        Button("Allow Location…") { location.requestIfNeeded() }
                    }
                } label: {
                    Text("Location access")
                    Text("macOS shows the Wi‑Fi network's name only to apps with Location access. Without it, Brêge notices the hotspot less reliably.")
                }
            }
        } footer: {
            Caption("To connect through the phone's hotspot, join it once from the Wi‑Fi menu and choose it here. Brêge then asks the phone to turn it on when you need it.")
        }
        .confirmationDialog("Forget \(device.name)?", isPresented: $confirmForget) {
            Button("Forget Phone", role: .destructive) { model.forget(device) }
        } message: {
            Text("Brêge on this Mac and the phone disconnect. Pair again to use them together.")
        }
    }

    private var status: String {
        guard device.connected else { return "Not connected" }
        guard let s = model.statuses[device.id] else { return "Connected" }
        return ["Connected", "\(s.batteryPct)% battery\(s.charging ? ", charging" : "")", s.networkType]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// The saved choice stays selectable even if macOS no longer lists it.
    private var networks: [String] {
        let saved = hotspot.ssid(for: device.id)
        return hotspot.knownNetworks + (saved.map { hotspot.knownNetworks.contains($0) ? [] : [$0] } ?? [])
    }
}

// MARK: - Notifications

private struct NotificationSettings: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Copy verification codes automatically", isOn: $settings.copyCodesAutomatically)
            } header: {
                Text("Verification Codes")
            } footer: {
                Caption("When a login code arrives on the phone, it is copied so you can paste it with ⌘V. The notification always offers Copy Code.")
            }

            Section {
                Toggle("Copy new screenshots to the clipboard", isOn: $settings.copyNewScreenshots)
            } header: {
                Text("Screenshots")
            } footer: {
                Caption("A screenshot taken on the phone lands on this Mac's clipboard, with a preview you can drag.")
            }

            Section("Phone Battery") {
                Toggle("Alert when the battery is low", isOn: $settings.lowBatteryAlert)
                Picker("Low battery level", selection: $settings.lowBatteryThreshold) {
                    ForEach([10, 15, 20, 30], id: \.self) { Text("\($0)%").tag($0) }
                }
                .disabled(!settings.lowBatteryAlert)
                Toggle("Alert when fully charged", isOn: $settings.fullBatteryAlert)
            }

            Section {
                LabeledContent("Mac notifications") {
                    HStack {
                        Text(model.notificationsBlocked ? "Off" : "On")
                            .foregroundStyle(model.notificationsBlocked ? .red : .secondary)
                        Button("Open System Settings…") { NotificationPresenter.openSettings() }
                    }
                }
            } footer: {
                Caption("Phone notifications, replies and these alerts appear as Mac notifications. Banner style and sounds are set in System Settings.")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Calls & Audio

private struct CallsSettings: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject private var settings = AppSettings.shared
    @State private var microphoneInstalled = PhoneMicrophone.isDriverInstalled

    var body: some View {
        Form {
            Section {
                Toggle("Pause music and video during phone calls", isOn: $settings.pauseAudioDuringCalls)
            } header: {
                Text("Calls")
            } footer: {
                Caption("Pauses Music, Spotify and TV while the phone rings or a call is active, and resumes them afterwards. macOS asks once for permission to control each app.")
            }

            Section {
                LabeledContent("Brêge Microphone") {
                    if microphoneInstalled {
                        Button("Remove…") {
                            model.uninstallMicrophone()
                            microphoneInstalled = PhoneMicrophone.isDriverInstalled
                        }
                    } else {
                        Text("Not installed").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Phone as Microphone")
            } footer: {
                Caption("The audio device is installed the first time you use the phone as a microphone.")
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { microphoneInstalled = PhoneMicrophone.isDriverInstalled }
    }
}

// MARK: - About

private struct AboutSettings: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingLicense = false

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return build.isEmpty ? "Version \(short)" : "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Brêge").font(.system(size: 22, weight: .semibold))
            Text(version).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Your Android phone and your Mac, together.")
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            HStack(spacing: 4) {
                Text("© 2026 iappyx")
                Text("·")
                Link("iappyx.github.io", destination: URL(string: "https://iappyx.github.io/")!)
            }
            .font(.callout)
            .padding(.top, 10)
            Text("Released under the MIT License.").font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("License") { showingLicense = true }
                Button("Acknowledgements") {
                    model.openWindowAction?(id: "acknowledgements")
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            .controlSize(.small)
            .padding(.top, 10)
        }
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showingLicense) {
            LicenseSheet(title: "MIT License", text: Self.bundledText("LICENSE"))
        }
    }

    static func bundledText(_ name: String) -> String {
        Bundle.main.url(forResource: name, withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
    }
}

private struct LicenseSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            ScrollView {
                Text(LicenseText.reflow(text)).font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 420)
    }
}

// MARK: - Helpers

private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

private struct ContentUnavailable: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(.secondary)
            Text(title).font(.headline)
            Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}
