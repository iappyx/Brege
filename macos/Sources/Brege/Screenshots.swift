import AppKit
import BregeCore
import SwiftUI

/// `Brege --screenshots <folder>`: renders Brêge's windows for the README with made-up phones,
/// conversations and photos. The core is not started, and nothing real (Keychain, database,
/// networks, notifications) is read, so the images cannot contain private data.
@MainActor
enum Screenshots {
    static var isActive: Bool { folder != nil }

    static let folder: URL? = {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--screenshots"), index + 1 < arguments.count else { return nil }
        return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
    }()

    static func run() {
        guard let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSApp.appearance = NSAppearance(named: CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)
        let model = AppModel.shared
        let now = Int64(Date().timeIntervalSince1970 * 1000)

        let pixel = Device(id: "screenshot-pixel", shortId: "", name: "Pixel 10 Pro", platform: .android, connected: true, lastSeenMs: now)
        let tablet = Device(id: "screenshot-tablet", shortId: "", name: "OnePlus Pad", platform: .android, connected: true, lastSeenMs: now)
        let load = { (devices: [Device], paths: [NetworkPathData]) in
            model.loadScreenshotData(
                devices: devices,
                statuses: [
                    pixel.id: StatusData(batteryPct: 82, charging: false, signalBars: 4, networkType: "5G", dnd: false, volumePct: 60),
                    tablet.id: StatusData(batteryPct: 64, charging: true, signalBars: 0, networkType: "", dnd: false, volumePct: 40),
                ],
                media: [pixel.id: MediaData(appLabel: "Music", title: "Blue in Green", artist: "The Quiet Quartet",
                                            playing: true, positionMs: 61_000, durationMs: 337_000)],
                unread: [pixel.id: 2],
                transfers: devices.count > 1 ? [AppModel.Transfer(id: "t1", name: "Boarding pass.pdf", bytes: 182_000, total: 182_000,
                                                                  incoming: true, done: true, failed: nil)] : [],
                networkPaths: paths,
                knownNetworks: [
                    KnownNetworkData(fingerprint: "a", isVpn: false, label: "Wi‑Fi “Home”", lastUsedMs: now, trusted: true),
                    KnownNetworkData(fingerprint: "b", isVpn: true, label: "VPN 10.8.0.2 (utun4)", lastUsedMs: now, trusted: true),
                    KnownNetworkData(fingerprint: "c", isVpn: false, label: "Wi‑Fi “Café Central”", lastUsedMs: now, trusted: false),
                ],
                phoneApps: [pixel.id: apps]
            )
        }
        load([pixel, tablet], [])
        model.recentPhotos(for: pixel.id).loadScreenshotData(photos, deviceId: pixel.id)
        model.live.updated(OngoingActivityData(
            key: "timer", package: "com.example.clock", appLabel: "Clock", title: "Timer", text: "Pasta",
            shortText: "", progress: 0, progressMax: 0, indeterminate: false,
            chronometerBaseMs: now + 7 * 60_000 + 42_000, countsDown: true, iconPng: Data(), actions: [], updatedMs: now
        ), from: pixel.id)
        let messages = model.messages(for: pixel.id)
        messages.loadScreenshotData(threads: threads(now: now), messages: conversation(now: now), selected: "sms:1")

        capture(MenuPanel(), size: CGSize(width: 340, height: 720), name: "menu", fitHeight: true)
        capture(MessagesView(model: messages), size: CGSize(width: 900, height: 600), name: "messages", title: "Messages — Pixel 10 Pro")
        capture(PhoneAppsWindow(deviceId: pixel.id), size: CGSize(width: 520, height: 460), name: "phone-apps", title: "Phone Apps — Pixel 10 Pro")
        captureWindow(SettingsOpener.makeWindow(tab: 1), name: "settings-phones")

        // A new network while the phone is away: Brêge asks before using it.
        var away = pixel
        away.connected = false
        model.live.ended(key: "timer", from: pixel.id)
        load([away], [NetworkPathData(fingerprint: "cafe", isVpn: false, label: "Wi‑Fi “Café Central”", ssid: "Café Central",
                                      trusted: false, declined: false, blockedDeviceIds: [])])
        capture(MenuPanel(), size: CGSize(width: 340, height: 400), name: "menu-new-network", fitHeight: true)

        NSApp.terminate(nil)
    }

    /// The menu bar popover's content on the window background it has in the menu bar.
    private struct MenuPanel: View {
        var body: some View {
            MenuContentView()
                .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private static func capture(_ view: some View, size: CGSize, name: String, title: String? = nil, fitHeight: Bool = false) {
        let host = NSHostingController(rootView: view.environmentObject(AppModel.shared))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: title == nil ? [.borderless] : [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.contentViewController = host
        if #available(macOS 14.0, *) { host.sceneBridgingOptions = [.toolbars, .title] }
        window.title = title ?? ""
        if fitHeight {
            host.view.layoutSubtreeIfNeeded()
            let fitting = host.view.fittingSize
            window.setContentSize(CGSize(width: size.width, height: min(size.height, max(fitting.height, 100))))
        } else {
            window.setContentSize(size)
        }
        captureWindow(window, name: name, bordered: title != nil)
    }

    private static func captureWindow(_ window: NSWindow, name: String, bordered: Bool = true) {
        window.setFrameOrigin(NSPoint(x: 40, y: 40))
        window.alphaValue = 0.001 // laid out and drawn, but not visible on screen
        window.orderFrontRegardless()
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))
        guard let view = bordered ? window.contentView?.superview : window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        window.orderOut(nil)
        // Materials (sidebars, glass) are drawn by the window server and come out transparent:
        // put the image on the window background.
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        bitmap.size = rep.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let rect = NSRect(origin: .zero, size: rep.size)
        (window.backgroundColor ?? .windowBackgroundColor).setFill()
        NSBezierPath(roundedRect: rect, xRadius: bordered ? 12 : 0, yRadius: bordered ? 12 : 0).fill()
        rep.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        guard let folder, let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: folder.appendingPathComponent("\(name).png"))
    }

