import Foundation

/// Power adapter details from `AdapterDetails`.
public struct PowerAdapter: Sendable, Equatable {
    public var watts: Int?
    public var name: String?
    public var voltageMillivolts: Int?
    public var currentMilliamps: Int?
}

/// macOS's own view of the battery, from the IOPS power-source API.
public struct PowerSourceInfo: Sendable, Equatable {
    /// The percentage macOS shows in the menu bar.
    public var chargePercent: Int?
    public var timeToEmptyMinutes: Int?
    public var timeToFullMinutes: Int?
    /// "Good", "Fair", "Poor", or a condition such as "Service Recommended".
    public var healthDescription: String?

    public init(chargePercent: Int? = nil, timeToEmptyMinutes: Int? = nil,
                timeToFullMinutes: Int? = nil, healthDescription: String? = nil) {
        self.chargePercent = chargePercent
        self.timeToEmptyMinutes = timeToEmptyMinutes
        self.timeToFullMinutes = timeToFullMinutes
        self.healthDescription = healthDescription
    }
}

/// One reading of the Mac's internal battery.
public struct MacBatterySnapshot: Sendable, Equatable {
    public var date: Date

    /// Remaining charge (mAh).
    public var currentCapacity: Int?
    /// Capacity when full, as the gas gauge currently estimates it (mAh).
    public var fullChargeCapacity: Int?
    /// Capacity when new (mAh).
    public var designCapacity: Int?
    /// Apple's "Maximum Capacity" basis on Apple Silicon (mAh).
    public var nominalChargeCapacity: Int?

    public var cycleCount: Int?
    public var designCycleCount: Int?
    public var temperatureCelsius: Double?
    public var voltageMillivolts: Int?
    /// Positive while charging, negative while discharging (mA).
    public var amperageMilliamps: Int?

    public var isCharging: Bool
    public var isExternalPowerConnected: Bool
    public var isFullyCharged: Bool
    public var timeToEmptyMinutes: Int?
    public var timeToFullMinutes: Int?

    public var adapter: PowerAdapter?
    public var serialNumber: String?
    public var gasGaugeName: String?
    /// Cell manufacturer, from the registry or decoded from the serial prefix.
    public var manufacturer: String?
    public var manufactureDate: DateComponents?
    /// Manufacture week without a year, when no full date is available.
    public var manufactureWeek: BatteryOrigin.ManufactureWeek?
    public var failures: BatteryFailure
    public var powerSource: PowerSourceInfo?

    // MARK: Derived values

    /// Remaining ÷ full-charge capacity (0–1).
    public var rawChargeFraction: Double? {
        guard let currentCapacity, let fullChargeCapacity, fullChargeCapacity > 0 else { return nil }
        return min(Double(currentCapacity) / Double(fullChargeCapacity), 1)
    }

    /// Charge fraction for the chosen display style.
    public func chargeFraction(style: CapacityStyle) -> Double? {
        switch style {
        case .raw:
            return rawChargeFraction
        case .apple:
            return powerSource?.chargePercent.map { Double($0) / 100 } ?? rawChargeFraction
        }
    }

    /// Full-charge ÷ design capacity (0–∞; above 1 for new batteries).
    public var healthFraction: Double? {
        guard let fullChargeCapacity, let designCapacity, designCapacity > 0 else { return nil }
        return Double(fullChargeCapacity) / Double(designCapacity)
    }

    /// Power flowing into (+) or out of (−) the battery, in watts.
    public var batteryPowerWatts: Double? {
        guard let voltageMillivolts, let amperageMilliamps else { return nil }
        return Double(voltageMillivolts) * Double(amperageMilliamps) / 1_000_000
    }

    /// Minutes until empty or full, whichever applies, preferring macOS's estimate.
    public var timeRemainingMinutes: Int? {
        if isCharging {
            return powerSource?.timeToFullMinutes ?? timeToFullMinutes
        }
        if isExternalPowerConnected { return nil }
        return powerSource?.timeToEmptyMinutes ?? timeToEmptyMinutes
    }
}

