import Foundation

/// How evenly the cells of a multi-cell pack are charged.
public enum CellBalance {
    /// A gap this large (mV) is worth a closer look; the gauge keeps healthy packs
    /// within a few tens of millivolts.
    public static let cautionSpread = 100

    /// Highest minus lowest cell voltage (mV), for packs with two or more cells.
    public static func spread(_ cells: [Int]) -> Int? {
        guard cells.count > 1, let low = cells.min(), let high = cells.max() else { return nil }
        return high - low
    }

    /// "4.421 · 4.431 · 4.433 V (12 mV apart)".
    public static func text(_ cells: [Int]) -> String? {
        guard let spread = spread(cells) else { return nil }
        let volts = cells.map { String(format: "%.3f", Double($0) / 1000) }.joined(separator: " · ")
        return "\(volts) V (\(spread) mV apart)"
    }

    public static func advice(_ cells: [Int]) -> BatteryAdvice? {
        guard let spread = spread(cells), spread >= cautionSpread else { return nil }
        return BatteryAdvice(
            level: .caution,
            message: "The cells differ by \(spread) mV. If the gap stays this large while the device is "
                + "idle, one cell may be wearing faster than the others.")
    }
}
