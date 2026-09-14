import BregeCore
import SwiftUI

/// Messages window: conversations from the phone, with SMS sending and RCS replies.
struct MessagesView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: MessagesModel
    @State private var search = ""
    @State private var composingNew = false
    @State private var dialing = false
    private var device: Device? { app.device(model.deviceId) }
    private var connected: Bool { device?.connected == true }

    var body: some View {
        split
        .navigationTitle(device.map { "Messages — \($0.name)" } ?? "Messages")
        .toolbar {
            ToolbarItemGroup {
                Button { dialing = true } label: { Label("Call…", systemImage: "phone") }
                    .disabled(!connected)
                Button { composingNew = true } label: { Label("New Message", systemImage: "square.and.pencil") }
                    .disabled(!connected)
                Button { model.refreshFromPhone() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(!connected)
            }
        }
        .sheet(isPresented: $composingNew, onDismiss: { model.composeNumber = nil }) {
            NewMessageSheet(model: model, number: model.composeNumber ?? "")
        }
        .onChange(of: model.composeNumber) { number in
            if number != nil { composingNew = true }
        }
        .sheet(isPresented: $dialing) { DialSheet(sims: model.sims, deviceId: model.deviceId) }
        .alert("Could not send", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .frame(minWidth: 720, minHeight: 480)
        .onAppear { app.messagesWindowOpened(deviceId: model.deviceId) }
    }

    @ViewBuilder
    private var split: some View {
        if Screenshots.isActive {
            // The window server draws the sidebar's glass, which an offscreen capture cannot
            // show; the README screenshot lays the same two columns out side by side.
            HStack(spacing: 0) {
                threadList.frame(width: 300)
                Divider()
                detail
            }
        } else {
            NavigationSplitView {
                threadList
                    .navigationSplitViewColumnWidth(min: 240, ideal: 300)
            } detail: {
                detail
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let thread = model.selectedThread {
            ConversationView(model: model, thread: thread)
                .id(thread.id)
        } else {
            emptyDetail
        }
    }

    private var filteredThreads: [ThreadData] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return model.threads }
        return model.threads.filter {
            $0.displayName.lowercased().contains(query) || $0.snippet.lowercased().contains(query)
                || $0.addresses.contains { $0.contains(query) }
        }
    }

    private var threadList: some View {
        List(selection: $model.selectedThreadId) {
            ForEach(filteredThreads, id: \.id) { thread in
                ThreadRow(thread: thread, photo: model.photo(for: thread)).tag(thread.id)
            }
        }
        .searchable(text: $search, placement: .sidebar)
        .overlay {
            if model.threads.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "message").font(.largeTitle).foregroundStyle(.secondary)
                    Text(connected ? "No messages yet" : "Phone not connected").font(.headline)
                    Text("On your phone, open Brêge and allow “Text messages on your Mac”.")
                        .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding()
            }
        }
    }

    private var emptyDetail: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right").font(.system(size: 48)).foregroundStyle(.tertiary)
            Text("Select a conversation").foregroundStyle(.secondary)
        }
    }
}

private struct ThreadRow: View {
    let thread: ThreadData
    var photo: NSImage?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(name: thread.displayName, isGroup: thread.addresses.count > 1, photo: photo)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(thread.displayName).font(.body.weight(thread.unread ? .bold : .regular)).lineLimit(1)
                    Spacer()
                    Text(Formatting.shortDate(ms: thread.lastMs)).font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    if thread.kind == .rcs {
                        Text("RCS").font(.caption2.weight(.semibold)).padding(.horizontal, 4)
                            .background(.blue.opacity(0.15), in: Capsule())
                    }
                    Text(thread.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            if thread.unread {
                Circle().fill(.blue).frame(width: 8, height: 8).padding(.top, 6)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct Avatar: View {
    let name: String
    let isGroup: Bool
    var photo: NSImage?

    var body: some View {
        ZStack {
            Circle().fill(Color.accentColor.opacity(0.2))
            if let photo {
                Image(nsImage: photo).resizable().scaledToFill().clipShape(Circle())
            } else if isGroup {
                Image(systemName: "person.2.fill").font(.caption).foregroundStyle(Color.accentColor)
            } else {
                Text(initials).font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
            }
        }
        .frame(width: 32, height: 32)
    }

    private var initials: String {
        let letters = name.split(separator: " ").prefix(2).compactMap { $0.first(where: \.isLetter) }
        return letters.isEmpty ? "#" : String(letters).uppercased()
    }
}

private struct ConversationView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: MessagesModel
    let thread: ThreadData
    @State private var draft = ""
    private var connected: Bool { app.device(model.deviceId)?.connected == true }
    @State private var subId: Int32 = -1

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 6) {
                        if model.hasOlder && model.messages.count >= 50 {
                            Button("Load earlier messages") { model.loadOlder() }
                                .buttonStyle(.borderless).padding(.vertical, 6)
                        }
                        ForEach(model.messages, id: \.id) { message in
                            Bubble(text: message.body, outgoing: message.outgoing, time: message.tsMs,
                                   sender: thread.addresses.count > 1 || thread.kind == .rcs ? message.senderName : "",
                                   hasMedia: message.hasMedia,
                                   failed: message.status == .failed, sending: message.status == .sending)
                                .id(message.id)
                        }
                        ForEach(model.pending.filter { $0.threadId == thread.id }) { p in
                            Bubble(text: p.body, outgoing: true, time: p.createdMs, sender: "", hasMedia: false,
                                   failed: p.status == .failed, sending: p.status == .sending,
                                   error: p.error, onDismiss: { model.dismissPending(p.id) })
                                .id(p.id)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(12)
                }
                .onAppear { proxy.scrollTo("bottom") }
                .onChange(of: model.messages.last?.id) { _ in withAnimation { proxy.scrollTo("bottom") } }
                .onChange(of: model.pending.count) { _ in withAnimation { proxy.scrollTo("bottom") } }
            }
            Divider()
            composer
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(thread.displayName).font(.headline)
                if thread.title.isEmpty, thread.addresses.count == 1, !thread.names.allSatisfy(\.isEmpty) {
                    Text(thread.addresses[0]).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let number = thread.callableNumber {
                Button { app.dial(number: number, subId: subId, deviceId: model.deviceId) } label: { Label("Call", systemImage: "phone") }
                    .disabled(!connected)
            }
        }
        .padding(12)
    }

