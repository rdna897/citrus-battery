import Foundation

/// Which battery notifications the user wants.
public struct BatteryAlertSettings: Sendable, Equatable {
    /// Notify when the charge falls below this percentage while on battery.
    public var lowChargePercent: Int?
    /// Notify when the estimated time on battery falls below this many minutes.
    public var lowTimeMinutes: Int?
    /// Notify when the battery finishes charging.
    public var fullyCharged: Bool

    public init(lowChargePercent: Int? = nil, lowTimeMinutes: Int? = nil, fullyCharged: Bool = false) {
        self.lowChargePercent = lowChargePercent
        self.lowTimeMinutes = lowTimeMinutes
        self.fullyCharged = fullyCharged
    }
}

public enum BatteryAlert: Sendable, Equatable {
    case lowCharge(percent: Int)
    case lowTime(minutes: Int)
    case fullyCharged

    public var title: String {
        switch self {
        case .lowCharge: "Battery low"
        case .lowTime: "Battery running out"
        case .fullyCharged: "Battery fully charged"
        }
    }

    public var body: String {
        switch self {
        case let .lowCharge(percent): "Battery percentage is at \(percent)%."
        case let .lowTime(minutes): "About \(DurationFormat.readable(minutes)) of battery time remaining."
        case .fullyCharged: "You can unplug the power adapter."
        }
    }
}

/// Re-arm state between readings, so each alert fires once per discharge.
public struct BatteryAlertState: Sendable, Equatable {
    public var canNotifyLowCharge = true
    public var canNotifyLowTime = true
    // Disarmed at start so launching while already full stays quiet.
    public var canNotifyFull = false
    public var lastLowChargeAlert: Date?
    public var lastLowTimeAlert: Date?

    public init() {}
}

public struct BatteryReading: Sendable, Equatable {
    public var chargePercent: Int
    public var timeToEmptyMinutes: Int?
    public var isExternalPowerConnected: Bool
    public var isFullyCharged: Bool

    public init(chargePercent: Int, timeToEmptyMinutes: Int?, isExternalPowerConnected: Bool, isFullyCharged: Bool) {
        self.chargePercent = chargePercent
        self.timeToEmptyMinutes = timeToEmptyMinutes
        self.isExternalPowerConnected = isExternalPowerConnected
        self.isFullyCharged = isFullyCharged
    }
}

public enum BatteryAlertRules {
    /// Minimum gap between repeats of the same alert (coconutBattery uses 15 minutes).
    public static let minimumRepeatInterval: TimeInterval = 900

    /// Alerts to post for this reading, and the updated state.
    ///
    /// Low-charge and low-time alerts fire once while discharging and re-arm when
    /// power is connected. The fully-charged alert fires once per charge and
    /// re-arms when power is disconnected or the battery is no longer full.
    public static func evaluate(_ reading: BatteryReading, settings: BatteryAlertSettings,
                                state: BatteryAlertState, now: Date = Date()) -> ([BatteryAlert], BatteryAlertState) {
        var state = state
        var alerts: [BatteryAlert] = []

        func repeatAllowed(_ last: Date?) -> Bool {
            last.map { now.timeIntervalSince($0) >= minimumRepeatInterval } ?? true
        }

        if reading.isExternalPowerConnected {
            state.canNotifyLowCharge = true
            state.canNotifyLowTime = true
        } else {
            if let threshold = settings.lowChargePercent, reading.chargePercent < threshold,
               state.canNotifyLowCharge, repeatAllowed(state.lastLowChargeAlert) {
                alerts.append(.lowCharge(percent: reading.chargePercent))
                state.canNotifyLowCharge = false
                state.lastLowChargeAlert = now
            }
            if let threshold = settings.lowTimeMinutes, let minutes = reading.timeToEmptyMinutes,
               minutes < threshold, state.canNotifyLowTime, repeatAllowed(state.lastLowTimeAlert) {
                alerts.append(.lowTime(minutes: minutes))
                state.canNotifyLowTime = false
                state.lastLowTimeAlert = now
            }
        }

        if reading.isExternalPowerConnected, reading.isFullyCharged {
            if settings.fullyCharged, state.canNotifyFull {
                alerts.append(.fullyCharged)
            }
            state.canNotifyFull = false
        } else {
            state.canNotifyFull = true
        }

        return (alerts, state)
    }
}
