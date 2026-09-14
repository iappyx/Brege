import AppKit
import BregeCore
import SwiftUI

/// Ongoing activities: ongoing phone notifications (timers, navigation, deliveries …) in the menu
/// bar and the Brêge popover. Timers count locally.
@MainActor
final class OngoingActivitiesModel: ObservableObject {
    struct Item: Identifiable {
        let deviceId: String
        var data: OngoingActivityData
        var id: String { "\(deviceId)/\(data.key)" }
    }

    @Published private(set) var items: [Item] = []
    /// Advances every second while a timer is shown.
    @Published private(set) var now = Date()
    @Published var showInMenuBar = UserDefaults.standard.object(forKey: "showOngoingActivityInMenuBar") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showInMenuBar, forKey: "showOngoingActivityInMenuBar") }
    }

    private var icons: [String: NSImage] = [:] // item id → app icon (sent once)
    private var ticker: Timer?

    var latest: Item? { items.first }

    func updated(_ data: OngoingActivityData, from deviceId: String) {
        let item = Item(deviceId: deviceId, data: data)
        if !data.iconPng.isEmpty, let icon = NSImage(data: data.iconPng) { icons[item.id] = icon }
        items.removeAll { $0.id == item.id }
        items.insert(item, at: 0)
        updateTicker()
    }

    func ended(key: String, from deviceId: String) {
        items.removeAll { $0.deviceId == deviceId && $0.data.key == key }
        icons["\(deviceId)/\(key)"] = nil
        updateTicker()
    }

    /// The phone disconnected: its activities can no longer be trusted to be current.
    func clear(deviceId: String) {
        items.removeAll { $0.deviceId == deviceId }
        icons = icons.filter { !$0.key.hasPrefix("\(deviceId)/") }
        updateTicker()
    }

    func icon(for item: Item) -> NSImage? { icons[item.id] }

    private func updateTicker() {
        let needsTicks = items.contains { $0.data.chronometerBaseMs != 0 }
        if needsTicks, ticker == nil {
            ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.now = Date() }
            }
        } else if !needsTicks {
            ticker?.invalidate()
            ticker = nil
        }
    }

    // MARK: Formatting

    func timerText(_ data: OngoingActivityData) -> String? {
        guard data.chronometerBaseMs != 0 else { return nil }
        let base = Double(data.chronometerBaseMs) / 1000
        let seconds = max(0, Int((data.countsDown ? base - now.timeIntervalSince1970 : now.timeIntervalSince1970 - base).rounded()))
        let (h, m, s) = (seconds / 3600, seconds / 60 % 60, seconds % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// Short text for the menu bar.
    func compactText(_ data: OngoingActivityData) -> String {
        if !data.shortText.isEmpty { return data.shortText }
        if let timer = timerText(data) { return timer }
        if data.progressMax > 0 { return "\(Int(Double(data.progress) / Double(data.progressMax) * 100))%" }
        let title = data.title.isEmpty ? data.appLabel : data.title
        return title.count > 18 ? String(title.prefix(17)) + "…" : title
    }

    func symbol(_ data: OngoingActivityData) -> String {
        if data.chronometerBaseMs != 0 { return data.countsDown ? "timer" : "stopwatch" }
        if data.progressMax > 0 || data.indeterminate { return "clock.arrow.circlepath" }
        return "dot.radiowaves.left.and.right"
    }
}

/// The list in the popover.
struct OngoingActivitiesSection: View {
    @ObservedObject var live: OngoingActivitiesModel
    @EnvironmentObject private var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if !live.items.isEmpty {
            Text("Ongoing Activities").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 2)
            ForEach(live.items.prefix(3)) { item in
                row(item)
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func row(_ item: OngoingActivitiesModel.Item) -> some View {
        let data = item.data
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Group {
                    if let icon = live.icon(for: item) {
                        Image(nsImage: icon).resizable()
                    } else {
                        Image(systemName: live.symbol(data)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 22, height: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(data.title.isEmpty ? data.appLabel : data.title)
                        .font(.caption.weight(.medium)).lineLimit(1)
                    if !data.text.isEmpty {
                        Text(data.text).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer()
                if let timer = live.timerText(data) {
                    Text(timer).font(.caption.monospacedDigit().weight(.semibold))
                }
            }
            if data.progressMax > 0 {
                ProgressView(value: Double(data.progress), total: Double(data.progressMax))
                    .controlSize(.small)
            } else if data.indeterminate {
                ProgressView().progressViewStyle(.linear).controlSize(.small)
            }
            if !data.actions.isEmpty {
                HStack {
                    ForEach(Array(data.actions.enumerated()), id: \.offset) { index, action in
                        Button(action.label) {
                            model.act(deviceId: item.deviceId, key: data.key, act: .action(index: UInt32(index)))
                        }
                    }
                }
                .controlSize(.mini)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            openWindow(id: "screen", value: ScreenTarget(deviceId: item.deviceId, package: data.package, label: data.appLabel))
            NSApp.activate(ignoringOtherApps: true)
        }
        .help("Open \(data.appLabel) in a window")
    }
}
