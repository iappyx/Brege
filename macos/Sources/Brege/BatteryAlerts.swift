import BregeCore
import Foundation

/// A Mac notification when the phone's battery runs low or is fully charged, once per crossing.
@MainActor
final class BatteryAlerts {
    private var lowShown: Set<String> = []
    private var fullShown: Set<String> = []
    private let presenter: NotificationPresenter

    init(presenter: NotificationPresenter) {
        self.presenter = presenter
    }

    func update(_ status: StatusData, device: Device) {
        let settings = AppSettings.shared
        let pct = Int(status.batteryPct)
        if status.charging || pct > settings.lowBatteryThreshold + 5 {
            lowShown.remove(device.id)
        } else if settings.lowBatteryAlert, pct <= settings.lowBatteryThreshold, !lowShown.contains(device.id) {
            lowShown.insert(device.id)
            presenter.showInfo(title: "\(device.name) battery low", body: "\(pct)% left. Time to charge your phone.")
        }
        if !status.charging || pct < 95 {
            fullShown.remove(device.id)
        } else if settings.fullBatteryAlert, pct >= 100, !fullShown.contains(device.id) {
            fullShown.insert(device.id)
            presenter.showInfo(title: "\(device.name) is fully charged", body: "You can unplug your phone.")
        }
    }
}
