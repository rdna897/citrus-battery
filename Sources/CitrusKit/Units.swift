import Foundation

/// Temperature scales offered in Settings. All are free in Citrus Battery.
public enum TemperatureUnit: String, CaseIterable, Identifiable, Sendable {
    case celsius, fahrenheit, kelvin, rankine, delisle, newton, reaumur, romer

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .celsius: "Celsius"
        case .fahrenheit: "Fahrenheit"
        case .kelvin: "Kelvin"
        case .rankine: "Rankine"
        case .delisle: "Delisle"
        case .newton: "Newton"
        case .reaumur: "Réaumur"
        case .romer: "Rømer"
        }
    }

    public var symbol: String {
        switch self {
        case .celsius: "°C"
        case .fahrenheit: "°F"
        case .kelvin: "K"
        case .rankine: "°R"
        case .delisle: "°De"
        case .newton: "°N"
        case .reaumur: "°Ré"
        case .romer: "°Rø"
        }
    }

    public func convert(celsius c: Double) -> Double {
        switch self {
        case .celsius: c
        case .fahrenheit: c * 9 / 5 + 32
        case .kelvin: c + 273.15
        case .rankine: (c + 273.15) * 9 / 5
        case .delisle: (100 - c) * 3 / 2
        case .newton: c * 33 / 100
        case .reaumur: c * 4 / 5
        case .romer: c * 21 / 40 + 7.5
        }
    }

    public func format(celsius c: Double) -> String {
        let value = convert(celsius: c)
        let separator = self == .kelvin ? " " : ""
        return String(format: "%.1f", value) + separator + symbol
    }
}

/// How battery capacity is presented.
public enum CapacityUnit: String, CaseIterable, Identifiable, Sendable {
    /// Charge in milliamp-hours.
    case milliampHours
    /// Energy in watt-hours.
    case wattHours

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .milliampHours: "mAh (charge)"
        case .wattHours: "Wh (energy)"
        }
    }

    /// Formats a charge in mAh, converting with the pack voltage (mV) for Wh.
    public func format(milliampHours mAh: Int, voltageMillivolts mV: Int?) -> String {
        switch self {
        case .milliampHours:
            return "\(mAh) mAh"
        case .wattHours:
            guard let mV, mV > 0 else { return "\(mAh) mAh" }
            return String(format: "%.1f Wh", Double(mAh) * Double(mV) / 1_000_000)
        }
    }
}

/// Which charge percentage to show.
public enum CapacityStyle: String, CaseIterable, Identifiable, Sendable {
    /// Remaining ÷ full-charge capacity, straight from the battery.
    case raw
    /// The percentage macOS shows in the menu bar.
    case apple

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .raw: "Raw battery values"
        case .apple: "macOS style"
        }
    }
}

/// How often live data refreshes.
public enum UpdateInterval: String, CaseIterable, Identifiable, Sendable {
    /// Every 5 s, with power values averaged over the last 30 s.
    case delayed
    /// Every second, unsmoothed.
    case fast

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .delayed: "Delayed (smoothed)"
        case .fast: "Fast (every second)"
        }
    }

    public var seconds: TimeInterval {
        switch self {
        case .delayed: 5
        case .fast: 1
        }
    }
}

public enum DurationFormat {
    /// "2:05" style hours and minutes.
    public static func hoursMinutes(_ minutes: Int) -> String {
        String(format: "%d:%02d", minutes / 60, minutes % 60)
    }
}
