import ApplicationServices
import BregeCore
import CoreGraphics

/// Touch on the tablet, as pointer events on the display Brêge created.
///
/// The tablet sends fractions of the display rather than pixels, so neither side has to know the
/// other's geometry — and the same message works whatever size the display was created at.
///
/// Two ways round, chosen on the tablet:
///
/// - **Touchscreen** (`relative` false): the cursor goes where the finger went. Right when the
///   tablet is in front of you and you are touching what you can see.
/// - **Trackpad** (`relative` true): the cursor moves from wherever it already is. Right when the
///   tablet is beside the keyboard and you are looking at the Mac's own screen, where the spot your
///   finger happened to land says nothing about what you meant to point at. The cursor is also free
///   to leave this display and cross the Mac's real screens, which in touchscreen mode it cannot.
///
/// Either way it needs Privacy & Security › Accessibility, the same grant the pointer and the
/// watch's media keys use; without it macOS drops the events and the screen is one you can only
/// look at.
@MainActor
enum DisplayTouch {
    /// Whether a finger is currently down, so a move is a drag rather than a hover.
    private static var isDown = false
    /// Scroll too small to be a whole line yet. Kept, so a slow drag adds up instead of rounding
    /// away to nothing on every event.
    private static var pendingLinesX = 0.0
    private static var pendingLinesY = 0.0
    /// What a line is worth, roughly a line of text.
    private static let pointsPerLine = 16.0
    /// How far the cursor travels for a finger dragged across the tablet, as a multiple of the
    /// display's own width. Two means one full sweep crosses twice the display — enough to reach
    /// across a desktop without lifting, while a short nudge is still a short nudge.
    private static let trackpadSpeed = 2.0

    static func apply(phase: DisplayTouchPhase, relative: Bool, x: Float, y: Float,
                      dx: Float, dy: Float, displayID: CGDirectDisplayID) {
        guard displayID != 0 else { return }
        // The core clamps these before they get here, and they are checked again anyway: a value
        // that is not finite traps the moment it reaches `Int32`, which would take the app down,
        // and the cost of being sure is four comparisons per touch.
        guard x.isFinite, y.isFinite, dx.isFinite, dy.isFinite else { return }
        let across = min(1, max(0, CGFloat(x)))
        let down = min(1, max(0, CGFloat(y)))
        let moveX = min(1, max(-1, CGFloat(dx)))
        let moveY = min(1, max(-1, CGFloat(dy)))

        // A display macOS has taken away answers with an empty rect, and every point computed
        // from it would land in a corner of a real screen instead.
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0 else { return }
        let point = relative
            ? moved(by: moveX, moveY, within: bounds)
            : CGPoint(x: bounds.origin.x + across * bounds.width,
                      y: bounds.origin.y + down * bounds.height)

        switch phase {
        case .down:
            isDown = true
            pendingLinesX = 0
            pendingLinesY = 0
            post(.leftMouseDown, at: point)
        case .move:
            post(isDown ? .leftMouseDragged : .mouseMoved, at: point)
        case .up:
            post(.leftMouseUp, at: point)
            isDown = false
        case .scroll:
            // A scroll goes to whatever is under the cursor. In touchscreen mode that means putting
            // the cursor under the fingers first; as a trackpad the cursor is already where the
            // user has been steering it, and moving it would be wrong.
            if !relative { CGWarpMouseCursorPosition(point) }
            // Lines rather than pixels: a synthesized pixel scroll is quietly ignored by some
            // apps, while a line scroll is what a wheel sends and everything honours.
            pendingLinesX += Double(moveX) * bounds.width / pointsPerLine
            pendingLinesY += Double(moveY) * bounds.height / pointsPerLine
            let linesX = wholeLines(&pendingLinesX)
            let linesY = wholeLines(&pendingLinesY)
            guard linesX != 0 || linesY != 0 else { return }
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                                      wheel1: linesY, wheel2: linesX, wheel3: 0) else {
                DisplayLog.write("scroll: the event could not be made")
                return
            }
            event.location = relative ? (CGEvent(source: nil)?.location ?? point) : point
            event.post(tap: .cghidEventTap)
        }
    }

    /// Whole lines out of the accumulator, leaving the fraction behind.
    ///
    /// `Int32(_: Double)` traps on anything not finite and on anything outside its range, so the
    /// conversion is capped first. The cap is far above any real scroll — it exists so that a
    /// sender's arithmetic can never end the app.
    private static func wholeLines(_ accumulated: inout Double) -> Int32 {
        guard accumulated.isFinite else {
            accumulated = 0
            return 0
        }
        let whole = accumulated.rounded(.towardZero)
        accumulated -= whole
        return Int32(min(1000, max(-1000, whole)))
    }

    /// Where the cursor lands after a drag of `dx`, `dy` from where it is now.
    ///
    /// Nothing clamps it to this display: that freedom is the point of trackpad mode, and macOS
    /// keeps the cursor on some screen by itself.
    private static func moved(by dx: CGFloat, _ dy: CGFloat, within bounds: CGRect) -> CGPoint {
        let from = CGEvent(source: nil)?.location ?? CGPoint(x: bounds.midX, y: bounds.midY)
        return CGPoint(x: from.x + dx * bounds.width * trackpadSpeed,
                       y: from.y + dy * bounds.height * trackpadSpeed)
    }

    /// Whether macOS will accept the events at all. Logged once at the start of a session
    /// rather than per touch: hundreds of lines a second say nothing the first one did not.
    static var isAllowed: Bool { AXIsProcessTrusted() }

    /// Releases anything held, so a session that ends mid-drag does not leave the button down.
    static func release(displayID: CGDirectDisplayID) {
        guard isDown, displayID != 0 else { return }
        isDown = false
        let bounds = CGDisplayBounds(displayID)
        post(.leftMouseUp, at: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    private static func post(_ type: CGEventType, at point: CGPoint) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point,
                                  mouseButton: .left) else { return }
        event.post(tap: .cghidEventTap)
    }
}
