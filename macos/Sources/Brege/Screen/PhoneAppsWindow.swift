import AppKit
import BregeCore
import SwiftUI

/// A launchable app on the phone, with its icon decoded once.
struct PhoneApp: Identifiable {
    let package: String
    let label: String
    let icon: NSImage?
    var id: String { package }
}

/// App launcher: opens a phone app in its own Mac window.
struct PhoneAppsWindow: View {
    let deviceId: String
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var search = ""

    private var apps: [PhoneApp] {
        let all = model.phoneApps[deviceId] ?? []
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return query.isEmpty ? all : all.filter { $0.label.lowercased().contains(query) || $0.package.contains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search apps", text: $search)
                .textFieldStyle(.roundedBorder)
                .padding(12)
            Divider()
            if model.phoneApps[deviceId] == nil {
                Spacer()
                ProgressView("Loading apps from the phone…")
                Spacer()
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], spacing: 12) {
                        ForEach(apps) { app in
                            Button { open(app) } label: { AppTile(app: app) }
                                .buttonStyle(.plain)
                                .help(app.package)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(minWidth: 360, minHeight: 360)
        .navigationTitle("Phone Apps")
        .toolbar {
            Button { model.requestPhoneApps(deviceId: deviceId, refresh: true) } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        }
        .onAppear { model.requestPhoneApps(deviceId: deviceId, refresh: false) }
    }

    private func open(_ app: PhoneApp) {
        openWindow(id: "screen", value: ScreenTarget(deviceId: deviceId, package: app.package, label: app.label))
        NSApp.activate(ignoringOtherApps: true)
    }
}

private struct AppTile: View {
    let app: PhoneApp

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 48, height: 48)
            Text(app.label)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 30, alignment: .top)
        }
        .frame(width: 88)
        .contentShape(Rectangle())
    }
}
