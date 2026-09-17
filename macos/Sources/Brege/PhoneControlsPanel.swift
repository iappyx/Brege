import BregeCore
import SwiftUI

/// Phone controls in the menu: torch, sound, Do Not Disturb, ring and buzz, clearing notifications,
/// and what the phone reports about its alarm, storage and battery. Everything here is what a
/// normal Android app may do; Wi‑Fi, Bluetooth and airplane mode are system-only.
struct PhoneControlsPanel: View {
    @EnvironmentObject private var model: AppModel
    let device: Device
    @State private var confirmingClear = false

    private var state: PhoneControlsData? { model.phoneControls[device.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let state {
                if state.hasTorch { row { torch(state) } }
                row { sound(state) }
                row { state.needsDndAccess ? AnyView(accessHint) : AnyView(dnd(state)) }
                row { actions }
                status(state)
            } else {
                row {
                    Label(device.connected ? "Asking the phone…" : "Phone not connected",
                          systemImage: device.connected ? "ellipsis" : "wifi.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .disabled(!device.connected)
    }

    /// One card, in the same style as the tiles above it.
    private func row(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
    }

    // --- controls ---------------------------------------------------------------------------

    private func torch(_ state: PhoneControlsData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { state.torchOn },
                set: { model.phoneControl(device, .torch, value: $0 ? 1 : 0) }
            )) {
                Label {
                    Text("Torch").font(.system(size: 12))
                } icon: {
                    Image(systemName: state.torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
                        .foregroundStyle(state.torchOn ? Color.accentColor : .secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .help("Turns itself off after ten minutes")

            // Only phones that support strength levels report a maximum above one.
            if state.torchOn, state.torchMaxLevel > 1 {
                HStack(spacing: 8) {
                    Image(systemName: "sun.min").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
                    Slider(value: Binding(
                        get: { Double(max(state.torchLevel, 1)) },
                        set: { model.phoneControl(device, .torchLevel, value: Int32($0.rounded())) }
                    ), in: 1...Double(state.torchMaxLevel))
                    .controlSize(.mini)
                    Text("\(max(state.torchLevel, 1))/\(state.torchMaxLevel)")
                        .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                        .frame(width: 32, alignment: .trailing)
                }
                .help("Torch brightness")
            }
        }
    }

    private func sound(_ state: PhoneControlsData) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: Binding(
                get: { state.ringerMode },
                set: { model.phoneControl(device, .ringerMode, value: Self.ringerValue($0)) }
            )) {
                Label("Silent", systemImage: "bell.slash").tag(RingerMode.silent)
                Label("Vibrate", systemImage: "waveform").tag(RingerMode.vibrate)
                Label("Sound", systemImage: "bell").tag(RingerMode.normal)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            slider("Ring", systemImage: "bell.fill", value: state.volumeRing) {
                model.phoneControl(device, .streamVolume, value: $0, stream: .ring)
            }
            slider("Media", systemImage: "speaker.wave.2.fill", value: state.volumeMedia) {
                model.phoneControl(device, .streamVolume, value: $0, stream: .media)
            }
            slider("Alarm", systemImage: "alarm.fill", value: state.volumeAlarm) {
                model.phoneControl(device, .streamVolume, value: $0, stream: .alarm)
            }
        }
    }

    private func slider(_ title: String, systemImage: String, value: UInt32,
                        onChange: @escaping (Int32) -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Slider(value: Binding(
                get: { Double(value) },
                set: { onChange(Int32($0.rounded())) }
            ), in: 0...100)
            .controlSize(.mini)
            Text("\(value)%")
                .font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)
        }
        .help("\(title) volume")
    }

    private func dnd(_ state: PhoneControlsData) -> some View {
        HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { state.dnd != .off },
                set: { model.phoneControl(device, .dnd, value: $0 ? Self.dndValue(.priority) : Self.dndValue(.off)) }
            )) {
                Label {
                    Text("Do Not Disturb").font(.system(size: 12))
                } icon: {
                    Image(systemName: "moon.fill")
                        .foregroundStyle(state.dnd != .off ? Color.accentColor : .secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            Spacer(minLength: 0)
            if state.dnd != .off {
                Picker("", selection: Binding(
                    get: { state.dnd },
                    set: { model.phoneControl(device, .dnd, value: Self.dndValue($0)) }
                )) {
                    Text("Priority").tag(DndMode.priority)
                    Text("Alarms only").tag(DndMode.alarms)
                    Text("Total silence").tag(DndMode.none)
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 110)
                .help("What still comes through while Do Not Disturb is on")
            }
        }
    }

    private var accessHint: some View {
        HStack(spacing: 8) {
            Image(systemName: "moon.badge.exclamationmark").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Do Not Disturb").font(.system(size: 12))
                Text("Needs permission on the phone").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Allow…") { model.phoneControl(device, .dnd, value: 2) }
                .controlSize(.small)
                .help("Sends a notification to the phone that opens the right settings screen")
        }
    }

    private var actions: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                action("Ring", systemImage: "bell.and.waves.left.and.right") { model.ring(device) }
                action("Stop", systemImage: "bell.slash") { model.stopRing(device) }
                action("Buzz", systemImage: "waveform") { model.phoneControl(device, .vibrate, value: 600) }
            }
            // Two presses instead of a dialog: a dialog would close this menu before it is answered.
            Button {
                if confirmingClear {
                    model.phoneControl(device, .clearNotifications, value: 0)
                    confirmingClear = false
                } else {
                    confirmingClear = true
                }
            } label: {
                Label(confirmingClear ? "Press again to clear" : "Clear Notifications",
                      systemImage: confirmingClear ? "exclamationmark.triangle.fill" : "bell.badge.slash")
                    .font(.system(size: 11))
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.small)
            .tint(confirmingClear ? .red : nil)
            .help("Music and navigation notifications stay: Android keeps those")
        }
        .onDisappear { confirmingClear = false }
    }

    private func action(_ title: String, systemImage: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 11))
                .frame(maxWidth: .infinity)
        }
        .controlSize(.small)
    }

    // --- what the phone reports ----------------------------------------------------------------

    private func status(_ state: PhoneControlsData) -> some View {
        let items = statusItems(state)
        return Group {
            if !items.isEmpty {
                HStack(spacing: 10) {
                    ForEach(items, id: \.text) { item in
                        HStack(spacing: 4) {
                            Image(systemName: item.symbol).font(.system(size: 9))
                            Text(item.text).lineLimit(1)
                        }
                        .foregroundStyle(item.symbol == "internaldrive" && storageIsLow(state)
                            ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.secondary))
                    }
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            }
        }
    }

    /// Free storage under a tenth of the phone is worth noticing.
    private func storageIsLow(_ state: PhoneControlsData) -> Bool {
        state.storageTotalBytes > 0 && state.storageFreeBytes * 10 < state.storageTotalBytes
    }

    private func statusItems(_ state: PhoneControlsData) -> [(symbol: String, text: String)] {
        var items: [(symbol: String, text: String)] = []
        if state.nextAlarmMs > 0 {
            items.append(("alarm", Formatting.shortDate(ms: state.nextAlarmMs)))
        }
        if state.storageTotalBytes > 0 {
            items.append(("internaldrive", "\(Self.size(state.storageFreeBytes)) free"))
        }
        if let battery = batteryLine(state) {
            items.append((state.chargingSource.isEmpty ? "battery.50" : "battery.100.bolt", battery))
        }
        return items
    }

    private func batteryLine(_ state: PhoneControlsData) -> String? {
        var parts: [String] = []
        if let percent = model.batteryPercent(device.id) { parts.append("\(percent)%") }
        if state.batteryTemperatureDc > 0 {
            parts.append(String(format: "%.0f °C", Double(state.batteryTemperatureDc) / 10))
        }
        if !state.batteryHealth.isEmpty, state.batteryHealth != "Good" { parts.append(state.batteryHealth) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func dndValue(_ mode: DndMode) -> Int32 {
        switch mode {
        case .off: 1
        case .priority: 2
        case .alarms: 3
        case .none: 4
        }
    }

    private static func ringerValue(_ mode: RingerMode) -> Int32 {
        switch mode {
        case .silent: 1
        case .vibrate: 2
        case .normal: 3
        }
    }

    private static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
