import AppKit
import BregeCore
import SwiftUI

/// The phone's installed apps on the Mac: how big, how long unused, and what each one is allowed to
/// interrupt you with. Uninstalling and opening settings happen on the phone, with its own
/// confirmation; the Mac only asks.
@MainActor
final class AppInventoryModel: ObservableObject {
    struct App: Identifiable, Equatable {
        let id: String // package
        let label: String
        let version: String
        let sizeBytes: UInt64
        let lastUsedMs: Int64
        let system: Bool
        let installedMs: Int64
        let icon: NSImage?
    }

    @Published private(set) var apps: [App] = []
    @Published private(set) var usageAccess = true
    @Published private(set) var loading = false
    @Published private(set) var settings: NotificationSettingsData?
    @Published var settingsFor: String?

    let deviceId: String
    private let node: () -> BregeNode?

    init(deviceId: String, node: @escaping () -> BregeNode?) {
        self.deviceId = deviceId
        self.node = node
    }

    func refresh(_ device: Device?) {
        guard device?.connected == true else { return }
        loading = true
        try? node()?.requestAppInventory(deviceId: deviceId, includeSystem: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.loading = false }
    }

    func received(_ apps: [InstalledAppData], usageAccess: Bool) {
        loading = false
        self.usageAccess = usageAccess
        self.apps = apps.map {
            App(id: $0.package, label: $0.label, version: $0.version, sizeBytes: $0.sizeBytes,
                lastUsedMs: $0.lastUsedMs, system: $0.system, installedMs: $0.installedMs,
                icon: $0.iconPng.isEmpty ? nil : NSImage(data: Data($0.iconPng)))
        }
    }

    func openNotificationSettings(_ package: String) {
        settingsFor = package
        settings = nil
        try? node()?.requestNotificationSettings(deviceId: deviceId, package: package)
    }

    func settingsReceived(_ settings: NotificationSettingsData) {
        guard settings.package == settingsFor else { return }
        self.settings = settings
    }

    func setImportance(_ importance: UInt32, channel: String, package: String) {
        try? node()?.updateNotificationChannel(deviceId: deviceId, package: package,
                                              channelId: channel, importance: importance)
    }

    func act(_ kind: AppActionKind, package: String) {
        try? node()?.sendAppAction(deviceId: deviceId, kind: kind, package: package)
    }
}

