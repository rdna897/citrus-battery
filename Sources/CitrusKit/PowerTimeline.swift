import Foundation

/// One minute of power readings, saved for the power chart.
public struct PowerMinute: Sendable, Equatable {
    /// Start of the minute.
    public var start: Date
    /// Average and highest whole-system power during the minute (W).
    public var averageWatts: Double
    public var peakWatts: Double
    /// Battery charge at the end of the minute (%), if the Mac has a battery.
    public var chargePercent: Int?
    public var onAdapter: Bool

    public init(start: Date, averageWatts: Double, peakWatts: Double, chargePercent: Int?, onAdapter: Bool) {
        self.start = start
        self.averageWatts = averageWatts
        self.peakWatts = peakWatts
        self.chargePercent = chargePercent
        self.onAdapter = onAdapter
    }
}

/// Collects live readings into `PowerMinute`s.
public struct PowerMinuteAggregator: Sendable {
    private var start: Date?
    private var sum = 0.0
    private var count = 0
    private var peak = 0.0
    private var chargePercent: Int?
    private var onAdapter = false

    public init() {}

    /// Adds a reading. Returns the previous minute once a reading from a later minute arrives.
    public mutating func add(watts: Double, at date: Date, chargePercent: Int?, onAdapter: Bool) -> PowerMinute? {
        let minute = Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 60).rounded(.down) * 60)
        var finished: PowerMinute?
        if let start, start != minute {
            finished = flush()
        }
        if start == nil { start = minute }
        sum += watts
        count += 1
        peak = max(peak, watts)
        self.chargePercent = chargePercent
        self.onAdapter = onAdapter
        return finished
    }

    /// The minute so far, if it has readings; starts a new one. Call before sleep.
    public mutating func flush() -> PowerMinute? {
        defer {
            start = nil
            sum = 0
            count = 0
            peak = 0
        }
        guard let start, count > 0 else { return nil }
        return PowerMinute(start: start, averageWatts: sum / Double(count), peakWatts: peak,
                           chargePercent: chargePercent, onAdapter: onAdapter)
    }
}

/// A time span the power chart can show.
public enum PowerPeriod: String, CaseIterable, Sendable, Identifiable {
    case live, hour, day, week, month

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .live: "2 min"
        case .hour: "1 h"
        case .day: "24 h"
        case .week: "7 d"
        case .month: "30 d"
        }
    }

    /// Title for the chart's time axis.
    public var axisTitle: String {
        switch self {
        case .live: "Last 2 minutes"
        case .hour: "Last hour"
        case .day: "Last 24 hours"
        case .week: "Last 7 days"
        case .month: "Last 30 days"
        }
    }

    public var duration: TimeInterval {
        switch self {
        case .live: 120
        case .hour: 3600
        case .day: 86_400
        case .week: 7 * 86_400
        case .month: 30 * 86_400
        }
    }

    /// Width of each plotted point: a few hundred points per period.
    public var bucket: TimeInterval {
        switch self {
        case .live, .hour: 60
        case .day: 5 * 60
        case .week: 30 * 60
        case .month: 2 * 3600
        }
    }
}

/// One plotted point of the power chart.
public struct PowerPoint: Sendable, Equatable, Identifiable {
    /// Middle of the bucket.
    public var date: Date
    public var averageWatts: Double
    public var peakWatts: Double
    public var chargePercent: Int?
    /// Points in the same segment are joined; a new segment starts after a gap
    /// (the Mac was asleep or the app wasn't running).
    public var segment: Int

    public var id: Date { date }
}

public enum PowerTimeline {
    /// How long saved minutes and sleeps are kept.
    public static let retention: TimeInterval = 30 * 86_400

