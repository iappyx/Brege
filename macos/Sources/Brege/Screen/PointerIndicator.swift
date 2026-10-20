import AppKit

/// A band down the screen edge while the phone holds this Mac's pointer and keyboard.
///
/// Capturing the keyboard means every keystroke leaves this Mac, and macOS shows nothing of its
/// own for that — screen recording gets a system indicator, reading input does not. So the warning
/// has to come from here, and it is deliberately hard to miss: the risk it guards against is
/// typing a password into the Mac while the phone is still receiving it.
@MainActor
final class PointerIndicator {
    private var window: NSWindow?

    /// Shows the band along `edge`, naming where the keystrokes are going.
    func show(edge: PointerCapture.Edge, device: String) {
        hide()
        guard let screen = NSScreen.main else { return }

        let width: CGFloat = 320
        let frame = NSRect(
            x: edge == .right ? screen.frame.maxX - width : screen.frame.minX,
            y: screen.frame.minY,
            width: width,
            height: screen.frame.height
        )
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true          // never in the way of what is being pointed at
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        panel.isReleasedWhenClosed = false
        panel.contentView = BandView(edge: edge, device: device)
        panel.orderFrontRegardless()
        window = panel
    }

    func hide() {
        window?.orderOut(nil)
        window = nil
    }

    /// A solid bar hard against the edge, fading into the screen, with the way back written on it.
    private final class BandView: NSView {
        private let edge: PointerCapture.Edge
        private let device: String

        init(edge: PointerCapture.Edge, device: String) {
            self.edge = edge
            self.device = device
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not from a nib") }

        override func draw(_ dirtyRect: NSRect) {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            let colour = NSColor.systemOrange

            // The gradient keeps the edge itself solid while the rest only tints the screen.
            let solid = colour.withAlphaComponent(0.85).cgColor
            let clear = colour.withAlphaComponent(0).cgColor
            let stops: [CGFloat] = [0, 1]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                                         colors: [solid, clear] as CFArray, locations: stops) {
                let start = CGPoint(x: edge == .right ? bounds.maxX : bounds.minX, y: 0)
                let end = CGPoint(x: edge == .right ? bounds.minX : bounds.maxX, y: 0)
                context.drawLinearGradient(gradient, start: start, end: end, options: [])
            }

            let text = "Keyboard and pointer on \(device)\nPush back through this edge to return,\nor press Control-Esc"
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            style.lineSpacing = 4
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
                .foregroundColor: NSColor.white,
                .paragraphStyle: style,
            ]
            let size = (text as NSString).boundingRect(
                with: NSSize(width: 240, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin], attributes: attributes).size
            let inset: CGFloat = 20
            let origin = CGPoint(
                x: edge == .right ? bounds.maxX - size.width - inset : inset,
                y: bounds.midY - size.height / 2
            )
            (text as NSString).draw(in: NSRect(origin: origin, size: size), withAttributes: attributes)
        }
    }
}
