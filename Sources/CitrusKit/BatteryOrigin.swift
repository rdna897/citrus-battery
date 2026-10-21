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

    // MARK: 17-character battery serial

    /// coconutBattery's year for each digit, used when there's no operating-time estimate.
    private static let serialYears = [0: 2020, 1: 2021, 2: 2022, 3: 2023, 4: 2014,
                                      5: 2015, 6: 2016, 7: 2017, 8: 2018, 9: 2019]

    /// Manufacture date (Monday of the week) from a 17-character battery serial:
    /// position 4 is the last digit of the year, positions 5–6 the ISO week.
    ///
    /// The serial only gives the year within a decade. With an operating-time
    /// `estimate`, the decade closest to it wins. Without one, this follows
    /// coconutBattery: digits 0–3 are the 2020s, 4–9 the 2010s, a "2023" pack
    /// with over 300 cycles is from 2013, and a date in the future moves back ten years.
    public static func serialManufactureDate(
        serial: String, estimate: Date? = nil, cycleCount: Int? = nil, now: Date = Date()
    ) -> Date? {
        let characters = Array(serial.trimmingCharacters(in: .whitespaces))
        guard characters.count == 17,
              let digit = characters[3].wholeNumberValue, characters[3].isASCII,
              let week = Int(String(characters[4...5])), (1...53).contains(week)
        else { return nil }

        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = TimeZone(identifier: "UTC")!
        func monday(_ year: Int) -> Date? {
            let date = iso.date(from: DateComponents(weekday: 2, weekOfYear: week, yearForWeekOfYear: year))
            // Week 53 only exists in some years; reject dates that rolled into the next year.
            return date.flatMap { iso.component(.yearForWeekOfYear, from: $0) == year ? $0 : nil }
        }

        if let estimate {
            let around = iso.component(.year, from: estimate)
            let years = (around - 10...around + 10).filter { (($0 % 10) + 10) % 10 == digit }
            return years.compactMap(monday).filter { $0 <= now }
                .min { abs($0.timeIntervalSince(estimate)) < abs($1.timeIntervalSince(estimate)) }
        }

        guard var year = serialYears[digit] else { return nil }
        if year == 2023, let cycleCount, cycleCount > 300 { year = 2013 }
        guard let date = monday(year) else { return nil }
        return date > now ? monday(year - 10) : date
    }

    // MARK: Mac serial date code

    private static let yearCodes = Array("CDFGHJKLMNPQRSTVWXYZ")
    private static let weekCodes = Array("123456789CDFGHJKLMNPQRTVWXY")

    /// Intel Macs from 2020 on still used dated 12-character serials; their year
    /// codes repeat the 2010s letters a decade later.
    static let modelsFrom2020s: Set<String> = [
        "MacBookAir9,1", "MacBookPro16,2", "MacBookPro16,3", "iMac20,1", "iMac20,2",
    ]

    /// Manufacture date (Monday of the week) from a classic 11/12-character Mac
    /// serial number: position 4 is the year and half-year, position 5 the week
    /// within that half. Apple silicon serials are random and carry no date.
    public static func macManufactureDate(serial: String, modelIdentifier: String) -> DateComponents? {
        let characters = Array(serial.uppercased())
        guard characters.count == 11 || characters.count == 12 else { return nil }
        let yearIndex = characters.count == 12 ? 3 : 2
        guard let i = yearCodes.firstIndex(of: characters[yearIndex]),
              let j = weekCodes.firstIndex(of: characters[yearIndex + 1])
        else { return nil }
        let base = modelsFrom2020s.contains(modelIdentifier) ? 2029 : 2019
        let year = base - (19 - i) / 2
        let week = j + (i % 2 == 0 ? 1 : 27)
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = TimeZone(identifier: "UTC")!
        guard let monday = iso.date(from: DateComponents(weekday: 2, weekOfYear: week, yearForWeekOfYear: year))
        else { return nil }
        return iso.dateComponents([.year, .month, .day], from: monday)
    }
}
