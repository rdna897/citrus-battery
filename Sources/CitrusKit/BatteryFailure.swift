/// Decoded `PermanentFailureStatus` flags reported by the battery gas gauge.
public struct BatteryFailure: OptionSet, Sendable, Hashable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let externalInputProblem = BatteryFailure(rawValue: 1 << 0)
    public static let safetyOvervoltage = BatteryFailure(rawValue: 1 << 1)
    public static let chargeOverTemperature = BatteryFailure(rawValue: 1 << 2)
    public static let dischargeOverTemperature = BatteryFailure(rawValue: 1 << 3)
    public static let cellImbalance = BatteryFailure(rawValue: 1 << 4)
    public static let chargeFETFailure = BatteryFailure(rawValue: 1 << 5)
    public static let dischargeFETFailure = BatteryFailure(rawValue: 1 << 6)
    public static let dataFlushFault = BatteryFailure(rawValue: 1 << 7)
    public static let permanentAFECommunicationFailure = BatteryFailure(rawValue: 1 << 8)
    public static let periodicAFECommunicationFailure = BatteryFailure(rawValue: 1 << 9)
    public static let chargeSafetyOverCurrent = BatteryFailure(rawValue: 1 << 10)
    public static let dischargeSafetyOverCurrent = BatteryFailure(rawValue: 1 << 11)
    public static let openThermistor = BatteryFailure(rawValue: 1 << 12)
    public static let fuseBlown = BatteryFailure(rawValue: 1 << 15)

    private static let descriptions: [(BatteryFailure, String)] = [
        (.externalInputProblem, "External Input Problem"),
        (.safetyOvervoltage, "Safety Overvoltage"),
        (.chargeOverTemperature, "Charge Over-Temperature"),
        (.dischargeOverTemperature, "Discharge Over-Temperature"),
        (.cellImbalance, "Cell Imbalance"),
        (.chargeFETFailure, "Charge FET Failure"),
        (.dischargeFETFailure, "Discharge FET Failure"),
        (.dataFlushFault, "Data Flush Fault"),
        (.permanentAFECommunicationFailure, "Permanent AFE Communication Failure"),
        (.periodicAFECommunicationFailure, "Periodic AFE Communication Failure"),
        (.chargeSafetyOverCurrent, "Charge Safety Over Current"),
        (.dischargeSafetyOverCurrent, "Discharge Safety Over Current"),
        (.openThermistor, "Open Thermistor"),
        (.fuseBlown, "Fuse Blown"),
    ]

    /// Human-readable names of every set flag, in bit order.
    public var messages: [String] {
        Self.descriptions.filter { contains($0.0) }.map(\.1)
    }
}
