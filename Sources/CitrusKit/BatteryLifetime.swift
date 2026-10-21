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

    public init(dictionary d: [String: Any]) {
        func int(_ key: String) -> Int? { MacBatterySnapshot.int(d[key]) }
        totalOperatingHours = int("TotalOperatingTime")
        minimumTemperatureCelsius = int("MinimumTemperature").map(Self.celsius)
        maximumTemperatureCelsius = int("MaximumTemperature").map(Self.celsius)
        averageTemperatureCelsius = int("AverageTemperature").map(Self.celsius)
        minimumPackVoltageMillivolts = int("MinimumPackVoltage")
        maximumPackVoltageMillivolts = int("MaximumPackVoltage")
        maximumChargeCurrentMilliamps = int("MaximumChargeCurrent")
        maximumDischargeCurrentMilliamps = int("MaximumDischargeCurrent")
        temperatureSamples = int("TemperatureSamples")
        cycleCountAtLastCalibration = int("CycleCountLastQmax")
    }

    /// Gauges mix whole degrees and tenths of a degree: an M4 Mac stores min/max in
    /// degrees and the average in tenths, an iPhone the reverse. A battery never
    /// reaches 100 °C, so anything above 100 is tenths.
    static func celsius(_ raw: Int) -> Double {
        raw > 100 ? Double(raw) / 10 : Double(raw)
    }
}
