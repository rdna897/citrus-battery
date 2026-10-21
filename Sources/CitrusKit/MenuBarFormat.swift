import Foundation

/// Placeholders for the menu bar status text.
public enum MenuBarToken: String, CaseIterable, Identifiable, Sendable {
    case charge = "%CHARGE%"
    case cycles = "%CC%"
    case temperature = "%CUSTEMP%"
    case health = "%HEALTH%"
    case timeRemaining = "%TIMEREM%"
    case status = "%STATUS%"
    case systemPower = "%SYSWATT%"
    case batteryPower = "%BATWATT%"
    case charger = "%CHARGER%"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .charge: "Charge %"
        case .cycles: "Cycles"
        case .temperature: "Temperature"
        case .health: "Health"
        case .timeRemaining: "Time Remaining"
        case .status: "Charge Status"
        case .systemPower: "System Usage"
        case .batteryPower: "Battery In/Out"
        case .charger: "Charger"
        }
    }

    public static let defaultFormat = MenuBarToken.charge.rawValue
}

/// Values available to the menu bar text.
public struct MenuBarValues: Sendable, Equatable {
    public var chargeFraction: Double?
    public var cycleCount: Int?
    public var temperatureText: String?
    public var healthFraction: Double?
    public var timeRemainingMinutes: Int?
    public var isCharging: Bool
    public var isExternalPowerConnected: Bool
    public var isFullyCharged: Bool
    public var systemWatts: Double?
    public var batteryWatts: Double?
    public var chargerWatts: Int?

    public init(chargeFraction: Double? = nil, cycleCount: Int? = nil, temperatureText: String? = nil,
                healthFraction: Double? = nil, timeRemainingMinutes: Int? = nil, isCharging: Bool = false,
                isExternalPowerConnected: Bool = false, isFullyCharged: Bool = false,
                systemWatts: Double? = nil, batteryWatts: Double? = nil, chargerWatts: Int? = nil) {
        self.chargeFraction = chargeFraction
        self.cycleCount = cycleCount
        self.temperatureText = temperatureText
        self.healthFraction = healthFraction
        self.timeRemainingMinutes = timeRemainingMinutes
        self.isCharging = isCharging
        self.isExternalPowerConnected = isExternalPowerConnected
        self.isFullyCharged = isFullyCharged
        self.systemWatts = systemWatts
        self.batteryWatts = batteryWatts
        self.chargerWatts = chargerWatts
    }
}

public enum MenuBarFormatter {
    /// Replaces every token in `format`; unavailable values render as "–".
    public static func render(_ format: String, values v: MenuBarValues) -> String {
        var text = format
        for token in MenuBarToken.allCases where text.contains(token.rawValue) {
            text = text.replacingOccurrences(of: token.rawValue, with: value(for: token, in: v) ?? "–")
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    static func value(for token: MenuBarToken, in v: MenuBarValues) -> String? {
        switch token {
        case .charge:
            return v.chargeFraction.map { "\(Int(($0 * 100).rounded()))%" }
        case .cycles:
            return v.cycleCount.map(String.init)
        case .temperature:
            return v.temperatureText
        case .health:
            return v.healthFraction.map { "\(Int(($0 * 100).rounded()))%" }
        case .timeRemaining:
            if v.isFullyCharged { return "Full" }
            return v.timeRemainingMinutes.map(DurationFormat.hoursMinutes)
        case .status:
            if v.isFullyCharged { return "Full" }
            if v.isCharging { return "Charging" }
            return v.isExternalPowerConnected ? "Not charging" : "Battery"
        case .systemPower:
            return v.systemWatts.map { String(format: "%.1f W", $0) }
        case .batteryPower:
            return v.batteryWatts.map { String(format: "%@%.1f W", $0 >= 0 ? "+" : "−", abs($0)) }
        case .charger:
            return v.chargerWatts.flatMap { $0 > 0 ? "\($0) W" : nil }
        }
    }
}
