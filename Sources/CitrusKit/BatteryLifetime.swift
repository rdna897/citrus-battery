import Foundation

/// Lifetime statistics the gas gauge keeps in `BatteryData.LifetimeData`.
public struct BatteryLifetime: Sendable, Equatable {
    /// Hours the pack has been powered since it was assembled.
    public var totalOperatingHours: Int?
    public var minimumTemperatureCelsius: Double?
    public var maximumTemperatureCelsius: Double?
    public var averageTemperatureCelsius: Double?
    public var minimumPackVoltageMillivolts: Int?
    public var maximumPackVoltageMillivolts: Int?
    public var maximumChargeCurrentMilliamps: Int?
    /// Negative: current flowing out of the battery.
    public var maximumDischargeCurrentMilliamps: Int?
    public var temperatureSamples: Int?
    /// Cycle count when the gauge last recalibrated its capacity estimate (Qmax).
    public var cycleCountAtLastCalibration: Int?
    /// When the gauge last wrote these statistics.
    public var updated: Date?

    public init(dictionary d: [String: Any]) {
        func int(_ key: String) -> Int? { MacBatterySnapshot.int(d[key]) }
        totalOperatingHours = int("TotalOperatingTime")
        // The minimum and maximum share a unit, which the maximum shows: a
        // lifetime maximum of 10 °C or less is impossible, so 100 or less is whole
        // degrees. Judged alone, a cold minimum in tenths (5 °C as 50) would pass
        // for whole degrees.
        let minimum = int("MinimumTemperature"), maximum = int("MaximumTemperature")
        let rangeInTenths = Self.isTenths(maximum ?? minimum ?? 0)
        minimumTemperatureCelsius = minimum.map { Self.celsius($0, tenths: rangeInTenths) }
        maximumTemperatureCelsius = maximum.map { Self.celsius($0, tenths: rangeInTenths) }
        averageTemperatureCelsius = int("AverageTemperature").map { Self.celsius($0, tenths: Self.isTenths($0)) }
        minimumPackVoltageMillivolts = int("MinimumPackVoltage")
        maximumPackVoltageMillivolts = int("MaximumPackVoltage")
        maximumChargeCurrentMilliamps = int("MaximumChargeCurrent")
        maximumDischargeCurrentMilliamps = int("MaximumDischargeCurrent")
        temperatureSamples = int("TemperatureSamples")
        cycleCountAtLastCalibration = int("CycleCountLastQmax")
        // Unix seconds; 0 when not recorded.
        updated = int("UpdateTime").flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
    }

    /// Gauges mix whole degrees and tenths of a degree: an M4 Mac stores min/max in
    /// degrees and the average in tenths, an iPhone the reverse. A battery never
    /// reaches 100 °C, and its maximum and average are never 10 °C or less, so
    /// above 100 is tenths.
    static func isTenths(_ raw: Int) -> Bool { raw > 100 }

    static func celsius(_ raw: Int, tenths: Bool) -> Double {
        tenths ? Double(raw) / 10 : Double(raw)
    }
}
