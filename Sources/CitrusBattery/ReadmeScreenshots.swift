#if DEBUG
import AppKit
import CitrusKit
import SwiftUI

/// Reproducible documentation images of the actual views. All identities and
/// readings are fictional; history exists only in an in-memory database.
@MainActor
enum ReadmeScreenshots {
    static let date = ISO8601DateFormatter().date(from: "2026-10-21T09:41:00Z")!

    static func render(to directory: URL) throws {
        _ = NSApplication.shared
        let previousApp = NSWorkspace.shared.frontmostApplication
        defer { previousApp?.activate(options: []) }
        NSApp.setActivationPolicy(.accessory)
        NSApp.finishLaunching()
        NSApp.activate(ignoringOtherApps: true)
        NSApp.appearance = NSAppearance(named: .aqua)
        UserDefaults.standard.setVolatileDomain([
            PreferenceKey.temperatureUnit: "celsius",
            PreferenceKey.capacityUnit: "milliampHours",
            PreferenceKey.capacityStyle: "raw",
            PreferenceKey.updateInterval: "delayed",
            PreferenceKey.powerChartPeriod: PowerPeriod.day.rawValue,
            PreferenceKey.sleepPeriod: SleepPeriod.week.rawValue,
            PreferenceKey.appEnergyPeriod: AppEnergyPeriod.day.rawValue,
            PreferenceKey.autosaveNewDevices: true,
            "AppleLocale": "en_GB",
            "AppleLanguages": ["en"],
        ], forName: UserDefaults.argumentDomain)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let monitor = makeMonitor()
        let devices = IOSDeviceMonitor(sampleDevices: [makeDevice(isPad: false), makeDevice(isPad: true)])
        let store = try HistoryStore(url: nil)
        for index in 0..<90 {
            let capacity = 4694 - index * 2 + [0, 8, -3, 5, -6, 2][index % 6]
            try store.insert(HistoryEntry(
                date: date.addingTimeInterval(Double(index - 89) * 2 * 86400),
                deviceType: .mac, deviceSerial: "DEMO-MAC-001",
                deviceName: "MacBook Air", deviceModel: "Mac16,12", osVersion: "macOS 26.0",
                batterySerial: "DEMO-BATTERY-001", cycleCount: 18 + index,
                designCapacity: 4629, fullChargeCapacity: capacity))
        }
        // A year of iPhone readings, so its page shows a health forecast.
        for index in 0..<60 {
            let capacity = 3582 - index * 3 + [0, 6, -4, 3, -5, 1][index % 6]
            try store.insert(HistoryEntry(
                date: date.addingTimeInterval(Double(index - 59) * 6 * 86400),
                deviceType: .iOS, deviceSerial: "DEMO-IPHONE-001",
                deviceName: "My iPhone", deviceModel: "iPhone17,1", osVersion: "iOS 26.0",
                batterySerial: nil, cycleCount: 40 + index * 2,
                designCapacity: 3582, fullChargeCapacity: capacity))
        }
        try insertSampleSleeps(into: store)
        try insertSamplePower(into: store)
        try insertSampleAppEnergy(into: store)
        // The live lists read this Mac's own apps; show fictional ones instead.
        SleepBlockerMonitor.sample = [
            SleepBlocker(owner: "/System/Applications/Music.app", reason: "Playing audio",
                         since: Date().addingTimeInterval(-25 * 60)),
            SleepBlocker(owner: "/System/Applications/Utilities/Terminal.app", process: "caffeinate",
                         since: Date().addingTimeInterval(-72 * 60)),
        ]
        SignificantEnergyMonitor.sample = [
            SignificantEnergyApp(bundleIdentifier: "com.apple.Safari", displayName: "Safari", energyImpact: 2400),
        ]
        let history = HistoryController(monitor: monitor, iosDevices: devices, store: store)
        let navigator = Navigator()

        func dependencies<V: View>(_ view: V, monitor: BatteryMonitor = monitor) -> some View {
            view.environmentObject(monitor)
                .environmentObject(devices)
                .environmentObject(history)
                .environmentObject(navigator)
                .environment(\.locale, Locale(identifier: "en_GB"))
        }

        navigator.selection = .thisMac
        try capture(dependencies(ContentView()), title: "This Mac", size: NSSize(width: 1000, height: 780),
                    to: directory.appendingPathComponent("mac-dashboard.png"))
        // Scrolled down to power history, the charger check and sleep drain, while charging.
        let charging = makeMonitor(charging: true)
        try capture(dependencies(ContentView(), monitor: charging), title: "This Mac",
                    size: NSSize(width: 1000, height: 780), scrolledTo: 600,
                    to: directory.appendingPathComponent("mac-power.png"))
        navigator.selection = .device("demo-iphone")
        try capture(dependencies(ContentView()), title: "iPhone", size: NSSize(width: 1000, height: 780),
                    to: directory.appendingPathComponent("iphone.png"))
        navigator.selection = .history
        try capture(dependencies(ContentView()), title: "History", size: NSSize(width: 1100, height: 780),
                    to: directory.appendingPathComponent("history.png"))
        navigator.selection = .sleep
        // Tall enough for the summary, advice, chart and reasons to leave the table room.
        try capture(dependencies(ContentView()), title: "Sleep", size: NSSize(width: 1100, height: 1000),
                    to: directory.appendingPathComponent("sleep.png"))
        // The night with the most brief wakes, as when picking it and choosing Show Details.
        let sessions = try store.sleepSessions(mac: "DEMO-MAC-001")
        let wakes = try store.darkWakes(mac: "DEMO-MAC-001")
        if let busiest = sessions.max(by: {
            WakeBreakdown.wakes(wakes, during: [$0]).count < WakeBreakdown.wakes(wakes, during: [$1]).count
        }) {
            let title = busiest.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)
                .hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits)) + " – "
                + busiest.end.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)
                    .hour(.twoDigits(amPM: .abbreviated)).minute(.twoDigits))
            try capture(dependencies(WakeDetailsView(title: title, sessions: [busiest],
                                                     wakes: WakeBreakdown.wakes(wakes, during: [busiest]))),
                        title: "Wake Details", size: NSSize(width: 780, height: 640),
                        to: directory.appendingPathComponent("wake-details.png"))
        }
        navigator.selection = .thisMac
        try capture(dependencies(ContentView()), title: "This Mac", size: NSSize(width: 1000, height: 780),
                    scrolledTo: 1060, to: directory.appendingPathComponent("mac-energy.png"))
        navigator.selection = .settings
        navigator.settingsSection = .menuBar
        try capture(dependencies(ContentView()).environmentObject(AppUpdater())
                        .environmentObject(Notifier(monitor: monitor, iosDevices: devices)),
                    title: "Settings", size: NSSize(width: 1000, height: 780),
                    to: directory.appendingPathComponent("settings.png"))
        try capture(dependencies(LifetimeAnalyzer()), title: "Battery Lifetime Data", size: NSSize(width: 920, height: 690),
                    to: directory.appendingPathComponent("lifetime.png"))
        try capture(dependencies(AdvancedViewer(sampleSections: advancedSections)), title: "Advanced Viewer",
                    size: NSSize(width: 920, height: 690), to: directory.appendingPathComponent("advanced.png"))
        try renderMenuBar(dependencies(MenuBarScene()).environmentObject(AppUpdater()),
                          to: directory.appendingPathComponent("menu-bar.png"))
    }

    /// The status item, with macOS's own battery icon, and its panel open below.
    private struct MenuBarScene: View {
        var body: some View {
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 16) {
                    MenuBarLabel(inMenuBar: false)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.black.opacity(0.1), in: Capsule())
                    Image(systemName: "wifi")
                    Image(systemName: "switch.2")
                    Text("Wed 21 Oct  10:41")
                }
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .trailing)
                .background(Color.white.opacity(0.55))
                MenuBarPanel()
                    .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color(white: 0.965))
                        .shadow(color: .black.opacity(0.18), radius: 18, y: 8))
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.black.opacity(0.08)))
                    .padding(.trailing, 150)
            }
            .frame(width: 640)
            .padding(.bottom, 30)
            .environment(\.colorScheme, .light)
        }
    }

    /// Renders a SwiftUI scene onto the backdrop without a window frame, captured
    /// from a borderless window at its natural size: an image renderer clips the
    /// panel, and can't draw the materials of an app built with the macOS 26 SDK.
    private static func renderMenuBar<V: View>(_ view: V, to url: URL) throws {
        let hosting = NSHostingView(rootView: view)
        hosting.frame.size = hosting.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.center()
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        // Rows added once the panel's lists start can change its height.
        if hosting.fittingSize != window.frame.size {
            window.setContentSize(hosting.fittingSize)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        }
        let image = try screenImage(of: window)
        window.close()
        let size = NSSize(width: 1200, height: 960)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
            pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current!.cgContext.scaleBy(x: 2, y: 2)
        NSGradient(starting: NSColor(red: 0.93, green: 0.96, blue: 0.89, alpha: 1),
                   ending: NSColor(red: 0.99, green: 0.97, blue: 0.90, alpha: 1))!
            .draw(in: NSRect(origin: .zero, size: size), angle: -35)
        let fit = min((size.width - 120) / image.size.width, (size.height - 80) / image.size.height)
        let drawn = NSSize(width: image.size.width * fit, height: image.size.height * fit)
        image.draw(in: NSRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2,
                              width: drawn.width, height: drawn.height))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
        print("Rendered \(url.lastPathComponent)")
    }

    /// The window as it appears on screen, at its size in points.
    private static func screenImage(of window: NSWindow) throws -> NSImage {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("citrus-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: file) }
        let screencapture = Process()
        screencapture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // No sound, no shadow (the backdrop draws its own), just this window.
        screencapture.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]
        try screencapture.run()
        screencapture.waitUntilExit()
        guard screencapture.terminationStatus == 0, let image = NSImage(contentsOf: file) else {
            throw CocoaError(.fileWriteUnknown)
        }
        image.size = window.frame.size
        return image
    }

    /// Two weeks of nights on battery, with the brief wakes macOS made and why.
    /// Already marked as read, so no logs on this Mac are consulted.
    private static func insertSampleSleeps(into store: HistoryStore) throws {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())
        let tasks = ["com.apple.photoanalysisd.backgroundanalysis", "com.apple.mail.fetch",
                     "com.apple.softwareupdated.scan"]
        var wakes: [DarkWake] = []
        for night in 1...14 {
            let start = today.addingTimeInterval(Double(-night) * 86_400 + 23 * 3600 + Double((night * 7) % 40) * 60)
            let hours = 7 + Double((night * 5) % 4) / 2
            let end = start.addingTimeInterval(hours * 3600)
            // One night an app kept waking the Mac; the rest are ordinary.
            let busy = night == 4
            let lossPerHour = busy ? 0.016 : 0.0022 + Double(night % 4) * 0.0006
            let count = Int(hours * (busy ? 16 : Double(4 + night % 3)))
            for index in 0..<count {
                let at = start.addingTimeInterval(((Double(index) + 0.5) * hours * 3600 / Double(count)).rounded())
                let wake: DarkWake
                switch busy ? index % 4 : index % 10 {
                case 0...3:
                    let task = busy ? tasks[0] : tasks[index % 3]
                    wake = DarkWake(date: at, reason: .scheduledTask, detail: task, seconds: 4 + index % 7,
                                    holders: ["powerd", "cloudd"],
                                    apps: task.contains("photo") ? ["com.apple.Photos"] : task.contains("mail")
                                        ? ["com.apple.mail"] : [], mac: "DEMO-MAC-001")
                case 4...6:
                    wake = DarkWake(date: at, reason: .pushNotification, seconds: 3 + index % 4,
                                    holders: ["powerd"], mac: "DEMO-MAC-001")
                case 7...8:
                    wake = DarkWake(date: at, reason: .networkUpkeep, seconds: 5 + index % 5,
                                    holders: ["mDNSResponder"], mac: "DEMO-MAC-001")
                default:
                    wake = DarkWake(date: at, reason: .wireless, seconds: 2 + index % 3, mac: "DEMO-MAC-001")
                }
                wakes.append(wake)
            }
            try store.insert(SleepSession(start: start, end: end, startCapacity: 3900,
                                          endCapacity: 3900 - Int(lossPerHour * hours * 4518), fullChargeCapacity: 4518,
                                          briefWakes: count, wakesLogged: true, appsLogged: true, mac: "DEMO-MAC-001"))
        }
        try store.insert(wakes, loggedSessions: [])
    }

    /// A week of hourly energy for a few built-in apps, so their icons and names
    /// are real while the figures are fictional.
    private static func insertSampleAppEnergy(into store: HistoryStore) throws {
        let joulesPerHour: [String: Double] = [
            "/Applications/Safari.app": 950, "/System/Applications/Photos.app": 430,
            "/System/Applications/Music.app": 310, "/System/Applications/Mail.app": 170,
            "/System/Applications/Messages.app": 90, "/System/Applications/Notes.app": 45,
        ]
        let now = Date()
        for hour in 0..<(7 * 24) {
            let at = now.addingTimeInterval(-Double(hour) * 3600)
            let busy = 0.6 + 0.4 * sin(Double(hour) / 3)
            try store.addAppUsage(joulesPerHour.mapValues { AppUsage(joules: $0 * busy, cpuSeconds: $0 * busy / 9) },
                                  at: at, onBattery: hour % 3 != 0)
        }
    }

    /// A week of power readings: working days with a charge in the morning and
    /// the Mac asleep each night.
    private static func insertSamplePower(into store: HistoryStore) throws {
        // The chart ends at the current time, so the sample does too.
        let now = Date()
        let calendar = Calendar(identifier: .gregorian)
        var charge = 80.0
        var minute = now.addingTimeInterval(-7 * 86_400)
        while minute < now {
            let hour = calendar.component(.hour, from: minute)
            if hour >= 23 || hour < 7 {
                let wake = calendar.date(bySettingHour: 7, minute: 0, second: 0,
                                         of: hour >= 23 ? minute.addingTimeInterval(86_400) : minute)!
                try store.insertSleepPeriod(DateInterval(start: minute, end: min(wake, now)))
                // Brief wakes with the screen off, every hour or so.
                var dark = minute.addingTimeInterval(2400)
                while dark.addingTimeInterval(60) < min(wake, now) {
                    try store.insert(PowerMinute(start: dark, averageWatts: 0.6, peakWatts: 1.2,
                                                 chargePercent: Int(charge), onAdapter: false))
                    dark.addTimeInterval(3600 + Double(Int(dark.timeIntervalSince1970) % 1200))
                }
                charge -= wake.timeIntervalSince(minute) / 3600 * 0.3
                minute = wake
                continue
            }
            let index = minute.timeIntervalSince1970 / 60
            let plugged = (9..<11).contains(hour)
            let burst = Int(index) % 97 < 6 ? 14.0 : 0
            let watts = 5.5 + 2 * sin(index / 13) + burst
            charge = plugged ? min(charge + 0.6, 95) : max(charge - watts / 50 * 1.6 / 6, 8)
            try store.insert(PowerMinute(start: minute, averageWatts: watts, peakWatts: watts + 3 + burst / 2,
                                         chargePercent: Int(charge), onAdapter: plugged))
            minute += 60
        }
    }

    private static func makeMonitor(charging: Bool = false) -> BatteryMonitor {
        var registry: [String: Any] = [
            "AppleRawCurrentCapacity": 3709, "AppleRawMaxCapacity": 4518, "DesignCapacity": 4629,
            "NominalChargeCapacity": 4546, "CycleCount": 107, "DesignCycleCount9C": 1000,
            "Temperature": 2860, "Voltage": 11720, "Amperage": -530,
            "IsCharging": false, "ExternalConnected": false, "FullyCharged": false,
            "AvgTimeToEmpty": 420, "Serial": "DEMO-BATTERY-001", "Manufacturer": "Sunwoda",
            "DeviceName": "bq40z651", "ManufactureDate": ((2025 - 1980) << 9) | (12 << 5) | 3,
            "LifetimeData": lifetimeData(hours: 7728, cycles: 103),
        ]
        if charging {
            // A 30 W charger running flat out, so the charger check has something to say.
            registry.merge([
                "AppleRawCurrentCapacity": 2800, "Amperage": 1820, "IsCharging": true, "ExternalConnected": true,
                "AvgTimeToFull": 95, "AvgTimeToEmpty": 65535,
                "AdapterDetails": [
                    "Watts": 30, "Name": "30W USB-C Power Adapter", "Manufacturer": "Apple Inc.",
                    "AdapterVoltage": 20000, "Current": 1500, "UsbHvcHvcIndex": 3,
                    "UsbHvcMenu": [[5000, 3000], [9000, 3000], [15000, 2000], [20000, 1500]].enumerated().map {
                        ["Index": $0.offset, "MaxVoltage": $0.element[0], "MaxCurrent": $0.element[1]]
                    },
                ] as [String: Any],
                "PowerTelemetryData": ["SystemPowerIn": 28_600],
            ]) { $1 }
        }
        let battery = MacBatterySnapshot(registry: registry, smc: nil, powerSource: charging
            ? PowerSourceInfo(chargePercent: 62, timeToFullMinutes: 95)
            : PowerSourceInfo(chargePercent: 82, timeToEmptyMinutes: 420), date: date)
        let now = Date()
        let samples = (0..<61).map { index in
            let t = Double(index)
            let watts = 6.3 + 0.7 * sin(t * 0.43) + 0.4 * cos(t * 0.9)
                + 5.4 * exp(-pow((t - 21) / 4, 2)) + 2.8 * exp(-pow((t - 43) / 5, 2))
            return PowerSample(date: now.addingTimeInterval((t - 60) * 2), systemWatts: watts)
        }
        return BatteryMonitor(sampleBattery: battery, info: MacInfo(
            modelIdentifier: "Mac16,12", modelNumber: "MW123B/A", serialNumber: "DEMO-MAC-001",
            chip: "Apple M4", osVersion: "macOS 26.0", bootDate: date.addingTimeInterval(-2 * 86400)),
            name: "MacBook Air (13-inch, M4, 2025)",
            power: PowerReadings(systemWatts: 6.4, adapterWatts: charging ? 28.6 : 0, cpuTemperatureCelsius: 38.2),
            history: samples, limit: ChargeLimitStatus(optimizedChargingEnabled: true))
    }

    private static func makeDevice(isPad: Bool) -> TrackedDevice {
        let design = isPad ? 8588 : 3582
        let full = isPad ? 8375 : 3518
        let charge = isPad ? 88 : 64
        var lifetime = lifetimeData(hours: isPad ? 6984 : 7584, cycles: isPad ? 61 : 139)
        lifetime["MinimumPackVoltage"] = isPad ? 6800 : 3200
        lifetime["MaximumPackVoltage"] = isPad ? 8800 : 4450
        let snapshot = IOSDeviceSnapshot(
            udid: isPad ? "demo-ipad" : "demo-iphone", connection: isPad ? .wifi : .usb,
            info: ["DeviceName": isPad ? "Studio iPad" : "My iPhone",
                   "ProductType": isPad ? "iPad16,3" : "iPhone17,1", "ProductVersion": "26.0",
                   "SerialNumber": isPad ? "DEMO-IPAD-001" : "DEMO-IPHONE-001",
                   "ModelNumber": isPad ? "MVV83" : "MYNG3", "RegionInfo": "B/A"],
            battery: ["CurrentCapacity": charge, "MaxCapacity": 100,
                      "AppleRawCurrentCapacity": full * charge / 100, "AppleRawMaxCapacity": full,
                      "DesignCapacity": design, "CycleCount": isPad ? 64 : 142,
                      "Temperature": isPad ? 2540 : 3020, "Voltage": 3980,
                      "Amperage": isPad ? -450 : 2380, "IsCharging": !isPad,
                      "ExternalConnected": !isPad, "FullyCharged": false,
                      "Serial": isPad ? "DEMO-IPAD-BATTERY" : "DEMO-IPHONE-BATTERY",
                      "Manufacturer": "Sunwoda", "DeviceName": "Battery gas gauge",
                      "ManufactureDate": ((2025 - 1980) << 9) | (11 << 5) | 12,
                      "AdapterDetails": isPad ? [:] : ["Watts": 20, "Name": "USB-C Power Adapter"],
                      "LifetimeData": lifetime],
            gestalt: ["MarketingName": isPad ? "iPad Pro (11-inch, M4)" : "iPhone 16 Pro"], date: date)
        return TrackedDevice(udid: snapshot.udid, state: .ready, connection: snapshot.connection,
                             snapshot: snapshot, lastSeen: date)
    }

    private static func lifetimeData(hours: Int, cycles: Int) -> [String: Any] {
        ["TotalOperatingTime": hours, "MinimumTemperature": 12, "MaximumTemperature": 41,
         "AverageTemperature": 264, "MinimumPackVoltage": 10120, "MaximumPackVoltage": 13180,
         "MaximumChargeCurrent": 4280, "MaximumDischargeCurrent": -5960,
         "TemperatureSamples": 48216, "CycleCountLastQmax": cycles,
         "UpdateTime": Int(date.timeIntervalSince1970)]
    }

    private static var advancedSections: [InfoNode] {
        [InfoNode("Mac", children: [
            InfoNode("Model", "MacBook Air (13-inch, M4, 2025)"),
            InfoNode("Model identifier", "Mac16,12"), InfoNode("Chip", "Apple M4"),
            InfoNode("macOS", "26.0"), InfoNode("Serial number", "DEMO-MAC-001"),
        ]), InfoNode("Storage", children: [
            InfoNode("APPLE SSD AP0512Z", children: [
                InfoNode("Capacity", "512 GB"), InfoNode("Life used", "1%"),
                InfoNode("Data read", "8.42 TB"), InfoNode("Data written", "5.16 TB"),
                InfoNode("Power-on hours", "1,284 h"), InfoNode("Unsafe shutdowns", "0"),
                InfoNode("Media errors", "0"), InfoNode("Temperature", "32 °C"),
            ]),
        ]), InfoNode("Displays", children: [
            InfoNode("Built-in Liquid Retina display", "2560 × 1664 · 60 Hz"),
        ]), InfoNode("USB", children: [
            InfoNode("iPhone 16 Pro", "USB · Connected"), InfoNode("USB-C Multiport Adapter", "USB 3.1"),
        ])]
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
    }

    /// Shows the window briefly and captures it from the screen. Drawing it offscreen
    /// (`cacheDisplay`) can't render the system materials an app built with the
    /// macOS 26 SDK uses, such as the sidebar's selection, which come out black.
    private static func capture<V: View>(_ view: V, title: String, size: NSSize, scrolledTo offset: CGFloat = 0,
                                         to url: URL) throws {
        let controller = NSHostingController(rootView: view.preferredColorScheme(.light))
        if #available(macOS 14.0, *) { controller.sceneBridgingOptions = .all }
        // Keep the requested size; otherwise a long table grows the window to fit every row.
        controller.sizingOptions = []
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = title
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(size)
        window.center()
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        controller.view.layoutSubtreeIfNeeded()
        if offset > 0, let scrollView = scrollViews(in: controller.view)
            .max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }) {
            scrollView.hasVerticalScroller = false
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        }
        window.displayIfNeeded()
        try writeFramed(screenImage(of: window), to: url)
        window.close()
        print("Rendered \(url.lastPathComponent)")
    }

    /// A restrained citrus backdrop, consistent margins and a soft window shadow.
    private static func writeFramed(_ windowImage: NSImage, to url: URL) throws {
        let size = NSSize(width: 1200, height: 960)
        let scale: CGFloat = 2
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let context = NSGraphicsContext.current!.cgContext
        context.scaleBy(x: scale, y: scale)
        NSGradient(starting: NSColor(red: 0.93, green: 0.96, blue: 0.89, alpha: 1),
                   ending: NSColor(red: 0.99, green: 0.97, blue: 0.90, alpha: 1))!
            .draw(in: NSRect(origin: .zero, size: size), angle: -35)
        let fit = min((size.width - 120) / windowImage.size.width, (size.height - 120) / windowImage.size.height)
        let imageSize = NSSize(width: windowImage.size.width * fit, height: windowImage.size.height * fit)
        let rect = NSRect(x: (size.width - imageSize.width) / 2, y: (size.height - imageSize.height) / 2 + 6,
                          width: imageSize.width, height: imageSize.height)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(red: 0.20, green: 0.27, blue: 0.15, alpha: 0.22)
        shadow.shadowBlurRadius = 24
        shadow.shadowOffset = NSSize(width: 0, height: -12)
        shadow.set()
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSBezierPath(roundedRect: rect, xRadius: 12, yRadius: 12).addClip()
        windowImage.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try png.write(to: url)
    }
}
#endif
