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
        for (night, (hours, lost)) in [(8.2, 140), (7.5, 120), (9.1, 150)].enumerated() {
            let end = date.addingTimeInterval(-Double(night) * 86400 - 3 * 3600)
            try store.insert(SleepSession(start: end.addingTimeInterval(-hours * 3600), end: end,
                                          startCapacity: 3900, endCapacity: 3900 - lost, fullChargeCapacity: 4518))
        }
        let history = HistoryController(monitor: monitor, iosDevices: devices, store: store)
        let navigator = Navigator()

        func dependencies<V: View>(_ view: V) -> some View {
            view.environmentObject(monitor)
                .environmentObject(devices)
                .environmentObject(history)
                .environmentObject(navigator)
                .environment(\.locale, Locale(identifier: "en_GB"))
        }

        navigator.selection = .thisMac
        try capture(dependencies(ContentView()), title: "This Mac", size: NSSize(width: 1000, height: 780),
                    to: directory.appendingPathComponent("mac-dashboard.png"))
        navigator.selection = .device("demo-iphone")
        try capture(dependencies(ContentView()), title: "iPhone", size: NSSize(width: 1000, height: 780),
                    to: directory.appendingPathComponent("iphone.png"))
        navigator.selection = .history
        try capture(dependencies(ContentView()), title: "History", size: NSSize(width: 1100, height: 780),
                    to: directory.appendingPathComponent("history.png"))
        try capture(dependencies(LifetimeAnalyzer()), title: "Battery Lifetime Data", size: NSSize(width: 920, height: 690),
                    to: directory.appendingPathComponent("lifetime.png"))
        try capture(dependencies(AdvancedViewer(sampleSections: advancedSections)), title: "Advanced Viewer",
                    size: NSSize(width: 920, height: 690), to: directory.appendingPathComponent("advanced.png"))
    }

    private static func makeMonitor() -> BatteryMonitor {
        let battery = MacBatterySnapshot(registry: [
            "AppleRawCurrentCapacity": 3709, "AppleRawMaxCapacity": 4518, "DesignCapacity": 4629,
            "NominalChargeCapacity": 4546, "CycleCount": 107, "DesignCycleCount9C": 1000,
            "Temperature": 2860, "Voltage": 11720, "Amperage": -530,
            "IsCharging": false, "ExternalConnected": false, "FullyCharged": false,
            "AvgTimeToEmpty": 420, "Serial": "DEMO-BATTERY-001", "Manufacturer": "Sunwoda",
            "DeviceName": "bq40z651", "ManufactureDate": ((2025 - 1980) << 9) | (12 << 5) | 3,
            "LifetimeData": lifetimeData(hours: 7728, cycles: 103),
        ], smc: nil, powerSource: PowerSourceInfo(chargePercent: 82, timeToEmptyMinutes: 420), date: date)
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
            power: PowerReadings(systemWatts: 6.4, adapterWatts: 0, cpuTemperatureCelsius: 38.2),
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

    private static func capture<V: View>(_ view: V, title: String, size: NSSize, to url: URL) throws {
        let controller = NSHostingController(rootView: view.preferredColorScheme(.light))
        if #available(macOS 14.0, *) { controller.sceneBridgingOptions = .all }
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.title = title
        window.toolbarStyle = .unified
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(size)
        window.setFrameOrigin(NSPoint(x: -5000, y: 0))
        window.makeKeyAndOrderFront(nil)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        controller.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        guard let frame = window.contentView?.superview,
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
                  pixelsWide: Int(frame.bounds.width * 2), pixelsHigh: Int(frame.bounds.height * 2),
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw CocoaError(.fileWriteUnknown)
        }
        bitmap.size = frame.bounds.size
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        let image = NSImage(size: frame.bounds.size)
        image.addRepresentation(bitmap)
        try writeFramed(image, to: url)
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
