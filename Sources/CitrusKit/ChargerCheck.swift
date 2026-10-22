import Foundation

/// Explains how a connected charger is affecting charging.
public enum ChargerCheck {
    /// Share of the agreed power above which the charger counts as fully loaded.
    static let fullLoadShare = 0.9
    /// Below this charge level, charging isn't yet slowing down to protect the battery.
    static let fastChargeCeiling = 0.8

    /// Notes about the charger, most important first. Empty when nothing stands out.
    ///
    /// - Parameters:
    ///   - inputWatts: power arriving from the charger, if measured.
    ///   - systemWatts: power the whole device is using, if measured.
    public static func advice(battery: MacBatterySnapshot, inputWatts: Double?,
                              systemWatts: Double? = nil) -> [BatteryAdvice] {
        guard battery.isExternalPowerConnected, let adapter = battery.adapter else { return [] }
        var advice: [BatteryAdvice] = []
        let agreed = agreedWatts(adapter)

        let draining = (battery.batteryPowerWatts ?? 0) < -1
        if draining, !battery.isCharging, let inputWatts, inputWatts > 1 {
            let used = systemWatts.map { ", \(format($0)) used" } ?? ""
            advice.append(BatteryAdvice(
                level: .caution,
                message: "The battery is draining while plugged in: the charger supplies less power than "
                    + "is being used (\(format(inputWatts)) in\(used))."))
        }

        if let volts = adapter.voltageMillivolts, volts <= 5000, (agreed ?? 0) < 15 {
            advice.append(BatteryAdvice(
                level: .caution,
                message: "This is a basic 5 V USB supply\(agreed.map { " (\(format($0)))" } ?? ""). "
                    + "It charges slowly and may not keep up while the device is in use."))
        } else if battery.isCharging, let agreed, agreed > 0, let inputWatts,
                  inputWatts >= agreed * fullLoadShare,
                  (battery.rawChargeFraction ?? 1) < fastChargeCeiling {
            advice.append(BatteryAdvice(
                level: .info,
                message: "The charger is supplying nearly all it can (\(format(inputWatts)) of "
                    + "\(format(agreed))), so it sets the charging speed. A more powerful charger would "
                    + "charge faster, if the device supports one."))
        }
        return advice
    }

    /// The agreed power: voltage × current when known, else the reported wattage.
    public static func agreedWatts(_ adapter: PowerAdapter) -> Double? {
        if let volts = adapter.voltageMillivolts, let amps = adapter.currentMilliamps, volts > 0, amps > 0 {
            return Double(volts) * Double(amps) / 1_000_000
        }
        return adapter.watts.flatMap { $0 > 0 ? Double($0) : nil }
    }

    /// "20 V × 1.49 A", or `nil` when the voltage or current is missing.
    public static func agreedText(_ adapter: PowerAdapter) -> String? {
        guard let volts = adapter.voltageMillivolts, let amps = adapter.currentMilliamps, volts > 0, amps > 0
        else { return nil }
        return "\(number(Double(volts) / 1000)) V × \(number(Double(amps) / 1000)) A"
    }

    /// "5 V 3 A · 9 V 3 A · 20 V 1.5 A".
    public static func profilesText(_ adapter: PowerAdapter) -> String? {
        guard !adapter.profiles.isEmpty else { return nil }
        return adapter.profiles.map {
            "\(number(Double($0.voltageMillivolts) / 1000)) V \(number(Double($0.maxCurrentMilliamps) / 1000)) A"
        }.joined(separator: " · ")
    }

    /// Up to two decimals, without trailing zeros: 20, 1.5, 1.49.
    static func number(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        return rounded.formatted(.number.precision(.fractionLength(0...2)).grouping(.never)
            .locale(Locale(identifier: "en_US_POSIX")))
    }

    static func format(_ watts: Double) -> String {
        watts >= 10 ? String(format: "%.0f W", watts) : String(format: "%.1f W", watts)
    }
}
