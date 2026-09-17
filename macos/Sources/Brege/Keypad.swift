import BregeCore
import SwiftUI

/// Keypad for dialling a number on the phone. The call starts on the phone; the Mac only asks for
/// it (`CallAction.DIAL`), so there is no audio here and no tones during a running call.
struct KeypadView: View {
    @EnvironmentObject private var app: AppModel
    let sims: [SimData]
    let deviceId: String
    /// Names the Mac already has for numbers (message threads, recent calls), for the suggestions.
    var names: [String: String] = [:]
    var onCall: () -> Void = {}

    @State private var number = ""
    @State private var subId: Int32 = -1
    @FocusState private var fieldFocused: Bool

    private static let keys: [[(String, String)]] = [
        [("1", ""), ("2", "ABC"), ("3", "DEF")],
        [("4", "GHI"), ("5", "JKL"), ("6", "MNO")],
        [("7", "PQRS"), ("8", "TUV"), ("9", "WXYZ")],
        [("*", ""), ("0", "+"), ("#", "")],
    ]

    var body: some View {
        VStack(spacing: 12) {
            field
            if let match = suggestion {
                Text(match).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            keypad
            if sims.count > 1 {
                Picker("SIM", selection: $subId) {
                    Text("Default").tag(Int32(-1))
                    ForEach(sims, id: \.subId) { sim in Text(sim.label).tag(sim.subId) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
            Button(action: call) {
                Label("Call", systemImage: "phone.fill").frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!canCall)
            Text("The call starts on your phone; you talk on the phone.")
                .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
        }
        .padding(16)
        .frame(width: 260)
        .onAppear { fieldFocused = true }
    }

    private var field: some View {
        HStack(spacing: 6) {
            TextField("Phone number", text: $number)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .regular, design: .rounded))
                .multilineTextAlignment(.center)
                .focused($fieldFocused)
                .onSubmit { if canCall { call() } }
            Button {
                if !number.isEmpty { number.removeLast() }
            } label: {
                Image(systemName: "delete.left")
            }
            .buttonStyle(.plain)
            .opacity(number.isEmpty ? 0 : 1)
            .help("Remove the last character")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private var keypad: some View {
        VStack(spacing: 6) {
            ForEach(Self.keys, id: \.first!.0) { row in
                HStack(spacing: 6) {
                    ForEach(row, id: \.0) { key, letters in
                        Button { tap(key) } label: {
                            VStack(spacing: 1) {
                                Text(key).font(.system(size: 20, weight: .medium, design: .rounded))
                                if !letters.isEmpty {
                                    Text(letters).font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, minHeight: 40)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.bordered)
                        // Long-press 0 for "+", as on a phone.
                        .simultaneousGesture(
                            LongPressGesture().onEnded { _ in if key == "0" { tap("+") } }
                        )
                    }
                }
            }
        }
    }

    /// Mirrors `brege_features::messages::is_dialable`, which the core checks before dialling.
    private var canCall: Bool {
        let trimmed = number.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.count <= 32 && trimmed.contains(where: \.isNumber)
            && trimmed.allSatisfy { $0.isNumber || "+*# -().".contains($0) }
    }

    private var suggestion: String? {
        let digits = number.filter(\.isNumber)
        guard digits.count >= 3 else { return nil }
        return names.first { key, _ in key.filter(\.isNumber).hasSuffix(digits) }?.value
    }

    private func tap(_ key: String) {
        if key == "+", number.hasSuffix("0") { number.removeLast() }
        number += key
    }

    private func call() {
        app.dial(number: number.trimmingCharacters(in: .whitespaces), subId: subId, deviceId: deviceId)
        number = ""
        onCall()
    }
}

/// The keypad as a sheet, from the Messages window toolbar.
struct DialSheet: View {
    @Environment(\.dismiss) private var dismiss
    let sims: [SimData]
    let deviceId: String
    var names: [String: String] = [:]

    var body: some View {
        VStack(spacing: 0) {
            KeypadView(sims: sims, deviceId: deviceId, names: names) { dismiss() }
            Divider()
            HStack {
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(10)
        }
        .frame(width: 260)
    }
}
