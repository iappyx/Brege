import BregeCore
import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = model.startupError {
                Warning(symbol: "exclamationmark.triangle", tint: .red, title: "Brêge could not start", detail: error)
            }
            if model.localNetworkDenied {
                Warning(symbol: "network.slash", tint: .red, title: "Local Network access is off",
                        detail: "Your phone can only connect through a VPN.",
                        action: ("Open Settings", BonjourAdvertiser.openLocalNetworkSettings))
            }
            if model.notificationsBlocked {
                Warning(symbol: "bell.slash", tint: .orange, title: "Notifications are off for Brêge",
                        detail: "Phone notifications appear without banners or Reply.",
                        action: ("Open Settings", NotificationPresenter.openSettings))
            }

            NetworkPrompts()
            if model.devices.isEmpty {
                NoPhoneView()
            }
            ForEach(Array(model.devices.enumerated()), id: \.element.id) { index, device in
                if index > 0 { Divider() }
                // One settings button for the whole menu, on the first phone.
                DeviceCard(device: device, showsSettings: index == 0)
            }

            OngoingActivitiesSection(live: model.live)

            // Photos and captures show their own progress; this list is for files you send.
            let transfers = model.transfers.filter { !model.capture.ownTransfers.contains($0.id) }
            if !transfers.isEmpty {
                Section {
                    ForEach(transfers.prefix(3)) { TransferRow(transfer: $0) }
                } header: {
                    SectionHeader("Transfers")
                }
            }

            // Mac notifications already show phone notifications, with Reply; the list is only a
            // fallback when banners are turned off for Brêge.
            if model.notificationsBlocked, !model.notifications.isEmpty {
                Section {
                    ForEach(model.notifications.prefix(3), id: \.key) { n in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(n.title.isEmpty ? n.appLabel : "\(n.appLabel) · \(n.title)")
                                .font(.caption.weight(.medium)).lineLimit(1)
                            Text(n.text).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .opacity(n.dismissed ? 0.5 : 1)
                    }
                } header: {
                    SectionHeader("Notifications")
                }
            }
        }
        .padding(14)
        .frame(width: 340)
        .onAppear {
            model.openWindowAction = openWindow
            model.refresh()
            for device in model.devices where device.connected { model.recentPhotos(for: device.id).refresh(device) }
            model.hotspot.refreshKnownNetworks()
        }
    }
}

private struct SectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 2)
    }
}

private struct Warning: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    var action: (String, () -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let action {
                Button(action.0, action: action.1).controlSize(.small)
            }
        }
        .padding(8)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Asks before using a network or VPN Brêge does not know yet (network privacy plan).
private struct NetworkPrompts: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let disconnected = model.devices.filter { !$0.connected }
        if !disconnected.isEmpty {
            ForEach(model.networkPaths.filter { $0.isVpn && !$0.trusted && !$0.declined && !$0.blockedDeviceIds.isEmpty }, id: \.fingerprint) { path in
                VPNPrompt(path: path, names: names(path.blockedDeviceIds))
            }
            if let lan = model.networkPaths.first(where: { !$0.isVpn && !$0.trusted && !$0.declined }) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "network.badge.shield.half.filled").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 6) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Use Brêge on \(lan.label)?").font(.caption.weight(.semibold))
                                .fixedSize(horizontal: false, vertical: true)
                            Text("Brêge stays silent on networks it does not know, so phones cannot connect here.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        HStack {
                            Button("Not Here") { model.decideNetwork(lan.fingerprint, use: false) }.controlSize(.small)
                            Button("Use Here") { model.decideNetwork(lan.fingerprint, use: true) }.controlSize(.small)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(8)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func names(_ ids: [String]) -> String {
        let names = model.devices.filter { ids.contains($0.id) }.map(\.name)
        return names.isEmpty ? "your phone" : ListFormatter.localizedString(byJoining: names)
    }
}

