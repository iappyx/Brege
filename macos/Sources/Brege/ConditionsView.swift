import BregeCore
import SwiftUI

/// The pressure chart. A plain line with a soft fill: a day of readings, newest on the right.
struct PressureChart: View {
    let points: [PressurePointData]
    var showsScale = false

    private var range: (low: Float, high: Float) {
        let values = points.map(\.hpa)
        let low = values.min() ?? 1000
        let high = values.max() ?? 1010
        // A dead flat day would draw a line through the middle, which reads as "no data".
        return high - low < 1 ? (low - 0.5, high + 0.5) : (low, high)
    }

    /// The readings as points in the given box, newest on the right.
    private func plot(in size: CGSize) -> [CGPoint] {
        let (low, high) = range
        let span = max(high - low, 0.1)
        let inset: CGFloat = 4
        let height = size.height - inset * 2
        let stepX = points.count > 1 ? size.width / CGFloat(points.count - 1) : 0
        return points.enumerated().map { index, point in
            CGPoint(x: CGFloat(index) * stepX,
                    y: inset + CGFloat((high - point.hpa) / span) * height)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let plotted = plot(in: geo.size)
            ZStack(alignment: .topLeading) {
                if let first = plotted.first, let last = plotted.last, plotted.count > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: geo.size.height))
                        path.addLine(to: first)
                        for point in plotted.dropFirst() { path.addLine(to: point) }
                        path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height))
                        path.closeSubpath()
                    }
                    .fill(Color.accentColor.opacity(0.12))

                    Path { path in
                        path.move(to: first)
                        for point in plotted.dropFirst() { path.addLine(to: point) }
                    }
                    .stroke(Color.accentColor,
                            style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))

                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: 5, height: 5)
                        .position(x: last.x - 2, y: last.y)

                    if showsScale {
                        VStack(alignment: .leading) {
                            Text(String(format: "%.0f", range.high)).font(.system(size: 9))
                            Spacer()
                            Text(String(format: "%.0f", range.low)).font(.system(size: 9))
                        }
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Collecting readings…")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
        }
    }
}

/// One reading with its label, used in the card and in the window.
private struct Reading: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.system(size: 12, weight: .semibold))
                Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            }
        }
    }
}

/// The Conditions card in the menu, under the tiles.
struct ConditionsCard: View {
    @EnvironmentObject private var model: AppModel
    let device: Device
    @ObservedObject var conditions: ConditionsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let c = conditions.latest {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "barometer").font(.system(size: 13))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(ConditionsModel.forecast(c)).font(.system(size: 13, weight: .semibold))
                        Text(ConditionsModel.trendLine(c)).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if c.hasBarometer, abs(c.pressureDelta3h) >= 0.3 {
                        Text(ConditionsModel.delta(c))
                            .font(.system(size: 11, weight: .semibold))
                            .monospacedDigit()
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                    }
                }

                if c.hasBarometer, conditions.points.count > 1 {
                    PressureChart(points: conditions.points).frame(height: 54)
                }

                Divider()

                HStack(spacing: 12) {
                    Reading(icon: "sun.max", value: ConditionsModel.light(c),
                            label: ConditionsModel.lightDetail(c))
                    Spacer()
                    Reading(icon: "thermometer.medium",
                            value: String(format: "%.1f °C", c.batteryTempC), label: "battery")
                    Spacer()
                    if c.chargeWatts > 0.1 {
                        Reading(icon: "bolt.fill", value: String(format: "%.1f W", c.chargeWatts),
                                label: "charging")
                    } else {
                        Reading(icon: "cpu", value: ConditionsModel.thermal(c.thermalStatus), label: "thermal")
                    }
                }

                Button("Conditions…") { model.openConditions(deviceId: device.id) }
                    .buttonStyle(.link)
                    .font(.system(size: 11))
            } else {
                Label(device.connected ? "Asking the phone…" : "Phone not connected",
                      systemImage: device.connected ? "ellipsis" : "wifi.slash")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 9))
        .onAppear { conditions.refresh(device, hours: 24) }
    }
}

