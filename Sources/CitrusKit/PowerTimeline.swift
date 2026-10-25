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

    /// The periods worth offering, given when recording began: 7 d once there's
    /// more than 24 hours of records, 30 d once there's more than 7 days.
    public static func available(recordedSince start: Date?, now: Date) -> [PowerPeriod] {
        let span = start.map { now.timeIntervalSince($0) } ?? 0
        return allCases.filter { period in
            switch period {
            case .live, .hour, .day: true
            case .week: span > PowerPeriod.day.duration
            case .month: span > PowerPeriod.week.duration
            }
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

/// One point of the charge level line.
public struct ChargePoint: Sendable, Equatable, Identifiable {
    public var date: Date
    public var percent: Double
    /// Points in the same segment are joined.
    public var segment: Int

    public var id: Date { date }
}

public enum PowerTimeline {
    /// How long saved minutes and sleeps are kept.
    public static let retention: TimeInterval = 30 * 86_400

    /// The shortest span a history chart shows.
    public static let minimumSpan: TimeInterval = 10 * 60

    /// The time span to chart: the period, unless saved readings start later,
    /// in which case it starts with them so a short history fills the width.
    public static func domain(period: PowerPeriod, minutes: [PowerMinute], sleeps: [DateInterval],
                              now: Date) -> ClosedRange<Date> {
        let from = now.addingTimeInterval(-period.duration)
        let firstMinute: Date? = minutes.lazy.map(\.start).filter { $0 >= from }.min()
        let firstSleep: Date? = sleeps.lazy.filter { $0.end > from }.map(\.start).min()
        guard let first = [firstMinute, firstSleep].compactMap({ $0 }).min() else { return from...now }
        return min(max(from, first), now.addingTimeInterval(-minimumSpan))...now
    }

    /// Width of each plotted point: the shortest that keeps a few hundred points.
    public static func bucket(span: TimeInterval) -> TimeInterval {
        let buckets: [TimeInterval] = [60, 5 * 60, 30 * 60, 2 * 3600]
        return buckets.first { span / $0 <= 400 } ?? 2 * 3600
    }

    /// Saved minutes averaged into buckets across the domain, oldest first.
    public static func points(_ minutes: [PowerMinute], in domain: ClosedRange<Date>) -> [PowerPoint] {
        let bucket = bucket(span: domain.upperBound.timeIntervalSince(domain.lowerBound))
        let grouped = Dictionary(grouping: minutes.filter { domain.contains($0.start) }) {
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

    /// The charge level across the domain. Charge carries on through sleep, so
    /// unlike power the line joins across a sleep, breaking only where the app
    /// wasn't running. When the domain starts during a sleep, the line starts at
    /// the edge, between the readings either side of it, as in a longer view.
    public static func chargeLine(_ minutes: [PowerMinute], in domain: ClosedRange<Date>,
                                  sleeps: [DateInterval]) -> [ChargePoint] {
        let half = bucket(span: domain.upperBound.timeIntervalSince(domain.lowerBound)) / 2
        // Whether a sleep spans a gap. Readings stop a little before sleep and resume a
        // little after waking, so it need only come within a couple of minutes of them.
        func asleep(from: Date, to: Date) -> Bool {
            sleeps.contains { $0.start <= from.addingTimeInterval(120) && $0.end >= to.addingTimeInterval(-120) }
        }
        var line: [ChargePoint] = []
        var segment = 0
        var lastEnd: Date?
        for point in points(minutes, in: domain) {
            guard let percent = point.chargePercent.map(Double.init) else { continue }
            let start = point.date.addingTimeInterval(-half)
            if let lastEnd {
                if start > lastEnd, !asleep(from: lastEnd, to: start) { segment += 1 }
            } else if let before = minutes.filter({ $0.start < domain.lowerBound && $0.chargePercent != nil })
                        .max(by: { $0.start < $1.start }),
                      let charge = before.chargePercent,
                      asleep(from: before.start.addingTimeInterval(60), to: start) {
                let from = before.start.addingTimeInterval(30)
                let share = domain.lowerBound.timeIntervalSince(from) / point.date.timeIntervalSince(from)
                line.append(ChargePoint(date: domain.lowerBound,
                                        percent: Double(charge) + (percent - Double(charge)) * share, segment: 0))
            }
            line.append(ChargePoint(date: point.date, percent: percent, segment: segment))
            lastEnd = point.date.addingTimeInterval(half)
        }
        return line
    }

    /// Width of each bar: the shortest round slot that keeps about a hundred bars.
    public static func barWidth(span: TimeInterval) -> TimeInterval {
        let widths: [TimeInterval] = [60, 5 * 60, 15 * 60, 30 * 60, 3600, 2 * 3600, 4 * 3600, 8 * 3600]
        return widths.first { span / $0 <= 100 } ?? 8 * 3600
    }

    /// Bars across the domain in slots of `barWidth`, counted from local midnight.
    /// Power is averaged over the time the Mac was awake or asleep in the slot, so
    /// a brief wake in a sleep is a small bar; charge carries on through sleep.
    public static func bars(_ minutes: [PowerMinute], in domain: ClosedRange<Date>, sleeps: [DateInterval],
                            calendar: Calendar = .current) -> [PowerBar] {
        let width = barWidth(span: domain.upperBound.timeIntervalSince(domain.lowerBound))
        let line = chargeLine(minutes, in: domain, sleeps: sleeps)
        let recorded = sortedByStart(minutes.filter { domain.contains($0.start) })
        let midnight = calendar.startOfDay(for: domain.lowerBound)
        var start = midnight.addingTimeInterval(
            (domain.lowerBound.timeIntervalSince(midnight) / width).rounded(.down) * width)
        var bars: [PowerBar] = []
        // Minutes are taken in order as the slots advance: one pass, not one per slot.
        var next = 0
        while start < domain.upperBound {
            let end = start.addingTimeInterval(width)
            let slot = DateInterval(start: start, end: end)
            while next < recorded.count, recorded[next].start < start { next += 1 }
            let first = next
            while next < recorded.count, recorded[next].start < end { next += 1 }
            let inSlot = recorded[first..<next]
            var watts: Double?
            if !inSlot.isEmpty {
                let asleep = sleeps.compactMap { $0.intersection(with: slot)?.duration }.reduce(0, +) / 60
                let awake = Double(inSlot.count)
                watts = inSlot.map(\.averageWatts).reduce(0, +) / max(awake + asleep, awake)
            }
            let adapterMinutes = inSlot.filter(\.onAdapter).count
            bars.append(PowerBar(start: start, end: end, watts: watts,
                                 chargePercent: charge(in: slot, line: line),
                                 onAdapter: !inSlot.isEmpty && adapterMinutes * 2 >= inSlot.count))
            start = end
        }
        return bars.filter { $0.watts != nil || $0.chargePercent != nil }
    }

    /// The charge at the end of a slot: its last point, or between the points
    /// either side when the line passes through it without one.
    private static func charge(in slot: DateInterval, line: [ChargePoint]) -> Double? {
        if let last = line.last(where: { $0.date >= slot.start && $0.date < slot.end }) { return last.percent }
        guard let after = line.firstIndex(where: { $0.date >= slot.end }), after > 0 else { return nil }
        let before = line[after - 1], next = line[after]
        guard before.segment == next.segment else { return nil }
        let share = slot.end.timeIntervalSince(before.date) / next.date.timeIntervalSince(before.date)
        return before.percent + (next.percent - before.percent) * share
    }

    /// Spacing between time axis ticks: the shortest that gives at most eight.
    public static func tickStep(span: TimeInterval) -> TimeInterval {
        let steps: [TimeInterval] = [30, 60, 2 * 60, 5 * 60, 10 * 60, 15 * 60, 30 * 60, 3600, 2 * 3600,
                                     3 * 3600, 6 * 3600, 86_400, 2 * 86_400, 5 * 86_400]
        return steps.first { span / $0 <= 8 } ?? 10 * 86_400
    }

    /// Round local times across the domain, leaving out any too close to the
    /// edges for their centred label to fit.
    public static func ticks(domain: ClosedRange<Date>, calendar: Calendar = .current) -> [Date] {
        let span = domain.upperBound.timeIntervalSince(domain.lowerBound)
        guard span > 0 else { return [] }
        let step = tickStep(span: span)
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

    /// Sleeps overlapping the domain, clipped to it.
    public static func sleeps(_ sleeps: [DateInterval], in domain: ClosedRange<Date>) -> [DateInterval] {
        let window = DateInterval(start: domain.lowerBound, end: domain.upperBound)
        return sleeps.compactMap { $0.intersection(with: window) }.filter { $0.duration > 0 }
    }

    /// Times macOS woke the Mac briefly with the screen off (for network upkeep,
    /// Find My or maintenance) during a sleep: saved minutes that lie wholly
    /// inside a sleep, with back-to-back minutes joined.
    public static func briefWakes(_ minutes: [PowerMinute], sleeps: [DateInterval]) -> [BriefWake] {
        var wakes: [BriefWake] = []
        // Both in order, so each minute is checked against the sleeps around it only.
        let sleeps = sleeps.sorted { $0.start < $1.start }
        var sleep = 0
        for minute in sortedByStart(minutes) {
            let end = minute.start.addingTimeInterval(60)
            while sleep < sleeps.count, sleeps[sleep].end < end { sleep += 1 }
            // Sleeps can overlap, so look on while one could still contain the minute.
            var candidate = sleep
            var inside = false
            while candidate < sleeps.count, sleeps[candidate].start <= minute.start {
                if end <= sleeps[candidate].end { inside = true; break }
                candidate += 1
            }
            guard inside else { continue }
            if let last = wakes.last, last.end >= minute.start {
                wakes[wakes.count - 1].end = end
                wakes[wakes.count - 1].peakWatts = max(last.peakWatts, minute.peakWatts)
            } else {
                wakes.append(BriefWake(start: minute.start, end: end, peakWatts: minute.peakWatts))
            }
        }
        return wakes
    }

    /// Saved minutes are kept in order, so this is usually just a check.
    static func sortedByStart(_ minutes: [PowerMinute]) -> [PowerMinute] {
        let ordered = zip(minutes, minutes.dropFirst()).allSatisfy { $0.start <= $1.start }
        return ordered ? minutes : minutes.sorted { $0.start < $1.start }
    }

    /// Wakes grouped so that each group's neighbours are at most `gap` apart,
    /// for marking a run of wakes once where they would crowd together.
    public static func group(_ wakes: [BriefWake], within gap: TimeInterval) -> [[BriefWake]] {
        var groups: [[BriefWake]] = []
        for wake in wakes.sorted(by: { $0.start < $1.start }) {
            if let last = groups.last?.last, wake.middle.timeIntervalSince(last.middle) <= gap {
                groups[groups.count - 1].append(wake)
            } else {
                groups.append([wake])
            }
        }
        return groups
    }
}

/// One bar of the history charts.
public struct PowerBar: Sendable, Equatable, Identifiable {
    public var start: Date
    public var end: Date
    /// Average system power over the slot (W), if the app recorded any of it.
    public var watts: Double?
    /// Battery charge at the end of the slot (%).
    public var chargePercent: Double?
    /// Most of the recorded slot was on the power adapter.
    public var onAdapter: Bool

    public var id: Date { start }
    public var middle: Date { start.addingTimeInterval(end.timeIntervalSince(start) / 2) }
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
            return ("Battery", battery.isExternalPowerConnected ? "Not charging" : "Idle")
        }
        return (watts > 0 ? "Charging with" : "Discharging with", String(format: "%.1f W", abs(watts)))
    }
}