    /// Saved minutes averaged into the period's buckets, oldest first.
    public static func points(_ minutes: [PowerMinute], period: PowerPeriod, now: Date) -> [PowerPoint] {
        let from = now.addingTimeInterval(-period.duration)
        let bucket = period.bucket
        let grouped = Dictionary(grouping: minutes.filter { $0.start >= from && $0.start <= now }) {
            ($0.start.timeIntervalSince1970 / bucket).rounded(.down)
        }
        var points: [PowerPoint] = []
        var segment = 0
        var previous: Double?
        for key in grouped.keys.sorted() {
            let group = grouped[key]!.sorted { $0.start < $1.start }
            // Weighted by minutes, so a partly covered bucket isn't skewed.
            let average = group.map(\.averageWatts).reduce(0, +) / Double(group.count)
            if let previous, key - previous > 1 { segment += 1 }
            previous = key
            points.append(PowerPoint(
                date: Date(timeIntervalSince1970: key * bucket + bucket / 2),
                averageWatts: average,
                peakWatts: group.map(\.peakWatts).max() ?? average,
                chargePercent: group.last { $0.chargePercent != nil }?.chargePercent,
                segment: segment))
        }
        return points
    }

    /// Round local times across the domain, leaving out any too close to the
    /// edges for their centred label to fit.
    public static func ticks(period: PowerPeriod, domain: ClosedRange<Date>,
                      calendar: Calendar = .current) -> [Date] {
        let step: TimeInterval = switch period {
        case .live: 30
        case .hour: 10 * 60
        case .day: 3 * 3600
        case .week: 86_400
        case .month: 5 * 86_400
        }
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        guard span > 0 else { return [] }
        let margin = span * 0.04
        var tick = calendar.startOfDay(for: domain.lowerBound)
        var ticks: [Date] = []
        while tick <= domain.upperBound {
            if tick.timeIntervalSince(domain.lowerBound) >= margin, domain.upperBound.timeIntervalSince(tick) >= margin {
                ticks.append(tick)
            }
            // Day steps follow the calendar so midnight stays midnight across clock changes.
            tick = step >= 86_400
                ? calendar.date(byAdding: .day, value: Int(step / 86_400), to: tick)!
                : tick.addingTimeInterval(step)
        }
        return ticks
    }

    /// Sleeps overlapping the period, clipped to it.
    public static func sleeps(_ sleeps: [DateInterval], period: PowerPeriod, now: Date) -> [DateInterval] {
        let window = DateInterval(start: now.addingTimeInterval(-period.duration), end: now)
        return sleeps.compactMap { $0.intersection(with: window) }.filter { $0.duration > 0 }
    }

    /// Times macOS woke the Mac briefly with the screen off (for network upkeep,
    /// Find My or maintenance) during a sleep: saved minutes that lie wholly
    /// inside a sleep, with back-to-back minutes joined.
    public static func briefWakes(_ minutes: [PowerMinute], sleeps: [DateInterval]) -> [BriefWake] {
        var wakes: [BriefWake] = []
        for minute in minutes.sorted(by: { $0.start < $1.start }) {
            let end = minute.start.addingTimeInterval(60)
            guard sleeps.contains(where: { $0.start <= minute.start && end <= $0.end }) else { continue }
            if let last = wakes.last, last.end >= minute.start {
                wakes[wakes.count - 1].end = end
                wakes[wakes.count - 1].peakWatts = max(last.peakWatts, minute.peakWatts)
            } else {
                wakes.append(BriefWake(start: minute.start, end: end, peakWatts: minute.peakWatts))
            }
        }
        return wakes
    }
}

/// A brief wake during sleep. Times are to the minute: the wake itself
/// usually lasts only seconds.
public struct BriefWake: Sendable, Equatable, Identifiable {
    public var start: Date
    public var end: Date
    public var peakWatts: Double

    public var id: Date { start }
    public var middle: Date { start.addingTimeInterval(end.timeIntervalSince(start) / 2) }
}

/// How power is flowing through the battery, for "Charging with 12.3 W"-style rows.
public enum BatteryFlow {
    /// Below this the battery is effectively resting (it would show as "0.0 W").
    static let restingWatts = 0.05

    public static func describe(_ battery: MacBatterySnapshot) -> (title: String, value: String?) {
        guard let watts = battery.batteryPowerWatts else { return ("Battery", nil) }
        if abs(watts) < restingWatts {
            return ("Battery", battery.isExternalPowerConnected ? "Not charging (running on adapter)" : "Idle")
        }
        return (watts > 0 ? "Charging with" : "Discharging with", String(format: "%.1f W", abs(watts)))
    }
}
