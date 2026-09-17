import AppKit
import BregeCore
import SwiftUI
import UniformTypeIdentifiers

/// The phone's whole photo library: a grid by month, the gallery's albums in the sidebar, and drag,
/// open or save for the ones you pick. Only the photo you touch travels to the Mac.
struct PhotosView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: PhotosModel
    @State private var search = ""
    @State private var selection = Set<String>()
    @State private var largeVideo: PhotosModel.Item?

    private var device: Device? { app.device(model.deviceId) }
    private var connected: Bool { device?.connected == true }

    private var months: [(title: String, items: [PhotosModel.Item])] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return model.months }
        return model.months.compactMap { month in
            let items = month.items.filter { $0.name.lowercased().contains(query) }
            return items.isEmpty ? nil : (title: month.title, items: items)
        }
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            grid
        }
        .navigationTitle(device.map { "Photos — \($0.name)" } ?? "Photos")
        .searchable(text: $search, placement: .toolbar, prompt: "Search by file name")
        .toolbar {
            ToolbarItemGroup {
                Toggle(isOn: $model.includeVideos) { Label("Videos", systemImage: "video") }
                    .toggleStyle(.button)
                    .help("Show videos as well as photos")
                Button { model.restart(); model.loadMore(device) } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(!connected)
            }
        }
        .frame(minWidth: 620, minHeight: 460)
        .onAppear { app.photosWindowOpened(deviceId: model.deviceId) }
        // Switching album or the video toggle empties the grid, so ask for the first page at once.
        .onChange(of: model.album) { _ in model.loadMore(device) }
        .onChange(of: model.includeVideos) { _ in model.loadMore(device) }
        .confirmationDialog(
            largeVideo.map { "Fetch \($0.name)?" } ?? "",
            isPresented: Binding(get: { largeVideo != nil }, set: { if !$0 { largeVideo = nil } }),
            titleVisibility: .visible
        ) {
            Button("Fetch") {
                if let item = largeVideo, let device { model.file(for: item, from: device) { _ in } }
                largeVideo = nil
            }
            Button("Cancel", role: .cancel) { largeVideo = nil }
        } message: {
            Text("This video is \(Self.size(largeVideo?.sizeBytes ?? 0)). It is sent over your own network.")
        }
    }

    private var sidebar: some View {
        List(selection: Binding(get: { model.album }, set: { model.album = $0 ?? "" })) {
            Label("All Photos", systemImage: "photo.on.rectangle").tag("")
            if !model.albums.isEmpty {
                Section("Albums") {
                    ForEach(model.albums) { album in
                        HStack {
                            Label(album.name, systemImage: album.name == "Screenshots" ? "camera.viewfinder" : "folder")
                                .lineLimit(1)
                            Spacer()
                            Text("\(album.count)").font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(album.id)
                    }
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 170, ideal: 190)
    }

    private var grid: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14, pinnedViews: [.sectionHeaders]) {
                ForEach(months, id: \.title) { month in
                    Section {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                            ForEach(month.items) { item in
                                thumbnail(item)
                            }
                        }
                        .padding(.horizontal, 12)
                    } header: {
                        Text(month.title)
                            .font(.headline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.regularMaterial)
                    }
                }
                footer
            }
            .padding(.vertical, 10)
        }
        .overlay { if model.items.isEmpty { empty } }
    }

    private var footer: some View {
        Group {
            if model.loading {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.vertical, 12)
            } else if !model.reachedEnd, !model.items.isEmpty {
                // Reaching the bottom asks for the next page.
                Color.clear.frame(height: 1).onAppear { model.loadMore(device) }
            } else if model.partialAccess {
                Label("Only the photos you picked on the phone are shown.", systemImage: "hand.raised")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled").font(.largeTitle).foregroundStyle(.secondary)
            Text(model.permissionNeeded ? "No photo access yet"
                : connected ? "No photos" : "Phone not connected").font(.headline)
            Text(model.permissionNeeded
                ? "On your phone, open Brêge and allow “Recent photos on your Mac”."
                : connected ? "This album is empty." : "Photos you looked at before stay visible here.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .padding()
    }

    private func thumbnail(_ item: PhotosModel.Item) -> some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let image = item.thumbnail {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: item.video ? "video" : "photo").foregroundStyle(.secondary)
                }
            }
            .frame(width: 104, height: 104)
            .clipped()
            if item.video {
                Label(Self.duration(item.durationMs), systemImage: "play.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 4).padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: Capsule())
                    .foregroundStyle(.white)
                    .padding(5)
            }
        }
        .frame(width: 104, height: 104)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(selection.contains(item.id) ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                              lineWidth: selection.contains(item.id) ? 2 : 1)
        )
        .overlay { progress(item) }
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { selection = [item.id] }
        .onTapGesture(count: 2) { open(item) }
        .onDrag { dragProvider(item) }
        .contextMenu {
            Button("Open") { open(item) }
            Button("Copy") { copy(item) }
            Button("Save to…") { save(item) }
            Divider()
            Button("Reveal in Finder") { reveal(item) }
        }
        .help("\(item.name) · \(Self.size(item.sizeBytes))")
    }

    @ViewBuilder private func progress(_ item: PhotosModel.Item) -> some View {
        if let progress = model.progress(item, transfers: app.transfers) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(.black.opacity(0.35))
                Circle().stroke(.white.opacity(0.35), lineWidth: 3).frame(width: 26, height: 26)
                Circle().trim(from: 0, to: max(0.05, progress))
                    .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 26, height: 26)
            }
        }
    }

    // MARK: Actions

    private func fetch(_ item: PhotosModel.Item, then use: @escaping (URL) -> Void) {
        guard let device, connected else { return }
        if item.sizeBytes > PhotosModel.askBeforeBytes, model.progress(item, transfers: app.transfers) == nil {
            largeVideo = item
            return
        }
        model.file(for: item, from: device) { result in
            if case let .success(url) = result { use(url) }
        }
    }

    private func open(_ item: PhotosModel.Item) { fetch(item) { NSWorkspace.shared.open($0) } }

    private func copy(_ item: PhotosModel.Item) {
        fetch(item) { url in
            PhoneCapture.write(url, to: NSPasteboard.general)
            ClipboardMonitor.markOwnWrite()
        }
    }

    private func reveal(_ item: PhotosModel.Item) {
        fetch(item) { NSWorkspace.shared.activateFileViewerSelecting([$0]) }
    }

    private func save(_ item: PhotosModel.Item) {
        fetch(item) { url in
            let panel = NSSavePanel()
            panel.nameFieldStringValue = item.name
            panel.begin { response in
                guard response == .OK, let target = panel.url else { return }
                try? FileManager.default.removeItem(at: target)
                try? FileManager.default.copyItem(at: url, to: target)
            }
        }
    }

    private func dragProvider(_ item: PhotosModel.Item) -> NSItemProvider {
        guard let device else { return NSItemProvider() }
        let provider = NSItemProvider()
        provider.suggestedName = (item.name as NSString).deletingPathExtension
        let type = UTType(filenameExtension: (item.name as NSString).pathExtension)
            ?? UTType(mimeType: item.mime) ?? .jpeg
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            Task { @MainActor in
                model.file(for: item, from: device) { result in
                    switch result {
                    case let .success(url): completion(url, false, nil)
                    case let .failure(error):
                        completion(nil, false, NSError(domain: "Brege", code: 1,
                                                       userInfo: [NSLocalizedDescriptionKey: error.message]))
                    }
                }
            }
            return nil
        }
        return provider
    }

    private static func duration(_ ms: UInt32) -> String {
        let seconds = Int(ms / 1000)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    private static func size(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