struct PhoneAppsInventoryView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: AppInventoryModel
    @State private var search = ""
    @State private var sort = Sort.size
    @State private var uninstalling: AppInventoryModel.App?

    enum Sort: String, CaseIterable, Identifiable {
        case size = "Size"
        case unused = "Longest unused"
        case name = "Name"
        var id: String { rawValue }
    }

    private var device: Device? { app.device(model.deviceId) }
    private var connected: Bool { device?.connected == true }

    private var apps: [AppInventoryModel.App] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = query.isEmpty ? model.apps
            : model.apps.filter { $0.label.lowercased().contains(query) || $0.id.lowercased().contains(query) }
        switch sort {
        case .size: return filtered.sorted { $0.sizeBytes > $1.sizeBytes }
        case .unused: return filtered.sorted { $0.lastUsedMs < $1.lastUsedMs }
        case .name: return filtered.sorted { $0.label.lowercased() < $1.label.lowercased() }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !model.usageAccess { usageHint }
            List {
                ForEach(apps) { item in
                    row(item)
                }
            }
        }
        .navigationTitle(device.map { "Apps — \($0.name)" } ?? "Apps")
        .searchable(text: $search, placement: .toolbar, prompt: "Search apps")
        .toolbar {
            ToolbarItemGroup {
                Picker("", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.rawValue).tag($0) }
                }
                .labelsHidden()
                .frame(width: 140)
                Button { model.refresh(device) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(!connected)
            }
        }
        .overlay {
            if model.apps.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2").font(.largeTitle).foregroundStyle(.secondary)
                    Text(model.loading ? "Asking the phone…" : connected ? "No apps yet" : "Phone not connected")
                        .font(.headline)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .onAppear { app.appsWindowOpened(deviceId: model.deviceId) }
        .sheet(isPresented: Binding(get: { model.settingsFor != nil }, set: { if !$0 { model.settingsFor = nil } })) {
            NotificationSettingsSheet(model: model)
        }
        .confirmationDialog(
            uninstalling.map { "Uninstall \($0.label)?" } ?? "",
            isPresented: Binding(get: { uninstalling != nil }, set: { if !$0 { uninstalling = nil } }),
            titleVisibility: .visible
        ) {
            Button("Ask on Phone", role: .destructive) {
                if let item = uninstalling { model.act(.uninstall, package: item.id) }
                uninstalling = nil
            }
            Button("Cancel", role: .cancel) { uninstalling = nil }
        } message: {
            Text("Your phone shows its own confirmation; nothing is removed until you agree there.")
        }
    }

    private var usageHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Sizes and “last used” are missing").font(.caption.weight(.medium))
                Text("The phone needs Usage access: Settings › Apps › Special app access › Usage access › Brêge.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Open on Phone") { model.act(.usageAccess, package: "app.brege") }
                .controlSize(.small)
                .help("Sends a notification to the phone that opens the Usage access screen")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.quaternary.opacity(0.4))
    }

    private func row(_ item: AppInventoryModel.App) -> some View {
        HStack(spacing: 10) {
            Group {
                if let icon = item.icon {
                    Image(nsImage: icon).resizable().scaledToFit()
                } else {
                    Image(systemName: "app.dashed").foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.label).lineLimit(1)
                Text(detail(item)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { model.openNotificationSettings(item.id) } label: { Image(systemName: "bell.badge") }
                .buttonStyle(.borderless)
                .help("What this app may interrupt you with")
                .disabled(!connected)
        }
        .padding(.vertical, 2)
        .contextMenu {
            Button("Notification Settings…") { model.openNotificationSettings(item.id) }
            Button("Open App Settings on Phone") { model.act(.appSettings, package: item.id) }
            Divider()
            Button("Uninstall…", role: .destructive) { uninstalling = item }
        }
        .disabled(!connected && model.apps.isEmpty)
    }

    private func detail(_ item: AppInventoryModel.App) -> String {
        var parts: [String] = []
        if item.sizeBytes > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: Int64(item.sizeBytes), countStyle: .file))
        }
        if item.lastUsedMs > 0 {
            let days = Int((Date().timeIntervalSince1970 * 1000 - Double(item.lastUsedMs)) / 86_400_000)
            parts.append(days <= 0 ? "used today" : days == 1 ? "used yesterday"
                : days < 60 ? "used \(days) days ago" : "unused for \(days / 30) months")
        }
        if !item.version.isEmpty { parts.append(item.version) }
        return parts.joined(separator: " · ")
    }
}

/// What one app may interrupt you with, changed from the Mac.
private struct NotificationSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppInventoryModel

    private static let levels: [(UInt32, String)] = [
        (0, "Off"), (1, "Silent"), (2, "Quiet"), (3, "Normal"), (4, "Loud"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.settings?.appLabel ?? "Notifications").font(.headline)
            if let settings = model.settings {
                if !settings.allowed {
                    Label("This phone does not let Brêge change these settings.", systemImage: "lock")
                        .font(.caption).foregroundStyle(.secondary)
                } else if settings.channels.isEmpty {
                    Text("This app has no notification categories.").font(.caption).foregroundStyle(.secondary)
                } else {
                    List(settings.channels, id: \.id) { channel in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(channel.name).lineLimit(1)
                                if !channel.group.isEmpty {
                                    Text(channel.group).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Picker("", selection: Binding(
                                get: { channel.importance },
                                set: { model.setImportance($0, channel: channel.id, package: settings.package) }
                            )) {
                                ForEach(Self.levels, id: \.0) { Text($0.1).tag($0.0) }
                            }
                            .labelsHidden()
                            .frame(width: 100)
                        }
                    }
                    .frame(minHeight: 200)
                }
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            }
            HStack {
                if let settings = model.settings, settings.allowed {
                    Button("Open on Phone") { model.act(.notificationSettings, package: settings.package) }
                        .controlSize(.small)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}