private struct VPNPrompt: View {
    @EnvironmentObject private var model: AppModel
    let path: NetworkPathData
    let names: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "lock.shield").foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Use this VPN to reach \(names)?").font(.caption.weight(.semibold))
                Text(path.label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Never") { model.decideNetwork(path.fingerprint, use: false) }.controlSize(.small)
                .help("Do not use this VPN for Brêge")
            Button("Once") { model.allowNetworkOnce(path.fingerprint) }.controlSize(.small)
                .help("Use it until Brêge quits")
            Button("Always") { model.trustNetwork(path.fingerprint) }.controlSize(.small)
                .help("Remember this VPN")
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct NoPhoneView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Brêge").font(.headline)
                Spacer()
                SettingsMenu()
            }
            Image(systemName: "iphone.gen3.badge.plus").font(.system(size: 36)).foregroundStyle(.secondary)
            Text("Pair your Android phone to get started.").font(.callout).foregroundStyle(.secondary)
            Button("Pair a Phone…") {
                openWindow(id: "pairing")
                NSApp.activate(ignoringOtherApps: true)
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The ⚙ menu: everything that is not a daily action.
private struct SettingsMenu: View {
    @Environment(\.openWindow) private var openWindow
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Menu {
            Button("Settings…") { SettingsOpener.open() }
            Button("Notification History…") {
                openWindow(id: "notification-history")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Pair a Phone…") {
                openWindow(id: "pairing")
                NSApp.activate(ignoringOtherApps: true)
            }
            Divider()
            Button("Quit Brêge") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "gearshape")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct DeviceCard: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    let device: Device
    var showsSettings = true

    private func open(_ id: String, _ value: some Codable & Hashable) {
        model.used(device.id)
        openWindow(id: id, value: value)
        NSApp.activate(ignoringOtherApps: true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            ActivityRows(device: device)
            tiles
            if model.controlsOpenFor == device.id {
                PhoneControlsPanel(device: device)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)),
                                            removal: .opacity))
            }
            if model.conditionsOpenFor == device.id {
                ConditionsCard(device: device, conditions: model.conditions(for: device.id))
                    .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)),
                                            removal: .opacity))
            }
            RecentPhotosStrip(photos: model.recentPhotos(for: device.id), device: device)
            if device.connected, let media = model.media[device.id], !media.title.isEmpty {
                mediaRow(media)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard device.connected else { return false }
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in model.send(file: url, to: device) }
                }
            }
            return true
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: device.connected ? "iphone.gen3" : "iphone.gen3.slash")
                .font(.title2)
                .foregroundStyle(device.connected ? .primary : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if showsSettings { SettingsMenu() }
        }
    }

    private var tiles: some View {
        let connected = device.connected
        let micOn = model.micDevice == device.id
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)
        return LazyVGrid(columns: columns, spacing: 6) {
            let unread = model.unreadMessages[device.id] ?? 0
            Tile("Messages", symbol: unread > 0 ? "message.badge.filled.fill" : "message",
                 help: "Read and send the phone's text messages, and make calls, in a window on this Mac",
                 badge: unread) { open("messages", device.id) }
            let missed = model.missedCalls[device.id] ?? 0
            Tile("Calls", symbol: missed > 0 ? "phone.badge.waveform.fill" : "phone",
                 help: "Recent calls of this phone, with a keypad to dial any number",
                 badge: missed) { model.openCalls(deviceId: device.id) }
            Tile("Screen", symbol: "iphone.gen3.radiowaves.left.and.right",
                 help: "See and control the phone's screen on this Mac (needs wireless debugging)",
                 enabled: connected) { open("screen", ScreenTarget(deviceId: device.id)) }
            MenuTile("Apps", symbol: "square.grid.3x3",
                     help: "Open a phone app in a window (needs wireless debugging), or see what is installed",
                     enabled: connected) {
                Button("Open App…") { open("phone-apps", device.id) }
                Button("Installed Apps…") { model.openAppInventory(deviceId: device.id) }
            }
            Tile("Send Tab", symbol: "safari",
                 help: "Open the page from Safari, Chrome, Edge, Brave or Arc on the phone (or a link you copied)",
                 enabled: connected) { model.sendTab(to: device) }
            MenuTile("Camera", symbol: "camera",
                     help: "Take a photo or scan a document into this Mac, or use the phone camera live and record video",
                     enabled: connected) {
                Button("Take Photo") { model.used(device.id); model.capture.start(.photo, device: device, delivery: .clipboard) }
                Button("Scan Document") { model.used(device.id); model.capture.start(.document, device: device, delivery: .clipboard) }
                Divider()
                Button("Live Camera…") { open("phone-camera", device.id) }
                Button("Photo Library…") { model.openPhotos(deviceId: device.id) }
            }
            MenuTile("Files", symbol: "folder",
                     help: "Browse the phone's shared folders in Finder, or send files to the phone",
                     enabled: connected) {
                Button(model.openingDrives.contains(device.id) ? "Opening…" : "Show in Finder") { model.openPhoneInFinder(device) }
                    .disabled(model.openingDrives.contains(device.id))
                Button("Send Files…") { model.sendFiles(to: device) }
            }
            ControlsTile(device: device)
            ConditionsTile(device: device)
            Tile("Microphone", symbol: micOn ? "mic.fill" : "mic",
                 help: micOn ? "Stop using the phone as this Mac's microphone"
                     : "Use the phone as a microphone on this Mac (appears as “Brêge Microphone”)",
                 active: micOn, enabled: connected || micOn) {
                model.toggleMicrophone(device)
            }
            HotspotTile(device: device, hotspot: model.hotspot)
        }
    }

    private func mediaRow(_ media: MediaData) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(media.title).font(.caption.weight(.medium)).lineLimit(1)
                Text(media.artist.isEmpty ? media.appLabel : media.artist)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Group {
                Button { model.mediaCommand(device, .mediaPrevious) } label: { Image(systemName: "backward.fill") }
                Button { model.mediaCommand(device, .mediaPlayPause) } label: {
                    Image(systemName: media.playing ? "pause.fill" : "play.fill")
                }
                Button { model.mediaCommand(device, .mediaNext) } label: { Image(systemName: "forward.fill") }
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var subtitle: String {
        guard device.connected else { return "Not connected" }
        guard let s = model.statuses[device.id] else { return "Connected" }
        var parts = ["\(s.batteryPct)%\(s.charging ? " charging" : "")"]
        if !s.networkType.isEmpty { parts.append(s.networkType) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Tiles

private struct TileLabel: View {
    let title: String
    let symbol: String
    var active = false
    var badge = 0

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 16))
                .frame(height: 20)
                .overlay(alignment: .topTrailing) {
                    if badge > 0 {
                        Text("\(badge)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 4).background(.red, in: Capsule()).offset(x: 10, y: -6)
                    }
                }
            Text(title).font(.system(size: 11)).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, minHeight: 54)
        .foregroundStyle(active ? Color.white : Color.primary)
        .background(active ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary.opacity(0.6)),
                    in: RoundedRectangle(cornerRadius: 9))
        .contentShape(RoundedRectangle(cornerRadius: 9))
    }
}

