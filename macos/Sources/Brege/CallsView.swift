import BregeCore
import SwiftUI

/// Recent calls of one phone, with the keypad for a number that is not in the list.
struct CallsView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: CallsModel
    @State private var search = ""
    @State private var showingKeypad = false
    @State private var calling: CallLogData?

    private var device: Device? { app.device(model.deviceId) }
    private var connected: Bool { device?.connected == true }

    private var filtered: [CallLogData] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return model.calls }
        let digits = query.filter(\.isNumber)
        return model.calls.filter {
            $0.contactName.lowercased().contains(query)
                || (!digits.isEmpty && $0.number.filter(\.isNumber).contains(digits))
        }
    }

    var body: some View {
        List {
            ForEach(filtered, id: \.id) { call in
                CallRow(call: call, sims: app.sims(for: model.deviceId),
                        canCall: connected && !call.number.isEmpty,
                        onCall: { confirm(call) })
                    .contentShape(Rectangle())
                    // A single click only selects: dialling needs the button, a double click or the menu.
                    .onTapGesture(count: 2) { if connected { confirm(call) } }
                    .contextMenu {
                        Button("Call Back") { confirm(call) }
                            .disabled(!connected || call.number.isEmpty)
                        Button("Message") { app.openMessages(deviceId: model.deviceId, composingTo: call.number) }
                            .disabled(!connected || call.number.isEmpty)
                        Divider()
                        Button("Copy Number") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(call.number, forType: .string)
                        }
                        .disabled(call.number.isEmpty)
                    }
            }
            if model.hasOlder, !model.calls.isEmpty, search.isEmpty {
                Button("Load Older Calls") { model.loadOlder() }
                    .buttonStyle(.link)
                    .disabled(!connected)
            }
        }
        .searchable(text: $search)
        .overlay {
            if model.calls.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "phone").font(.largeTitle).foregroundStyle(.secondary)
                    Text(connected ? "No recent calls" : "Phone not connected").font(.headline)
                    Text(connected
                        ? "On your phone, open Brêge and allow “Calls on your Mac”."
                        : "Recent calls appear here when the phone is connected.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding()
            }
        }
        .navigationTitle(device.map { "Calls — \($0.name)" } ?? "Calls")
        .toolbar {
            ToolbarItemGroup {
                Button { showingKeypad = true } label: { Label("Keypad", systemImage: "circle.grid.3x3") }
                    .disabled(!connected)
                    .popover(isPresented: $showingKeypad, arrowEdge: .bottom) {
                        KeypadView(sims: app.sims(for: model.deviceId), deviceId: model.deviceId,
                                   names: model.knownNames) { showingKeypad = false }
                            .environmentObject(app)
                    }
                Button { model.refreshFromPhone() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(!connected)
            }
        }
        .frame(minWidth: 420, minHeight: 420)
        .onAppear { app.callsWindowOpened(deviceId: model.deviceId) }
        .confirmationDialog(
            calling.map { "Call \($0.contactName.isEmpty ? $0.number : $0.contactName)?" } ?? "Call?",
            isPresented: Binding(get: { calling != nil }, set: { if !$0 { calling = nil } }),
            titleVisibility: .visible
        ) {
            Button("Call") {
                if let call = calling { app.dial(number: call.number, deviceId: model.deviceId) }
                calling = nil
            }
            Button("Cancel", role: .cancel) { calling = nil }
        } message: {
            Text("The call starts on your phone; you talk on the phone.")
        }
    }
}

extension CallsView {
    /// Asks before dialling: one stray click should never start a real call.
    private func confirm(_ call: CallLogData) {
        guard connected, !call.number.isEmpty else { return }
        calling = call
    }
}

private struct CallRow: View {
    let call: CallLogData
    let sims: [SimData]
    var canCall = false
    var onCall: () -> Void = {}
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(call.direction == .missed ? Color.red : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(call.contactName.isEmpty ? displayNumber : call.contactName)
                    .lineLimit(1)
                    .foregroundStyle(call.direction == .missed ? Color.red : .primary)
                HStack(spacing: 6) {
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    if let sim = sims.first(where: { $0.subId == call.subId }), sims.count > 1 {
                        Text(sim.label).font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 4)
                            .background(.quaternary.opacity(0.5), in: Capsule())
                    }
                }
            }
            Spacer()
            if hovering, canCall {
                Button(action: onCall) { Image(systemName: "phone.fill") }
                    .buttonStyle(.borderless)
                    .help("Call this number back")
            }
            Text(Formatting.shortDate(ms: call.startedMs)).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .onHover { hovering = $0 }
    }

    private var displayNumber: String { call.number.isEmpty ? "Unknown caller" : call.number }

    private var symbol: String {
        switch call.direction {
        case .outgoing: "phone.arrow.up.right"
        case .missed: "phone.arrow.down.left"
        case .rejected: "phone.down"
        case .blocked: "nosign"
        case .voicemail: "recordingtape"
        case .incoming: "phone.arrow.down.left"
        }
    }

    private var detail: String {
        var parts: [String] = []
        if !call.contactName.isEmpty, !call.number.isEmpty { parts.append(call.number) }
        parts.append(description)
        return parts.joined(separator: " · ")
    }

    private var description: String {
        switch call.direction {
        case .missed: "Missed"
        case .rejected: "Declined"
        case .blocked: "Blocked"
        case .voicemail: "Voicemail"
        case .incoming, .outgoing:
            call.durationS == 0 ? "No answer" : Self.duration(seconds: Int(call.durationS))
        }
    }

    private static func duration(seconds: Int) -> String {
        seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
