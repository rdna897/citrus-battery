import Foundation

/// Charge lost while the Mac slept on battery.
public struct SleepSession: Sendable, Equatable, Identifiable {
    public var id: Int64
    public var start: Date
    public var end: Date
    /// Remaining charge at sleep and after waking (mAh).
    public var startCapacity: Int
    public var endCapacity: Int
    /// Full-charge capacity at the time (mAh), the basis for percentages.
    public var fullChargeCapacity: Int

    public init(id: Int64 = 0, start: Date, end: Date, startCapacity: Int, endCapacity: Int,
                fullChargeCapacity: Int) {
        self.id = id
        self.start = start
        self.end = end
        self.startCapacity = startCapacity
        self.endCapacity = endCapacity
        self.fullChargeCapacity = fullChargeCapacity
    }

    public var hours: Double { end.timeIntervalSince(start) / 3600 }

    /// Charge lost as a fraction of a full charge.
    public var lossFraction: Double {
        Double(startCapacity - endCapacity) / Double(fullChargeCapacity)
    }

    /// Fraction of a full charge lost per hour asleep.
    public var lossPerHour: Double { lossFraction / hours }

    /// Shorter sleeps are skipped: the gauge's resolution swamps the loss.
    public static let minimumDuration: TimeInterval = 30 * 60

    /// The gauge can revise the remaining charge up a little once the battery
    /// rests after heavy use; rises up to this share of a full charge count as no loss.
    public static let restingRise = 0.01

    /// A session from readings taken just before sleep and after waking, or `nil`
    /// when it can't be measured: too short, on power at either end, or charged in between.
    public init?(before: MacBatterySnapshot, after: MacBatterySnapshot, sleptAt: Date, wokeAt: Date) {
        guard wokeAt.timeIntervalSince(sleptAt) >= Self.minimumDuration,
              !before.isExternalPowerConnected, !after.isExternalPowerConnected,
              let start = before.currentCapacity, let end = after.currentCapacity,
              let full = after.fullChargeCapacity ?? before.fullChargeCapacity, full > 0,
              Double(end - start) <= Double(full) * Self.restingRise
        else { return nil }
        self.init(start: sleptAt, end: wokeAt, startCapacity: start, endCapacity: min(end, start),
                  fullChargeCapacity: full)
    }
}

public enum SleepDrain {
    /// Apple silicon Macs typically lose well under 1% an hour asleep; more than this
    /// usually means something keeps waking the Mac.
    public static let highLossPerHour = 0.01
    /// Sleeps this long give a reliable rate.
    public static let reliableHours = 2.0

    /// "Lost 3% in 8 h 12 min (0.4% an hour)".
    public static func summary(_ session: SleepSession) -> String {
        let minutes = Int((session.hours * 60).rounded())
        let lost = session.lossFraction < 0.005 ? "less than 1%" : String(format: "%.0f%%", session.lossFraction * 100)
        let rate = String(format: "%.1f%%", session.lossPerHour * 100)
        return "Lost \(lost) in \(DurationFormat.readable(minutes)) (\(rate) an hour)"
    }

    /// Hour-weighted average loss per hour across sessions.
    public static func averageLossPerHour(_ sessions: [SleepSession]) -> Double? {
        let hours = sessions.map(\.hours).reduce(0, +)
        guard hours > 0 else { return nil }
        return sessions.map(\.lossFraction).reduce(0, +) / hours
    }

    /// A warning when the latest long sleep drained faster than usual.
    public static func advice(_ sessions: [SleepSession]) -> BatteryAdvice? {
        guard let latest = sessions.max(by: { $0.end < $1.end }), latest.hours >= reliableHours,
              latest.lossPerHour >= highLossPerHour
        else { return nil }
        return BatteryAdvice(
            level: .caution,
            message: String(format: "The last sleep used %.1f%% an hour, which is high. Apps, connected "
                + "accessories or Wake for network access (Battery settings › Options) can keep "
                + "waking the Mac.", latest.lossPerHour * 100))
    }
}
