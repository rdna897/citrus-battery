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
    /// Times macOS woke the Mac briefly with the screen off during the sleep;
    /// `nil` when there were no power readings to count them from.
    public var briefWakes: Int?
    /// Whether macOS's power log covered the sleep, so its brief wakes' reasons
    /// were saved (see `WakeLog`).
    public var wakesLogged: Bool

    public init(id: Int64 = 0, start: Date, end: Date, startCapacity: Int, endCapacity: Int,
                fullChargeCapacity: Int, briefWakes: Int? = nil, wakesLogged: Bool = false) {
        self.id = id
        self.start = start
        self.end = end
        self.startCapacity = startCapacity
        self.endCapacity = endCapacity
        self.fullChargeCapacity = fullChargeCapacity
        self.briefWakes = briefWakes
        self.wakesLogged = wakesLogged
    }

    public var interval: DateInterval { DateInterval(start: start, end: end) }

    /// Higher than Apple silicon Macs usually lose, over a sleep long enough to tell.
    public var isHighLoss: Bool {
        hours >= SleepDrain.reliableHours && lossPerHour >= SleepDrain.highLossPerHour
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

    /// Brief wakes during a session, counted from the power readings saved then;
    /// `nil` when none of those readings go back that far.
    public static func briefWakes(during session: SleepSession, minutes: [PowerMinute]) -> Int? {
        guard let first = minutes.first?.start, first <= session.start else { return nil }
        return PowerTimeline.briefWakes(minutes, sleeps: [session.interval]).count
    }

    /// A warning when the latest long sleep drained faster than usual.
    public static func advice(_ sessions: [SleepSession]) -> BatteryAdvice? {
        guard let latest = sessions.max(by: { $0.end < $1.end }), latest.isHighLoss
        else { return nil }
        return BatteryAdvice(
            level: .caution,
            message: String(format: "The last sleep used %.1f%% an hour, which is high. Apps, connected "
                + "accessories or Wake for network access (Battery settings › Options) can keep "
                + "waking the Mac.", latest.lossPerHour * 100))
    }
}

/// Figures for the sleeps in a chosen period.
public struct SleepStats: Sendable, Equatable {
    public var count: Int
    public var hours: Double
    /// Total charge lost, as a fraction of a full charge.
    public var lossFraction: Double
    /// Hour-weighted: the total lost over the total time asleep.
    public var lossPerHour: Double?
    public var lossPerSleep: Double?
    /// Over the sleeps whose brief wakes were counted.
    public var briefWakesPerHour: Double?
    public var highLossCount: Int

    public init(_ sessions: [SleepSession]) {
        count = sessions.count
        hours = sessions.map(\.hours).reduce(0, +)
        lossFraction = sessions.map(\.lossFraction).reduce(0, +)
        lossPerHour = hours > 0 ? lossFraction / hours : nil
        lossPerSleep = count > 0 ? lossFraction / Double(count) : nil
        let counted = sessions.filter { $0.briefWakes != nil }
        let countedHours = counted.map(\.hours).reduce(0, +)
        briefWakesPerHour = countedHours > 0
            ? Double(counted.compactMap(\.briefWakes).reduce(0, +)) / countedHours : nil
        highLossCount = sessions.filter(\.isHighLoss).count
    }
}

/// The periods offered for sleep statistics.
public enum SleepPeriod: String, CaseIterable, Sendable, Identifiable {
    case week, month, quarter, all, custom

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .week: "7 Days"
        case .month: "30 Days"
        case .quarter: "90 Days"
        case .all: "All"
        case .custom: "Custom"
        }
    }

    /// Days back from today, for the fixed periods.
    public var days: Int? {
        switch self {
        case .week: 7
        case .month: 30
        case .quarter: 90
        case .all, .custom: nil
        }
    }

    /// Sessions that ended within the period. A fixed period counts back whole
    /// days from the end of today; a custom one runs from the start of `from` to
    /// the end of `to`.
    public func sessions(_ sessions: [SleepSession], from: Date, to: Date, now: Date,
                         calendar: Calendar = .current) -> [SleepSession] {
        let range: ClosedRange<Date>
        switch self {
        case .all:
            return sessions
        case .custom:
            let start = calendar.startOfDay(for: min(from, to))
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: max(from, to)))!
            range = start...end
        case .week, .month, .quarter:
            let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
            range = calendar.date(byAdding: .day, value: -(days ?? 0), to: end)!...end
        }
        return sessions.filter { range.contains($0.end) }
    }
}