/// Phone controls: torch, sound, Do Not Disturb and what the phone reports. The panel opens inside
/// the menu, because a popover would close this window before the buttons act.
/// Air pressure, room light and how warm the phone runs — folded away until asked for.
private struct ConditionsTile: View {
    @EnvironmentObject private var model: AppModel
    let device: Device

    var body: some View {
        Tile("Conditions", symbol: "barometer",
             help: "What the phone's sensors say: air pressure and the weather trend, room light, warmth",
             active: model.conditionsOpenFor == device.id,
             enabled: device.connected) {
            withAnimation(.easeOut(duration: 0.18)) { model.toggleConditions(device) }
        }
    }
}

private struct ControlsTile: View {
    @EnvironmentObject private var model: AppModel
    let device: Device

    var body: some View {
        Tile("Controls", symbol: "slider.horizontal.3",
             help: "Ring the phone, and change its torch, sound and Do Not Disturb from here",
             active: model.controlsOpenFor == device.id || model.phoneControls[device.id]?.torchOn == true,
             enabled: device.connected) {
            withAnimation(.easeOut(duration: 0.18)) { model.toggleControls(device) }
        }
    }
}

private struct Tile: View {
    let title: String
    let symbol: String
    let help: String
    var active = false
    var badge = 0
    var enabled = true
    let action: () -> Void

    init(_ title: String, symbol: String, help: String, active: Bool = false, badge: Int = 0, enabled: Bool = true,
         action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.help = help
        self.active = active
        self.badge = badge
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            TileLabel(title: title, symbol: symbol, active: active, badge: badge)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(help)
    }
}

private struct MenuTile<Content: View>: View {
    let title: String
    let symbol: String
    let help: String
    let enabled: Bool
    @ViewBuilder let content: () -> Content

    init(_ title: String, symbol: String, help: String, enabled: Bool, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.symbol = symbol
        self.help = help
        self.enabled = enabled
        self.content = content
    }

