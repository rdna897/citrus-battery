import Foundation

/// The trend of a battery's health over its saved history.
public struct HealthForecast: Sendable, Equatable {
    /// Health change per year as a fraction (−0.03 = losing 3% of design capacity a year).
    public var changePerYear: Double
    /// Trend health at the latest reading.
    public var currentHealth: Double
    public var firstDate: Date
    public var latestDate: Date
    /// Days with at least one reading.
    public var readingDays: Int
    /// Average charge cycles a month over the same period.
    public var cyclesPerMonth: Double?
    public var threshold: Double
    public var outlook: Outlook

    public enum Outlook: Sendable, Equatable {
        /// Losing less than `stableChangePerYear`.
        case stable
        /// The trend reaches the threshold on this date.
        case reaches(Date)
        /// The trend takes longer than `horizonYears` to reach the threshold.
        case beyondHorizon
        /// Health is already at or below the threshold.
        case belowThreshold
    }

    /// Losses smaller than this (0.5% a year) are within the gauge's noise.
    public static let stableChangePerYear = -0.005
    public static let horizonYears = 10.0
    /// History needed before a trend is meaningful: capacity readings wander by a
    /// percent or two, which swamps a shorter span.
    public static let minimumDays = 60
    public static let minimumReadingDays = 5
    /// Only the most recent year is fitted: the loss rate changes as a battery ages.
    public static let windowDays = 365

    /// Trend health on a date.
    public func health(at date: Date) -> Double {
        currentHealth + changePerYear * date.timeIntervalSince(latestDate) / Self.secondsPerYear
    }

    static let secondsPerYear = 365.25 * 86_400
}

/// The forecast, or how much history has been collected towards one.
public enum HealthTrend: Sendable, Equatable {
    case forecast(HealthForecast)
    /// Not enough history yet: the days spanned and days with readings so far.
    case collecting(days: Int, readingDays: Int)
}

extension HealthForecast {
    /// The trend for one device's entries, or `nil` when none has a health reading.
    ///
    /// Only the current battery is considered (entries recorded with another
    /// battery serial are skipped). Each day is reduced to its median reading
    /// and the slope is the median of all pairwise slopes (Theil–Sen), so
    /// occasional gauge recalibrations don't skew it.
    public static func trend(entries: [HistoryEntry], threshold: Double = 0.8,
                             calendar: Calendar = .current) -> HealthTrend? {
        var readings = entries.filter { $0.healthFraction != nil }.sorted { $0.date < $1.date }
        guard let latest = readings.last else { return nil }
        if let serial = readings.last(where: { $0.batterySerial != nil })?.batterySerial {
            readings.removeAll { $0.batterySerial != nil && $0.batterySerial != serial }
        }
        let windowStart = latest.date.addingTimeInterval(-Double(windowDays) * 86_400)
        readings.removeAll { $0.date < windowStart }

        let byDay = Dictionary(grouping: readings) { calendar.startOfDay(for: $0.date) }
        let days = byDay.keys.sorted()
        guard let first = days.first, let last = days.last else { return nil }
        let span = calendar.dateComponents([.day], from: first, to: last).day ?? 0
        guard span >= minimumDays, days.count >= minimumReadingDays else {
            return .collecting(days: span, readingDays: days.count)
        }

        // x: years since the first day; y: that day's median health.
        let points = days.map { day in
            (x: day.timeIntervalSince(first) / secondsPerYear,
             y: median(byDay[day]!.compactMap(\.healthFraction)))
        }
        var slopes: [Double] = []
        slopes.reserveCapacity(points.count * (points.count - 1) / 2)
        for i in points.indices {
            for j in points.indices where j > i {
                slopes.append((points[j].y - points[i].y) / (points[j].x - points[i].x))
            }
        }
        let slope = median(slopes)
        let intercept = median(points.map { $0.y - slope * $0.x })
        let current = intercept + slope * points.last!.x

        let outlook: Outlook
        if current <= threshold {
            outlook = .belowThreshold
        } else if slope > stableChangePerYear {
            outlook = .stable
        } else {
            let years = (current - threshold) / -slope
            outlook = years > horizonYears ? .beyondHorizon
                : .reaches(last.addingTimeInterval(years * secondsPerYear))
        }

        let cycled = readings.filter { $0.cycleCount != nil }
        var cyclesPerMonth: Double?
        if let a = cycled.first, let b = cycled.last, let from = a.cycleCount, let to = b.cycleCount, to >= from {
            let months = b.date.timeIntervalSince(a.date) / (secondsPerYear / 12)
            if months >= 1 { cyclesPerMonth = Double(to - from) / months }
        }

        return .forecast(HealthForecast(
            changePerYear: slope, currentHealth: current, firstDate: first, latestDate: last,
            readingDays: days.count, cyclesPerMonth: cyclesPerMonth, threshold: threshold, outlook: outlook))
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

extension HealthTrend {
    /// One line for a details row, e.g. "Losing 3.2% a year; 80% around Mar 2028".
    public var summary: String {
        switch self {
        case let .collecting(days, readingDays):
            if days < HealthForecast.minimumDays {
                return "Collecting history (\(days) of \(HealthForecast.minimumDays) days)"
            }
            return "Collecting history (\(readingDays) of \(HealthForecast.minimumReadingDays) readings)"
        case let .forecast(forecast):
            let threshold = "\(Int((forecast.threshold * 100).rounded()))%"
            let stable = forecast.changePerYear > HealthForecast.stableChangePerYear
            let rate = String(format: "Losing %.1f%% a year", -forecast.changePerYear * 100)
            switch forecast.outlook {
            case .stable:
                return "Stable, no measurable loss"
            case let .reaches(date):
                return "\(rate); \(threshold) around \(date.formatted(.dateTime.month(.abbreviated).year()))"
            case .beyondHorizon:
                return "\(rate); \(threshold) in over \(Int(HealthForecast.horizonYears)) years"
            case .belowThreshold:
                return stable ? "Stable, below \(threshold)" : "\(rate); already below \(threshold)"
            }
        }
    }
}
