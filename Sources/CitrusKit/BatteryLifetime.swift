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
        minimumTemperatureCelsius = int("MinimumTemperature").map(Double.init)
        maximumTemperatureCelsius = int("MaximumTemperature").map(Double.init)
        // Stored in tenths of a degree, unlike the minimum and maximum.
        averageTemperatureCelsius = int("AverageTemperature").map { Double($0) / 10 }
        minimumPackVoltageMillivolts = int("MinimumPackVoltage")
        maximumPackVoltageMillivolts = int("MaximumPackVoltage")
        maximumChargeCurrentMilliamps = int("MaximumChargeCurrent")
        maximumDischargeCurrentMilliamps = int("MaximumDischargeCurrent")
        temperatureSamples = int("TemperatureSamples")
        cycleCountAtLastCalibration = int("CycleCountLastQmax")
    }
}