    var body: some View {
        Menu(content: content) {
            TileLabel(title: title, symbol: symbol)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .help(help)
    }
}

/// Works without a connection: that is when the Mac needs the hotspot.
private struct HotspotTile: View {
    let device: Device
    @ObservedObject var hotspot: PhoneHotspot
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let requesting = hotspot.isRequesting(for: device.id)
        Tile(requesting ? "Cancel" : "Hotspot", symbol: "antenna.radiowaves.left.and.right",
             help: requesting ? "Stop asking the phone for its hotspot"
                 : hotspot.ssid(for: device.id) == nil ? "Set up the phone's hotspot network in Settings"
                 : "Ask the phone to turn on its hotspot and connect this Mac to it",
             active: requesting) {
            if requesting {
                hotspot.cancel()
            } else if hotspot.ssid(for: device.id) == nil {
                SettingsOpener.open()
            } else {
                hotspot.connect(device)
            }
        }
    }
}

// MARK: - Activity

/// One line per thing in progress (call, microphone, capture, hotspot); nothing when idle.
private struct ActivityRows: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var capture: PhoneCapture
    @ObservedObject var hotspot: PhoneHotspot
    let device: Device

    init(device: Device) {
        self.device = device
        _capture = ObservedObject(wrappedValue: AppModel.shared.capture)
        _hotspot = ObservedObject(wrappedValue: AppModel.shared.hotspot)
    }

    var body: some View {
        VStack(spacing: 6) {
            if let call = model.activeCall, call.deviceId == device.id {
                ActivityRow(symbol: "phone.fill", tint: .green,
                            text: call.call.contactName.isEmpty ? "On a call" : call.call.contactName)
            }
            if model.micDevice == device.id {
                ActivityRow(symbol: "mic.fill", tint: .accentColor, text: model.micStatus ?? "Microphone on",
                            actionTitle: "Stop") { model.stopMicrophone() }
            }
            if let status = capture.statuses[device.id] {
                ActivityRow(symbol: "camera", tint: .accentColor, text: status, actionTitle: "Cancel") {
                    capture.cancel(deviceId: device.id)
                }
            }
            if let status = hotspot.status, hotspot.isRequesting(for: device.id) {
                ActivityRow(symbol: "antenna.radiowaves.left.and.right", tint: .accentColor, text: status, actionTitle: "Cancel") { hotspot.cancel() }
            }
        }
    }
}

private struct ActivityRow: View {
    let symbol: String
    let tint: Color
    let text: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.caption).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let actionTitle, let action {
                Button(actionTitle, action: action).controlSize(.small)
            }
        }
        .padding(8)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct TransferRow: View {
    let transfer: AppModel.Transfer

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: transfer.incoming ? "arrow.down.circle" : "arrow.up.circle")
                Text(transfer.name).font(.caption).lineLimit(1)
                Spacer()
                if let failed = transfer.failed {
                    Image(systemName: "exclamationmark.triangle").help(failed)
                } else if transfer.done {
                    Image(systemName: "checkmark.circle").foregroundStyle(.green)
                }
            }
            if !transfer.done, transfer.failed == nil, transfer.total > 0 {
                ProgressView(value: Double(transfer.bytes), total: Double(transfer.total))
                    .controlSize(.mini)
            }
        }
    }
}

struct PairingView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 16) {
            Text("Pair a phone").font(.title2.weight(.semibold))
            Text("Open Brêge on your Android phone and scan this code. Keep this window open until the phone is paired; the code works once and expires in 5 minutes.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(width: 320)
            if let name = model.justPaired {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.green)
                    Text("Paired with \(name)").font(.headline)
                }
                .frame(width: 280, height: 280)
            } else if let uri = model.inviteURI, let image = QRCode.image(for: uri, size: 280) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .frame(width: 280, height: 280)
                    .padding(8)
                    .background(.white, in: RoundedRectangle(cornerRadius: 12))
                Text("Reachable at: \(LocalAddresses.ipv4().joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DisclosureGroup("Can’t scan?") {
                    Text(uri).font(.caption.monospaced()).textSelection(.enabled).frame(width: 300)
                }
                .frame(width: 320)
            } else {
                ProgressView().frame(width: 280, height: 280)
            }
        }
        .padding(24)
        .onAppear { model.beginPairing() }
        .onDisappear { model.endPairing() }
    }
}
