import AppKit
import QuickLookThumbnailing
import SwiftUI

/// A floating thumbnail of the latest photo or scan from the phone, like the screenshot preview:
/// drag it into any app (Outlook, a browser, chat apps) to attach the file, click to open it.
/// Services only work in apps that accept their result; dragging works everywhere.
@MainActor
final class CaptureShelf {
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    func show(_ url: URL) {
        close()
        let size = NSSize(width: 150, height: 190)
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: ShelfView(url: url, onClose: { [weak self] in self?.close() },
                                                              onHover: { [weak self] hovering in self?.hovering(hovering) }))
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 20, y: screen.minY + 20))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        scheduleHide()
    }

    func close() {
        hideWork?.cancel()
        panel?.orderOut(nil)
        panel = nil
    }

    private func hovering(_ hovering: Bool) {
        if hovering { hideWork?.cancel() } else { scheduleHide() }
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.close() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 60, execute: work)
    }
}

private struct ShelfView: View {
    let url: URL
    let onClose: () -> Void
    let onHover: (Bool) -> Void
    @State private var thumbnail: NSImage?

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail).resizable().scaledToFit()
                    } else {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit()
                    }
                }
                .frame(width: 120, height: 130)
                .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                .onTapGesture { NSWorkspace.shared.open(url) }
                .help("Drag into a message or document to attach · Click to open")
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill").font(.title3).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .offset(x: 8, y: -8)
            }
            Text("Drag to attach")
                .font(.caption.weight(.medium))
            Text(url.lastPathComponent)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(12)
        .frame(width: 150, height: 190)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .onHover(perform: onHover)
        .task {
            let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 120, height: 130),
                                                       scale: NSScreen.main?.backingScaleFactor ?? 2,
                                                       representationTypes: .thumbnail)
            if let result = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
                thumbnail = result.nsImage
            }
        }
    }
}
