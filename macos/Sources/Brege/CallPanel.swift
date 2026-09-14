import AppKit
import BregeCore
import SwiftUI

/// Floating panel for the current phone call. Call audio stays on the phone,
/// because macOS offers no hands-free audio path.
@MainActor
final class CallPanelController {
    private var panel: NSPanel?

    func show(call: CallData, model: AppModel) {
        let view = CallView(call: call).environmentObject(model)
        if let panel {
            (panel.contentView as? NSHostingView<AnyView>)?.rootView = AnyView(view)
            panel.orderFrontRegardless()
            return
        }
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 170),
            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered, defer: false
        )
        panel.title = "Phone call"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: AnyView(view))
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - 320, y: frame.maxY - 20))
        }
        panel.orderFrontRegardless()
        self.panel = panel
    }

    func close() {
        panel?.close()
        panel = nil
    }
}

private struct CallView: View {
    @EnvironmentObject private var app: AppModel
    let call: CallData

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: call.incoming ? "phone.arrow.down.left.fill" : "phone.arrow.up.right.fill")
                    .font(.title2)
                    .foregroundStyle(call.status == .ringing ? .green : .accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).lineLimit(1)
                    if !call.contactName.isEmpty, !call.number.isEmpty {
                        Text(call.number).font(.caption).foregroundStyle(.secondary)
                    }
                    statusText.font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack {
                switch call.status {
                case .ringing where call.incoming:
                    Button(role: .destructive) { app.callAction(.decline) } label: {
                        Label("Decline", systemImage: "phone.down.fill")
                    }
                    Spacer()
                    Button { app.callAction(.answer) } label: {
                        Label("Answer on phone", systemImage: "phone.fill")
                    }
                    .keyboardShortcut(.defaultAction)
                case .ended:
                    Spacer()
                default:
                    Spacer()
                    Button(role: .destructive) { app.callAction(.hangUp) } label: {
                        Label("Hang up", systemImage: "phone.down.fill")
                    }
                }
            }
            .controlSize(.large)
            Text("You talk on your phone.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14)
        .frame(width: 300)
    }

    private var title: String {
        if !call.contactName.isEmpty { return call.contactName }
        if !call.number.isEmpty { return call.number }
        return call.incoming ? "Unknown caller" : "Outgoing call"
    }

    @ViewBuilder private var statusText: some View {
        switch call.status {
        case .ringing: Text(call.incoming ? "Incoming call" : "Ringing…")
        case .dialing: Text("Calling…")
        case .ended: Text("Call ended")
        case .active:
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(0, Int(context.date.timeIntervalSince1970) - Int(call.startedMs / 1000))
                Text(String(format: "%d:%02d", seconds / 60, seconds % 60)).monospacedDigit()
            }
        }
    }
}