    // MARK: Made-up content

    private static var photos: [RecentPhotosModel.Item] {
        let palettes: [(NSColor, NSColor, String)] = [
            (.systemOrange, .systemPink, "sun.horizon.fill"),
            (.systemTeal, .systemBlue, "water.waves"),
            (.systemGreen, .systemMint, "leaf.fill"),
            (.systemIndigo, .systemPurple, "moon.stars.fill"),
            (.systemGray, .darkGray, "iphone.gen3"),
        ]
        return palettes.enumerated().map { index, palette in
            RecentPhotosModel.Item(id: "p\(index)", name: "IMG_\(4210 + index).jpg", screenshot: index == 4,
                                   mime: "image/jpeg", thumbnail: tile(palette.0, palette.1, palette.2, size: 96))
        }
    }

    private static var apps: [PhoneApp] {
        let list: [(String, String, NSColor)] = [
            ("Calendar", "calendar", .systemRed), ("Camera", "camera.fill", .darkGray), ("Clock", "clock.fill", .black),
            ("Files", "folder.fill", .systemBlue), ("Maps", "map.fill", .systemGreen), ("Music", "music.note", .systemPink),
            ("Notes", "note.text", .systemYellow), ("Photos", "photo.on.rectangle", .systemOrange),
            ("Podcasts", "mic.fill", .systemPurple), ("Translate", "character.bubble.fill", .systemTeal),
            ("Weather", "cloud.sun.fill", .systemCyan), ("Wallet", "wallet.pass.fill", .systemIndigo),
        ]
        return list.map { PhoneApp(package: "com.example.\($0.0.lowercased())", label: $0.0, icon: tile($0.2, $0.2.blended(withFraction: 0.35, of: .white) ?? $0.2, $0.1, size: 96)) }
    }

    private static func threads(now: Int64) -> [ThreadData] {
        let minute: Int64 = 60_000
        return [
            ThreadData(id: "sms:1", addresses: ["+15550142"], names: ["Sam Visser"], title: "", snippet: "See you at 7 at the station 🙂",
                       lastMs: now - 3 * minute, kind: .sms, canReply: true, unread: true),
            ThreadData(id: "rcs:2", addresses: ["+15550199", "+15550123", "+15550188"], names: ["Lena", "Joris", "Mara"], title: "Weekend trip",
                       snippet: "Lena: I'll bring the tent", lastMs: now - 42 * minute, kind: .rcs, canReply: true, unread: true),
            ThreadData(id: "sms:3", addresses: ["+15550107"], names: ["Mum"], title: "", snippet: "Did you get home ok?",
                       lastMs: now - 180 * minute, kind: .sms, canReply: true, unread: false),
            ThreadData(id: "sms:4", addresses: ["ExampleBank"], names: [""], title: "", snippet: "Your verification code is 481902",
                       lastMs: now - 300 * minute, kind: .sms, canReply: false, unread: false),
            ThreadData(id: "sms:5", addresses: ["+15550166"], names: ["Pizzeria Roma"], title: "", snippet: "Your order is on its way",
                       lastMs: now - 1500 * minute, kind: .sms, canReply: true, unread: false),
        ]
    }

    private static func conversation(now: Int64) -> [MessageData] {
        let minute: Int64 = 60_000
        let lines: [(String, Bool, Int64)] = [
            ("Are we still on for tonight?", false, 58),
            ("Yes! Train gets in at 18:52", true, 55),
            ("Perfect. Shall we get food first?", false, 20),
            ("Sounds good, you pick the place", true, 12),
            ("See you at 7 at the station 🙂", false, 3),
        ]
        return lines.enumerated().map { index, line in
            MessageData(id: "m\(index)", threadId: "sms:1", address: "+15550142", senderName: line.1 ? "" : "Sam Visser",
                        body: line.0, tsMs: now - line.2 * minute, outgoing: line.1, subId: -1,
                        status: line.1 ? .sent : .received, hasMedia: false, kind: .sms)
        }
    }

    private static func tile(_ top: NSColor, _ bottom: NSColor, _ symbol: String, size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSGradient(starting: top, ending: bottom)?.draw(in: NSBezierPath(roundedRect: rect, xRadius: size * 0.22, yRadius: size * 0.22), angle: -90)
            let configuration = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            if let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                let origin = NSPoint(x: rect.midX - glyph.size.width / 2, y: rect.midY - glyph.size.height / 2)
                glyph.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
            }
            return true
        }
    }
}
