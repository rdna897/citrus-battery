import CitrusKit
import SwiftUI

@main
enum Entry {
    static func main() {
        let arguments = CommandLine.arguments
        if arguments.contains("--dump") {
            DiagnosticDump.print()
            return
        }
        if arguments.contains("--advanced") {
            let info = MacInfo.read()
            var sections = AdvancedInfo.mac(info: info, marketingName: MacInfo.marketingName())
            for listing in IOSDeviceReader.connectedDevices() {
                if let raw = IOSDeviceReader.readRaw(listing) {
                    sections += AdvancedInfo.device(info: raw.info, battery: raw.battery, pack: raw.pack)
                }
            }
            for section in sections {
                print(section.tabSeparated().joined(separator: "\n"))
            }
            return
        }
        if arguments.contains("--ios-raw") {
            for listing in IOSDeviceReader.connectedDevices() {
                guard let raw = IOSDeviceReader.readRaw(listing) else { print("\(listing.udid): not readable"); continue }
                for (title, value) in [("INFO", raw.info), ("BATTERY", raw.battery), ("PACK", raw.pack), ("GESTALT", raw.gestalt)] {
                    print("===== \(title)")
                    printTree(value ?? [:], indent: "")
                }
            }
            return
        }
        if arguments.contains("--ios") {
            dumpIOSDevices()
            return
        }
        if let index = arguments.firstIndex(of: "--import-coconutbattery"), index + 1 < arguments.count {
            importCoconutBattery(path: arguments[index + 1])
            return
        }
        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
            let kind = index + 2 < arguments.count ? arguments[index + 2] : "main"
            MainActor.assumeIsolated { Snapshot.render(to: URL(fileURLWithPath: arguments[index + 1]), kind: kind) }
            return
        }
        CitrusBatteryApp.main()
    }
}

/// `CitrusBattery --ios` lists connected iPhones/iPads and their battery data.
private func dumpIOSDevices() {
    let devices = IOSDeviceReader.connectedDevices()
    if devices.isEmpty {
        print("No iPhone or iPad found. Connect one with a cable, unlock it, and tap Trust.")
    }
    for listing in devices {
        print("\(listing.udid) (\(listing.connection.rawValue))")
        switch IOSDeviceReader.read(listing) {
        case .notTrusted: print("  Not trusted yet: unlock the device and tap Trust.")
        case .locked: print("  Locked: unlock the device.")
        case .unavailable: print("  Couldn't read this device.")
        case let .ready(device):
            print("  \(device.name): \(device.marketingName) [\(device.productType)] iOS \(device.osVersion ?? "-")")
            print("  serial \(device.serialNumber ?? "-")  model \(device.modelNumber ?? "-")")
            guard let b = device.battery else {
                print("  No battery data returned.")
                continue
            }
            print("  charge \(b.rawChargeFraction.map { String(format: "%.1f%%", $0 * 100) } ?? "-")"
                + "  health \(b.healthFraction.map { String(format: "%.1f%%", $0 * 100) } ?? "-")"
                + "  (\(b.fullChargeCapacity.map(String.init) ?? "-") / \(b.designCapacity.map(String.init) ?? "-") mAh)"
                + "  cycles \(b.cycleCount.map(String.init) ?? "-")"
                + "  temp \(b.temperatureCelsius.map { String(format: "%.1f °C", $0) } ?? "-")")
            print("  charging \(b.isCharging)  external \(b.isExternalPowerConnected)  serial \(b.serialNumber ?? "-")"
                + "  maker \(b.manufacturer ?? "-")  lifetime \(b.lifetime?.totalOperatingHours.map { "\($0) h" } ?? "-")")
            print("  iOS charge \(b.chargeFraction(style: .apple).map { String(format: "%.0f%%", $0 * 100) } ?? "-")"
                + "  first used \(b.firstUseDate?.formatted(date: .abbreviated, time: .omitted) ?? "-")"
                + "  made ≈ \(b.estimatedManufactureDate?.formatted(date: .abbreviated, time: .omitted) ?? "-")"
                + "  lifetime temp \(b.lifetime?.minimumTemperatureCelsius.map { "\($0)" } ?? "-")–\(b.lifetime?.maximumTemperatureCelsius.map { "\($0)" } ?? "-") °C")
        }
    }
}

/// `CitrusBattery --import-coconutbattery backup.ccba` adds a coconutBattery backup to the history.
private func importCoconutBattery(path: String) {
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let entries = try CoconutBatteryBackup.entries(from: data)
        let added = try HistoryStore().importEntries(entries)
        print("Read \(entries.count) entries; added \(added) (others were already in the history).")
    } catch {
        print("Import failed: \(error.localizedDescription)")
    }
}