    @ViewBuilder private var composer: some View {
        if thread.canReply {
            HStack(alignment: .bottom, spacing: 8) {
                if model.sims.count > 1, thread.kind == .sms {
                    Picker("", selection: $subId) {
                        Text("Default SIM").tag(Int32(-1))
                        ForEach(model.sims, id: \.subId) { sim in Text(sim.label).tag(sim.subId) }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
                TextField(thread.kind == .rcs ? "Reply via your messaging app" : "Text message", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...6)
                    .onSubmit(send)
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !connected)
            }
            .padding(10)
        } else {
            Text(thread.kind == .rcs
                 ? "Reply on your phone — this conversation has no active notification to reply to."
                 : "Group and multimedia conversations can only be answered on your phone.")
                .font(.caption).foregroundStyle(.secondary).padding(10)
        }
    }

    private func send() {
        let body = draft
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        model.send(body: body, to: thread, subId: subId)
        draft = ""
    }
}

private struct Bubble: View {
    let text: String
    let outgoing: Bool
    let time: Int64
    let sender: String
    let hasMedia: Bool
    var failed = false
    var sending = false
    var error = ""
    var onDismiss: (() -> Void)?

    var body: some View {
        HStack {
            if outgoing { Spacer(minLength: 60) }
            VStack(alignment: outgoing ? .trailing : .leading, spacing: 2) {
                if !sender.isEmpty && !outgoing {
                    Text(sender).font(.caption2).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 4) {
                    if hasMedia {
                        Label("Photo or attachment — open on phone", systemImage: "photo")
                            .font(.caption)
                    }
                    if !text.isEmpty {
                        Text(text).textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .foregroundStyle(outgoing ? .white : .primary)
                .background(outgoing ? (failed ? Color.red : Color.accentColor) : Color.secondary.opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 14))
                .opacity(sending ? 0.6 : 1)
                HStack(spacing: 4) {
                    if failed {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.red)
                        Text(error.isEmpty ? "Not sent" : error).foregroundStyle(.red)
                        if let onDismiss { Button("Dismiss", action: onDismiss).buttonStyle(.borderless) }
                    } else if sending {
                        Text("Sending…")
                    } else {
                        Text(Formatting.time(ms: time))
                    }
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
            if !outgoing { Spacer(minLength: 60) }
        }
    }
}

private struct NewMessageSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: MessagesModel
    @State private var number: String

    init(model: MessagesModel, number: String) {
        self.model = model
        _number = State(initialValue: number)
    }
    @State private var body_ = ""
    @State private var subId: Int32 = -1

    var body: some View {
        Form {
            TextField("To (phone number)", text: $number)
            if model.sims.count > 1 {
                Picker("SIM", selection: $subId) {
                    Text("Default").tag(Int32(-1))
                    ForEach(model.sims, id: \.subId) { sim in Text(sim.label).tag(sim.subId) }
                }
            }
            TextField("Message", text: $body_, axis: .vertical).lineLimit(3...8)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Send") {
                    if model.sendNew(body: body_, to: number, subId: subId) { dismiss() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(number.isEmpty || body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .frame(width: 380)
    }
}

struct DialSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var app: AppModel
    let sims: [SimData]
    let deviceId: String
    @State private var number = ""
    @State private var subId: Int32 = -1

    var body: some View {
        Form {
            TextField("Phone number", text: $number)
            if sims.count > 1 {
                Picker("SIM", selection: $subId) {
                    Text("Default").tag(Int32(-1))
                    ForEach(sims, id: \.subId) { sim in Text(sim.label).tag(sim.subId) }
                }
            }
            Text("The call starts on your phone; you talk on the phone.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Call") {
                    app.dial(number: number, subId: subId, deviceId: deviceId)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!number.contains(where: \.isNumber))
            }
        }
        .padding()
        .frame(width: 340)
    }
}

enum Formatting {
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()

    static func time(ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        return Calendar.current.isDateInToday(date) ? timeFormatter.string(from: date)
            : "\(dayFormatter.string(from: date)) \(timeFormatter.string(from: date))"
    }

    static func shortDate(ms: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000)
        return Calendar.current.isDateInToday(date) ? timeFormatter.string(from: date) : dayFormatter.string(from: date)
    }
}
