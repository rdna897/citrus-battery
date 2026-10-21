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
        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
            MainActor.assumeIsolated { Snapshot.render(to: URL(fileURLWithPath: arguments[index + 1])) }
            return
        }
        CitrusBatteryApp.main()
    }
}

struct CitrusBatteryApp: App {
    @StateObject private var monitor = BatteryMonitor()

    var body: some Scene {
        WindowGroup("Citrus Battery") {
            ContentView()
                .environmentObject(monitor)
                .frame(minWidth: 760, minHeight: 520)
        }
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh") { monitor.refresh() }
                    .keyboardShortcut("r")
            }
        }

        Settings {
            SettingsView()
        }
    }
}

/// `CitrusBattery --dump` prints current readings, for debugging and bug reports.
enum DiagnosticDump {
    static func print() {
        let info = MacInfo.read()
        Swift.print("Mac: \(info.modelIdentifier) \(info.modelNumber ?? "") serial=\(info.serialNumber ?? "-")")
        Swift.print("macOS: \(info.osVersion)  chip: \(info.chip ?? "-")")

        let power = PowerReadings.read()
        Swift.print("System power: \(fmt(power.systemWatts)) W  adapter: \(fmt(power.adapterWatts)) W  "
            + "(\(fmt(power.adapterVolts)) V × \(fmt(power.adapterAmps)) A)  CPU: \(fmt(power.cpuTemperatureCelsius)) °C")

        guard let b = MacBatteryReader.read() else {
            Swift.print("No battery found")
            return
        }
        Swift.print("Charge: \(b.currentCapacity.map(String.init) ?? "-") / \(b.fullChargeCapacity.map(String.init) ?? "-") mAh"
            + "  raw \(pct(b.rawChargeFraction))  macOS \(b.powerSource?.chargePercent.map { "\($0)%" } ?? "-")")
        Swift.print("Health: \(pct(b.healthFraction))  design \(b.designCapacity.map(String.init) ?? "-") mAh"
            + "  nominal \(b.nominalChargeCapacity.map(String.init) ?? "-") mAh  macOS: \(b.powerSource?.healthDescription ?? "-")")
        Swift.print("Cycles: \(b.cycleCount.map(String.init) ?? "-") / \(b.designCycleCount.map(String.init) ?? "-")"
            + "  temperature \(fmt(b.temperatureCelsius)) °C")
        Swift.print("Voltage \(b.voltageMillivolts.map(String.init) ?? "-") mV  amperage \(b.amperageMilliamps.map(String.init) ?? "-") mA"
            + "  battery power \(fmt(b.batteryPowerWatts)) W")
        Swift.print("Charging \(b.isCharging)  external \(b.isExternalPowerConnected)  full \(b.isFullyCharged)"
            + "  remaining \(b.timeRemainingMinutes.map(DurationFormat.hoursMinutes) ?? "-")")
        Swift.print("Adapter: \(b.adapter?.watts.map { "\($0) W" } ?? "-") \(b.adapter?.name ?? "")")
        Swift.print("Serial: \(b.serialNumber ?? "-")  gauge: \(b.gasGaugeName ?? "-")  maker: \(b.manufacturer ?? "-")")
        let made = b.manufactureDate.map { "\($0.year ?? 0)-\($0.month ?? 0)-\($0.day ?? 0)" }
            ?? b.estimatedManufactureDate.map { "\($0.formatted(date: .numeric, time: .omitted)) (estimated)" }
            ?? b.manufactureWeek.map { "week \($0.week), month \($0.month), year unknown" }
        Swift.print("Manufactured: \(made ?? "-")")
        if let l = b.lifetime {
            Swift.print("Lifetime: \(l.totalOperatingHours.map(String.init) ?? "-") h operating, "
                + "temperature \(fmt(l.minimumTemperatureCelsius))–\(fmt(l.maximumTemperatureCelsius)) °C "
                + "(avg \(fmt(l.averageTemperatureCelsius))), pack "
                + "\(l.minimumPackVoltageMillivolts.map(String.init) ?? "-")–\(l.maximumPackVoltageMillivolts.map(String.init) ?? "-") mV")
        }
        Swift.print("Failures: \(b.failures.messages.isEmpty ? "none" : b.failures.messages.joined(separator: ", "))")
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
    static func render(to url: URL) {
        let monitor = BatteryMonitor()
        // Collect a few samples so the power chart has a line to draw.
        for _ in 0..<12 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            monitor.refresh()
        }
        let view = MacDetailContent()
            .environmentObject(monitor)
            .frame(width: 720)
            .background(Color(nsColor: .windowBackgroundColor))
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
