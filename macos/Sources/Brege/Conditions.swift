import AppKit
import BregeCore
import SwiftUI

/// What the phone's sensors say, on the Mac: air pressure and where the weather is going, how light
/// the room is, how warm and how fast the phone charges — and two things the Mac does about it.
///
/// Everything here comes from sensors that cost no permission on the phone.
@MainActor
final class ConditionsModel: ObservableObject {
    @Published private(set) var latest: ConditionsData?
    @Published private(set) var asking = false

    let deviceId: String
    private let node: () -> BregeNode?
    /// A push carries no chart, so the last history we asked for is kept.
    private var history: [PressurePointData] = []

    init(deviceId: String, node: @escaping () -> BregeNode?) {
        self.deviceId = deviceId
        self.node = node
    }

    var points: [PressurePointData] { history }

    /// Asks the phone for its readings. Watching how the phone lies costs power, so the phone only
    /// does it while the face-down automation is on.
    func refresh(_ device: Device?, hours: UInt32 = 24) {
        guard device?.connected == true else { return }
        asking = true
        try? node()?.requestConditions(deviceId: deviceId, historyHours: hours,
                                       watchMotion: ConditionsAutomation.faceDownQuiet)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.asking = false }
    }

    func received(_ conditions: ConditionsData) {
        asking = false
        latest = conditions
        if !conditions.history.isEmpty { history = conditions.history }
    }

    // --- what it means ----------------------------------------------------------------------

    /// The pressure trend in the words a barometer dial uses (after Zambretti).
    static func forecast(_ c: ConditionsData) -> String {
        guard c.hasBarometer, c.pressureHpa > 0 else { return "No barometer" }
        let delta = c.pressureDelta3h
        let high = c.pressureHpa >= 1015
        let low = c.pressureHpa <= 1005
        switch delta {
        case ..<(-3.5): return "Stormy, rain soon"
        case ..<(-1.5): return low ? "Rain likely" : "Becoming unsettled"
        case ..<(-0.5): return "Slowly turning wetter"
        case 0.5...1.5: return low ? "Slowly clearing" : "Fair, staying so"
        case 1.5...: return high ? "Settled and fine" : "Clearing up"
        default: return high ? "Settled and fine" : low ? "Unsettled" : "Steady"
        }
    }

    static func trendLine(_ c: ConditionsData) -> String {
        guard c.hasBarometer, c.pressureHpa > 0 else {
            return "This phone has no pressure sensor."
        }
        let now = String(format: "%.1f hPa", c.pressureHpa)
        guard abs(c.pressureDelta3h) >= 0.3 else { return "\(now) · steady" }
        let direction = c.pressureDelta3h < 0 ? "falling" : "rising"
        if c.fallingSinceMs > 0 {
            return "\(now) · \(direction) since \(Formatting.shortDate(ms: c.fallingSinceMs))"
        }
        return "\(now) · \(direction)"
    }

    static func delta(_ c: ConditionsData) -> String {
        String(format: "%+.1f / 3h", c.pressureDelta3h)
    }

    static func thermal(_ status: UInt32) -> String {
        switch status {
        case 0: return "Nominal"
        case 1: return "Light"
        case 2: return "Moderate"
        case 3: return "Severe"
        case 4: return "Critical"
        default: return "Emergency"
        }
    }

    static func light(_ c: ConditionsData) -> String {
        guard c.hasLight else { return "—" }
        return c.lightLux >= 1000
            ? String(format: "%.1f klx", c.lightLux / 1000)
            : String(format: "%.0f lx", c.lightLux)
    }

    static func lightDetail(_ c: ConditionsData) -> String {
        guard c.hasLight else { return "no sensor" }
        switch c.lightLux {
        case ..<5: return "dark"
        case ..<60: return "dim"
        case ..<400: return "lit room"
        case ..<3000: return "bright"
        default: return "daylight"
        }
    }
}

/// The two things the Mac does by itself when the phone reports a change.
///
/// Both are off until switched on, and both are reversed when the phone reports the opposite, so
/// nothing is left behind if the phone goes away.
@MainActor
enum ConditionsAutomation {
    private static let faceDownKey = "conditions.faceDownQuiet"
    private static let darkRoomKey = "conditions.darkRoomAppearance"

    static var faceDownQuiet: Bool {
        get { UserDefaults.standard.bool(forKey: faceDownKey) }
        set { UserDefaults.standard.set(newValue, forKey: faceDownKey) }
    }

    static var darkRoomAppearance: Bool {
        get { UserDefaults.standard.bool(forKey: darkRoomKey) }
        set { UserDefaults.standard.set(newValue, forKey: darkRoomKey) }
    }

    /// True while the phone lies face down and the switch is on: phone notifications are held back.
    private(set) static var quiet = false
    private static var appearanceChanged = false

    static func apply(_ c: ConditionsData, presenter: NotificationPresenter) {
        if faceDownQuiet, c.hasAccelerometer {
            let wanted = c.faceDown
            if wanted != quiet {
                quiet = wanted
                presenter.paused = wanted
            }
        } else if quiet {
            quiet = false
            presenter.paused = false
        }

        if darkRoomAppearance, c.hasLight {
            if c.darkRoom, !appearanceChanged {
                appearanceChanged = setDarkAppearance(true)
            } else if !c.darkRoom, appearanceChanged {
                _ = setDarkAppearance(false)
                appearanceChanged = false
            }
        }
    }

    /// Switching the Mac's appearance is the one thing here that needs the Automation permission;
    /// macOS asks the first time and the switch stays off if it is refused.
    @discardableResult
    private static func setDarkAppearance(_ dark: Bool) -> Bool {
        let source = """
        tell application "System Events" to tell appearance preferences \
        to set dark mode to \(dark ? "true" : "false")
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "not allowed"
            NSLog("Brêge: cannot switch appearance: \(message)")
            return false
        }
        return true
    }
}
