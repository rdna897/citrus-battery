import Foundation

/// Where and when a battery cell pack was made, decoded from identifiers the
/// battery reports.
public enum BatteryOrigin {
    /// Cell manufacturers keyed by the first two characters of the battery serial.
    private static let manufacturerPrefixes: [(name: String, prefixes: [String])] = [
        ("Amperex Technology Ltd. (ATL)", ["AC", "AE", "AF", "AX", "AZ", "YF"]),
        ("Huizhou Desay Battery", ["43", "F5", "FD", "FU", "LD", "LY", "RE", "ZP"]),
        ("Sony", ["FX", "RD", "YG", "YV", "YW"]),
        ("Samsung", ["LZ", "SB", "ST"]),
        ("Huapu Technology", ["DV", "FG", "HH", "HT"]),
        ("Simplo Technology", ["D8", "D9", "W0"]),
        ("Sunwoda", ["64", "77", "79", "F8", "LM", "YS"]),
        ("LG Chem", ["LN", "YH"]),
        ("Dynapack Electronics", ["9G", "C0", "DP"]),
        ("TianJin Lishen Battery", ["TP"]),
        ("Dongguan NVT Technology", ["FQ"]),
    ]

    /// Cell manufacturer implied by a battery serial number, if the prefix is known.
    public static func manufacturer(serial: String) -> String? {
        let prefix = serial.trimmingCharacters(in: .whitespaces).prefix(2).uppercased()
        guard prefix.count == 2 else { return nil }
        return manufacturerPrefixes.first { $0.prefixes.contains(prefix) }?.name
    }

    /// A manufacture week recorded without a year.
    public struct ManufactureWeek: Sendable, Equatable {
        /// ISO 8601 week of the year (1–53).
        public var week: Int
        /// Calendar month (1–12) containing that week's Monday.
        public var month: Int
    }

    /// Estimates when the pack was made from its powered-on hours.
    ///
    /// This is the method coconutBattery uses (today − operating hours). When the
    /// battery also records its manufacture week (which carries no year), the
    /// estimate picks the year and the recorded week gives the exact Monday.
    public static func estimatedManufactureDate(
        operatingHours: Int, week: ManufactureWeek?, now: Date = Date(),
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> Date? {
        guard operatingHours > 0,
              let estimate = calendar.date(byAdding: .day, value: -(operatingHours / 24), to: now)
        else { return nil }
        let estimateDay = calendar.startOfDay(for: estimate)
        guard let week else { return estimateDay }

        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = calendar.timeZone
        let year = calendar.component(.year, from: estimate)
        let candidates = (year - 1...year + 1).compactMap { y in
            iso.date(from: DateComponents(weekday: 2, weekOfYear: week.week, yearForWeekOfYear: y))
        }.filter { $0 <= now }
        return candidates.min { abs($0.timeIntervalSince(estimate)) < abs($1.timeIntervalSince(estimate)) }
            ?? estimateDay
    }

    /// Decodes the SMC `BMDT` string found on Apple Silicon batteries, e.g.
    /// `"330802"`: ISO week 33, month 08, weekday 2 (Monday).
    ///
    /// The value carries no year, so only the week and month are returned.
    public static func manufactureWeek(bmdt: String) -> ManufactureWeek? {
        let digits = bmdt.trimmingCharacters(in: CharacterSet.decimalDigits.inverted)
        guard digits.count == 6, digits.allSatisfy(\.isASCII),
              let week = Int(digits.prefix(2)),
              let month = Int(digits.dropFirst(2).prefix(2)),
              (1...53).contains(week), (1...12).contains(month)
        else { return nil }
        return ManufactureWeek(week: week, month: month)
    }
}