struct CitrusBatteryApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var monitor: BatteryMonitor
    @StateObject private var history: HistoryController
    @StateObject private var notifier: Notifier
    @StateObject private var navigator = Navigator()
    @StateObject private var iosDevices: IOSDeviceMonitor
    @AppStorage(PreferenceKey.showInMenuBar) private var showInMenuBar = true

    init() {
        let monitor = BatteryMonitor()
        let iosDevices = IOSDeviceMonitor()
        _monitor = StateObject(wrappedValue: monitor)
        _iosDevices = StateObject(wrappedValue: iosDevices)
        _history = StateObject(wrappedValue: HistoryController(monitor: monitor, iosDevices: iosDevices))
        _notifier = StateObject(wrappedValue: Notifier(monitor: monitor, iosDevices: iosDevices))
    }

    var body: some Scene {
        // A single window: reopening (e.g. from the menu bar) brings it forward
        // instead of creating another copy.
        Window("Citrus Battery", id: "main") {
            ContentView()
                .environmentObject(monitor)
                .environmentObject(history)
                .environmentObject(navigator)
                .environmentObject(iosDevices)
                .frame(minWidth: 760, minHeight: 520)
        }
        .commands {
            AppCommands(monitor: monitor, navigator: navigator, iosDevices: iosDevices)
        }

        WindowGroup("Advanced Viewer", id: "advanced", for: String.self) { $target in
            AdvancedViewer(target: target ?? AdvancedTarget.mac)
                .environmentObject(monitor)
                .environmentObject(iosDevices)
        }

        Settings {
            SettingsView()
                .environmentObject(monitor)
                .environmentObject(history)
                .environmentObject(notifier)
        }

        MenuBarExtra(isInserted: $showInMenuBar) {
            MenuBarPanel()
                .environmentObject(monitor)
                .environmentObject(navigator)
                .environmentObject(iosDevices)
        } label: {
            MenuBarLabel()
                .environmentObject(monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

/// `CitrusBattery --dump` prints current readings, for debugging and bug reports.
enum DiagnosticDump {
    /// The same readings as text, for Help → Copy Diagnostic Report.
    static func report() -> String {
        var lines: [String] = []
        let bundle = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development build"
        lines.append("Citrus Battery \(bundle)")
        capture { lines.append($0) }
        return lines.joined(separator: "\n")
    }

    static func print() {
        capture { Swift.print($0) }
    }

    private static func capture(_ emit: (String) -> Void) {
        func print(_ line: String) { emit(line) }
        let info = MacInfo.read()
        print("Mac: \(info.modelIdentifier) \(info.modelNumber ?? "") serial=\(info.serialNumber ?? "-")")
        print("macOS: \(info.osVersion)  chip: \(info.chip ?? "-")")

        let power = PowerReadings.read()
        print("System power: \(fmt(power.systemWatts)) W  adapter: \(fmt(power.adapterWatts)) W  "
            + "(\(fmt(power.adapterVolts)) V × \(fmt(power.adapterAmps)) A)  CPU: \(fmt(power.cpuTemperatureCelsius)) °C")

        guard let b = MacBatteryReader.read() else {
            print("No battery found")
            return
        }
        print("Charge: \(b.currentCapacity.map(String.init) ?? "-") / \(b.fullChargeCapacity.map(String.init) ?? "-") mAh"
            + "  raw \(pct(b.rawChargeFraction))  macOS \(b.powerSource?.chargePercent.map { "\($0)%" } ?? "-")")
        print("Health: \(pct(b.healthFraction))  design \(b.designCapacity.map(String.init) ?? "-") mAh"
            + "  nominal \(b.nominalChargeCapacity.map(String.init) ?? "-") mAh  macOS: \(b.powerSource?.healthDescription ?? "-")")
        print("Cycles: \(b.cycleCount.map(String.init) ?? "-")"
            + "  temperature \(fmt(b.temperatureCelsius)) °C")
        print("Voltage \(b.voltageMillivolts.map(String.init) ?? "-") mV  amperage \(b.amperageMilliamps.map(String.init) ?? "-") mA"
            + "  battery power \(fmt(b.batteryPowerWatts)) W")
        print("Charging \(b.isCharging)  external \(b.isExternalPowerConnected)  full \(b.isFullyCharged)"
            + "  remaining \(b.timeRemainingMinutes.map(DurationFormat.hoursMinutes) ?? "-")")
        print("Adapter: \(b.adapter?.watts.map { "\($0) W" } ?? "-") \(b.adapter?.name ?? "")")
        print("Serial: \(b.serialNumber ?? "-")  gauge: \(b.gasGaugeName ?? "-")  maker: \(b.manufacturer ?? "-")")
        let made = b.manufactureDate.map { "\($0.year ?? 0)-\($0.month ?? 0)-\($0.day ?? 0)" }
            ?? b.estimatedManufactureDate.map { "\($0.formatted(date: .numeric, time: .omitted)) (estimated)" }
            ?? b.manufactureWeek.map { "week \($0.week), month \($0.month), year unknown" }
        print("Manufactured: \(made ?? "-")")
        if let l = b.lifetime {
            print("Lifetime: \(l.totalOperatingHours.map(String.init) ?? "-") h operating, "
                + "temperature \(fmt(l.minimumTemperatureCelsius))–\(fmt(l.maximumTemperatureCelsius)) °C "
                + "(avg \(fmt(l.averageTemperatureCelsius))), pack "
                + "\(l.minimumPackVoltageMillivolts.map(String.init) ?? "-")–\(l.maximumPackVoltageMillivolts.map(String.init) ?? "-") mV")
        }
        let limit = ChargeLimitReader.read()
        print("Charge limit: macOS \(limit.macOSLimitPercent.map { "\($0)%" } ?? "off")"
            + "  optimized \(limit.optimizedChargingEnabled ? (limit.optimizedChargingEngaged ? "on, engaged" : "on") : "off")"
            + "  third-party \(limit.thirdPartyLimiters.isEmpty ? "none" : limit.thirdPartyLimiters.joined(separator: ", "))"
            + "  BCLM \(limit.smcChargeLevelLimit.map(String.init) ?? "-")"
            + "  gauge calibrated \(b.cyclesSinceCalibration.map { "\($0) cycles ago" } ?? "-")")
        if let advice = limit.advice(cyclesSinceCalibration: b.cyclesSinceCalibration) {
            print("Advice (\(advice.level)): \(advice.message)")
        }
        print("Failures: \(b.failures.messages.isEmpty ? "none" : b.failures.messages.joined(separator: ", "))")
    }

    private static func fmt(_ value: Double?) -> String {
        value.map { String(format: "%.2f", $0) } ?? "-"
    }

    private static func pct(_ fraction: Double?) -> String {
        fraction.map { String(format: "%.1f%%", $0 * 100) } ?? "-"
    }
}

/// `CitrusBattery --snapshot out.png` renders the Mac detail view offscreen
/// (for screenshots and visual checks without Screen Recording permission).
@MainActor
enum Snapshot {
    static func render(to url: URL, kind: String) {
        let monitor = BatteryMonitor()
        // Collect a few samples so the power chart has a line to draw.
        for _ in 0..<12 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            monitor.refresh()
        }
        let view: AnyView
        switch kind {
        case "panel":
            view = AnyView(VStack(alignment: .leading, spacing: 12) {
                ForEach(["%CHARGE%", "%CHARGE% %TIMEREM%", "%SYSWATT% · %CUSTEMP%"], id: \.self) { format in
                    MenuBarSnapshotLabel(format: format)
                }
                MenuBarPanel()
            }
            .padding(8)
            .environmentObject(monitor)
            .environmentObject(Navigator())
            .background(Color(nsColor: .windowBackgroundColor)))
        default:
            view = AnyView(MacDetailContent()
                .environmentObject(monitor)
                .frame(width: 720)
                .background(Color(nsColor: .windowBackgroundColor)))
        }
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else {
            Swift.print("Rendering failed")
            return
        }
        do {
            try png.write(to: url)
            Swift.print("Wrote \(url.path)")
        } catch {
            Swift.print("Could not write \(url.path): \(error.localizedDescription)")
        }
    }
}

/// A menu bar label with a fixed format, for snapshots.
private struct MenuBarSnapshotLabel: View {
    let format: String
    @EnvironmentObject private var monitor: BatteryMonitor

    var body: some View {
        Text(Image(systemName: MenuBarLabel.symbolName(for: monitor.battery))) + Text(" ")
            + Text(MenuBarFormatter.render(format, values: monitor.menuBarValues(
                temperatureUnit: .celsius, capacityStyle: .raw)))
    }
}

/// Prints a property-list tree with short values (for --ios-raw).
private func printTree(_ value: Any, indent: String) {
    if let dictionary = value as? [String: Any] {
        for key in dictionary.keys.sorted() {
            let child = dictionary[key]!
            if child is [String: Any] || child is [Any] {
                print("\(indent)\(key):")
                printTree(child, indent: indent + "  ")
            } else {
                print("\(indent)\(key) = \(String(describing: child).prefix(80))")
            }
        }
    } else if let array = value as? [Any] {
        print("\(indent)[\(array.count) items] \(String(describing: array.prefix(4)).prefix(120))")
    } else {
        print("\(indent)\(String(describing: value).prefix(80))")
    }
}