/// The Conditions window: the full chart, every reading, and what the Mac does about them.
struct ConditionsView: View {
    @EnvironmentObject private var app: AppModel
    @ObservedObject var model: ConditionsModel
    @State private var faceDownQuiet = ConditionsAutomation.faceDownQuiet
    @State private var darkRoomAppearance = ConditionsAutomation.darkRoomAppearance

    private var device: Device? { app.device(model.deviceId) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let c = model.latest {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ConditionsModel.forecast(c)).font(.title2.weight(.semibold))
                        Text(ConditionsModel.trendLine(c)).font(.callout).foregroundStyle(.secondary)
                    }

                    if c.hasBarometer {
                        VStack(alignment: .leading, spacing: 6) {
                            PressureChart(points: model.points, showsScale: true)
                                .frame(height: 150)
                                .padding(10)
                                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                            HStack {
                                Text("24 hours ago").font(.caption2).foregroundStyle(.secondary)
                                Spacer()
                                Text("now").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }

                    HStack(spacing: 8) {
                        card("Room light", ConditionsModel.light(c), ConditionsModel.lightDetail(c))
                        card("Battery", String(format: "%.1f °C", c.batteryTempC),
                             c.chargeWatts > 0.1 ? "charging" : "not charging")
                        card("Charge", c.chargeWatts > 0.1 ? String(format: "%.1f W", c.chargeWatts) : "—",
                             c.chargeWatts > 0.1
                                ? String(format: "%.2f A · %.2f V", abs(c.chargeAmps), c.chargeVolts)
                                : "on battery")
                        card("Thermal", ConditionsModel.thermal(c.thermalStatus),
                             c.thermalStatus == 0 ? "no throttling" : "throttling")
                    }

                    if c.hasBarometer, abs(c.altitudeDeltaM) >= 3 {
                        Label(String(format: "%@ %.0f m since the oldest reading — from the pressure alone.",
                                     c.altitudeDeltaM > 0 ? "Up" : "Down", abs(c.altitudeDeltaM)),
                              systemImage: c.altitudeDeltaM > 0 ? "arrow.up" : "arrow.down")
                            .font(.callout)
                            .padding(.horizontal, 11).padding(.vertical, 9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))
                    }

                    VStack(alignment: .leading, spacing: 7) {
                        Text("Automations").font(.caption.weight(.semibold)).foregroundStyle(.secondary)

                        automation(
                            title: "Phone face down → this Mac holds phone notifications",
                            detail: c.hasAccelerometer
                                ? "Calls, files and Brêge's own messages still come through."
                                : "This phone reports no motion sensor.",
                            isOn: $faceDownQuiet,
                            enabled: c.hasAccelerometer
                        ) {
                            ConditionsAutomation.faceDownQuiet = $0
                            model.refresh(device) // the phone starts or stops watching
                        }

                        automation(
                            title: "Room goes dark → this Mac switches to dark mode",
                            detail: c.hasLight
                                ? "Below 20 lx for two minutes. macOS asks once for permission to switch."
                                : "This phone reports no light sensor.",
                            isOn: $darkRoomAppearance,
                            enabled: c.hasLight
                        ) { ConditionsAutomation.darkRoomAppearance = $0 }
                    }

                    Text("One reading a minute, batched on the phone, and only while a Mac is connected.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "barometer").font(.largeTitle).foregroundStyle(.secondary)
                        Text(model.asking ? "Asking the phone…"
                             : device?.connected == true ? "Nothing yet" : "Phone not connected")
                            .font(.headline)
                        Text("The phone collects a reading a minute while it is connected.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 280)
                }
            }
            .padding(16)
        }
        .navigationTitle(device.map { "Conditions — \($0.name)" } ?? "Conditions")
        .toolbar {
            Button { model.refresh(device) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(device?.connected != true)
        }
        .frame(minWidth: 460, minHeight: 520)
        .onAppear { model.refresh(device) }
    }

    private func card(_ label: String, _ value: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .semibold))
            Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))
    }

    private func automation(title: String, detail: String, isOn: Binding<Bool>,
                            enabled: Bool, onChange: @escaping (Bool) -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(!enabled)
                .onChange(of: isOn.wrappedValue) { onChange($0) }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 11).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 9))
    }
}
