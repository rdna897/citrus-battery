import Foundation

/// The rows of the Battery Lifetime Data window: everything the gas gauge has
/// recorded over the battery's life, as name/value pairs.
public enum LifetimeReport {
    public struct Row: Identifiable, Sendable, Equatable {
        public var name: String
        public var value: String
        public var id: String { name }

        public init(_ name: String, _ value: String) {
            self.name = name
            self.value = value
        }
    }

    /// Rows for every value the battery reports; missing values are left out.
    /// Returns an empty list when the battery keeps no lifetime data.
    public static func rows(for battery: MacBatterySnapshot, temperatureUnit: TemperatureUnit,
                            now: Date = Date()) -> [Row] {
        guard let lifetime = battery.lifetime else { return [] }
        var rows: [Row] = []
        func add(_ name: String, _ value: String?) {
            if let value { rows.append(Row(name, value)) }
        }
        func day(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .omitted) }
        func temperature(_ celsius: Double?) -> String? { celsius.map(temperatureUnit.format(celsius:)) }
        func volts(_ millivolts: Int?) -> String? { millivolts.map { String(format: "%.2f V", Double($0) / 1000) } }
        // Current as a multiple of design capacity: 1C fills or empties the battery in an hour.
        func current(_ milliamps: Int?) -> String? {
            guard let milliamps else { return nil }
            let amps = abs(milliamps)
            guard let design = battery.designCapacity, design > 0 else { return "\(amps) mA" }
            return "\(amps) mA (" + String(format: "%.2f", Double(amps) / Double(design)) + "C)"
        }

        add("Total operating time", lifetime.totalOperatingHours.map {
            "\($0.formatted()) h (\(($0 / 24).formatted()) days)"
        })
        if let best = battery.bestManufactureDate {
            let source = switch best.source {
            case .recorded: ""
            case .serialNumber: " (from battery serial)"
            case .operatingTime: " (estimated)"
            }
            add("Manufactured", day(best.date) + source)
            let days = Calendar.current.dateComponents([.day], from: best.date, to: now).day ?? 0
            add("Age", "\(days.formatted()) days")
        }
        add("First used", battery.firstUseDate.map(day))
        add("Charge cycles", battery.cycleCount.map { $0.formatted() })
        if let last = lifetime.cycleCountAtLastCalibration {
            let ago = battery.cyclesSinceCalibration.map { $0 == 0 ? " (this cycle)" : " (\($0) ago)" } ?? ""
            add("Gauge last calibrated", "At cycle \(last)\(ago)")
        }
        add("Minimum temperature", temperature(lifetime.minimumTemperatureCelsius))
        add("Maximum temperature", temperature(lifetime.maximumTemperatureCelsius))
        add("Average temperature", temperature(lifetime.averageTemperatureCelsius))
        add("Temperature samples", lifetime.temperatureSamples.map { $0.formatted() })
        add("Minimum pack voltage", volts(lifetime.minimumPackVoltageMillivolts))
        add("Maximum pack voltage", volts(lifetime.maximumPackVoltageMillivolts))
        add("Maximum charge current", current(lifetime.maximumChargeCurrentMilliamps))
        add("Maximum discharge current", current(lifetime.maximumDischargeCurrentMilliamps))
        let failures = battery.failures.messages
        add("Battery failures", failures.isEmpty ? "None" : failures.joined(separator: ", "))
        add("Lifetime data updated", lifetime.updated.map { $0.formatted(date: .abbreviated, time: .shortened) })
        return rows
    }
}