extension MacBatterySnapshot {
    /// Builds a snapshot from `AppleSmartBattery` registry properties.
    ///
    /// Intel Macs publish capacities in mAh at the top level, and
    /// `AppleRawCurrentCapacity`/`AppleRawMaxCapacity` hold raw values. Apple
    /// Silicon publishes percentages at the top level and real capacities
    /// inside `BatteryData`, and may omit temperature entirely. In that case
    /// the SMC is used.
    public init(registry r: [String: Any], smc: SMCReading?, powerSource: PowerSourceInfo?, date: Date = Date()) {
        let batteryData = r["BatteryData"] as? [String: Any] ?? [:]
        let topLevelIsPercent = Self.int(r["MaxCapacity"]).map { $0 <= 100 } ?? false

        self.date = date
        designCapacity = Self.int(batteryData["DesignCapacity"]) ?? Self.int(r["DesignCapacity"])
            ?? smc?.double(SMCKey.designCapacity).map { Int($0) }
        fullChargeCapacity = Self.int(r["AppleRawMaxCapacity"]) ?? Self.int(batteryData["FullChargeCapacity"])
            ?? (topLevelIsPercent ? nil : Self.int(r["MaxCapacity"]))
            ?? smc?.double(SMCKey.fullChargeCapacity).map { Int($0) }
        currentCapacity = Self.int(r["AppleRawCurrentCapacity"]) ?? Self.int(batteryData["RemainingCapacity"])
            ?? (topLevelIsPercent ? nil : Self.int(r["CurrentCapacity"]))
            ?? smc?.double(firstOf: SMCKey.remainingCapacity).map { Int($0) }
        nominalChargeCapacity = Self.int(r["NominalChargeCapacity"]) ?? Self.int(batteryData["NominalChargeCapacity"])

        cycleCount = Self.int(r["CycleCount"]) ?? smc?.double(SMCKey.cycleCount).map { Int($0) }
        designCycleCount = Self.int(r["DesignCycleCount9C"]) ?? Self.int(r["DesignCycleCount70"])

        if let centi = Self.int(r["Temperature"]) ?? Self.int(r["VirtualTemperature"]) {
            temperatureCelsius = Double(centi) / 100
        } else {
            temperatureCelsius = smc?.double(SMCKey.batteryTemperature)
        }

        voltageMillivolts = Self.int(r["Voltage"]) ?? Self.int(r["AppleRawBatteryVoltage"])
        amperageMilliamps = Self.int(r["InstantAmperage"]) ?? Self.int(r["Amperage"])

        isCharging = Self.bool(r["IsCharging"]) ?? false
        isExternalPowerConnected = Self.bool(r["ExternalConnected"]) ?? false
        isFullyCharged = Self.bool(r["FullyCharged"]) ?? false
        timeToEmptyMinutes = Self.minutes(r["AvgTimeToEmpty"])
        timeToFullMinutes = Self.minutes(r["AvgTimeToFull"])

        if let details = r["AdapterDetails"] as? [String: Any], !details.isEmpty {
            adapter = PowerAdapter(
                watts: Self.int(details["Watts"]),
                name: details["Name"] as? String ?? details["Description"] as? String,
                voltageMillivolts: Self.int(details["AdapterVoltage"]),
                currentMilliamps: Self.int(details["Current"])
            )
        }

        serialNumber = (r["Serial"] as? String) ?? (r["BatterySerialNumber"] as? String)
            ?? smc?.read(SMCKey.batterySerial)?.stringValue
        gasGaugeName = r["DeviceName"] as? String
        manufacturer = r["Manufacturer"] as? String ?? serialNumber.flatMap(BatteryOrigin.manufacturer(serial:))
        manufactureDate = Self.int(r["ManufactureDate"]).flatMap(Self.decodePackedDate)
        if manufactureDate == nil {
            manufactureWeek = smc?.read(SMCKey.batteryManufactureWeek)?.stringValue
                .flatMap(BatteryOrigin.manufactureWeek(bmdt:))
        }
        failures = BatteryFailure(rawValue: Self.int(r["PermanentFailureStatus"])
            ?? Self.int(batteryData["PermanentFailureStatus"]) ?? 0)
        self.powerSource = powerSource
    }

    /// Decodes the Smart Battery Data packed date: `(year − 1980) << 9 | month << 5 | day`.
    public static func decodePackedDate(_ value: Int) -> DateComponents? {
        let day = value & 0x1F
        let month = (value >> 5) & 0x0F
        let year = (value >> 9) + 1980
        guard (1...31).contains(day), (1...12).contains(month), year < 2100 else { return nil }
        return DateComponents(year: year, month: month, day: day)
    }

    /// Reads integers, reinterpreting unsigned 64-bit registry values as signed
    /// (IOKit stores negative amperage as a huge unsigned number).
    static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        return Int(truncatingIfNeeded: number.int64Value)
    }

    static func bool(_ value: Any?) -> Bool? {
        (value as? NSNumber)?.boolValue
    }

    /// `65535` means "still calculating".
    static func minutes(_ value: Any?) -> Int? {
        guard let minutes = int(value), minutes >= 0, minutes < 0xFFFF else { return nil }
        return minutes
    }
}
