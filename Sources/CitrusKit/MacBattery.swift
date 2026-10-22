import Foundation

/// Power adapter details from `AdapterDetails`.
public struct PowerAdapter: Sendable, Equatable {
    /// The power agreed with the charger (W).
    public var watts: Int?
    public var name: String?
    /// Agreed voltage (mV).
    public var voltageMillivolts: Int?
    /// Agreed maximum current (mA).
    public var currentMilliamps: Int?
    public var manufacturer: String?
    public var isWireless: Bool
    /// What a USB Power Delivery charger offers, lowest voltage first.
    public var profiles: [PowerProfile]
    /// The offered profile in use, if known.
    public var activeProfile: PowerProfile?

    public init(watts: Int? = nil, name: String? = nil, voltageMillivolts: Int? = nil,
                currentMilliamps: Int? = nil, manufacturer: String? = nil, isWireless: Bool = false,
                profiles: [PowerProfile] = [], activeProfile: PowerProfile? = nil) {
        self.watts = watts
        self.name = name
        self.voltageMillivolts = voltageMillivolts
        self.currentMilliamps = currentMilliamps
        self.manufacturer = manufacturer
        self.isWireless = isWireless
        self.profiles = profiles
        self.activeProfile = activeProfile
    }

    /// The most power any offered profile can supply (W).
    public var maximumOfferedWatts: Double? {
        profiles.map(\.watts).max()
    }
}

/// One voltage and current limit a USB Power Delivery charger offers.
public struct PowerProfile: Sendable, Equatable {
    public var voltageMillivolts: Int
    public var maxCurrentMilliamps: Int

    public init(voltageMillivolts: Int, maxCurrentMilliamps: Int) {
        self.voltageMillivolts = voltageMillivolts
        self.maxCurrentMilliamps = maxCurrentMilliamps
    }

    public var watts: Double {
        Double(voltageMillivolts) * Double(maxCurrentMilliamps) / 1_000_000
    }
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
    /// `ChargerData.NotChargingReason` bit field (0 while charging normally).
    public var notChargingReason: Int?
    public var timeToEmptyMinutes: Int?
    public var timeToFullMinutes: Int?

    public var adapter: PowerAdapter?
    /// Power arriving from the charger, as the power controller measures it (mW).
    public var chargerInputMilliwatts: Int?
    public var serialNumber: String?
    public var gasGaugeName: String?
    /// Cell manufacturer, from the registry or decoded from the serial prefix.
    public var manufacturer: String?
    public var manufactureDate: DateComponents?
    /// Manufacture week without a year, when no full date is available.
    public var manufactureWeek: BatteryOrigin.ManufactureWeek?
    /// Estimated from operating hours (and the manufacture week, if recorded)
    /// when the battery stores no full date.
    public var estimatedManufactureDate: Date?
    /// Decoded from a 17-character battery serial, when the battery stores no full date.
    public var serialManufactureDate: Date?
    public var lifetime: BatteryLifetime?
    /// When the device was first set up, if the gauge recorded it.
    public var firstUseDate: Date?
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

    /// Where a manufacture date came from, best first.
    public enum ManufactureDateSource: Sendable, Equatable {
        /// Stored by the battery (Intel Macs).
        case recorded
        /// Decoded from the battery serial.
        case serialNumber
        /// Today minus operating hours.
        case operatingTime
    }

    /// The most reliable manufacture date available.
    public var bestManufactureDate: (date: Date, source: ManufactureDateSource)? {
        if let date = manufactureDate.flatMap({ Calendar.current.date(from: $0) }) { return (date, .recorded) }
        if let serialManufactureDate { return (serialManufactureDate, .serialNumber) }
        if let estimatedManufactureDate { return (estimatedManufactureDate, .operatingTime) }
        return nil
    }

    /// Cycles since the gauge last recalibrated its capacity estimate.
    public var cyclesSinceCalibration: Int? {
        guard let cycleCount, let last = lifetime?.cycleCountAtLastCalibration, last <= cycleCount else { return nil }
        return cycleCount - last
    }

    /// Set in `NotChargingReason` while iOS holds the charge because of its
    /// charging settings (Charge Limit / charging optimization). Verified on an
    /// iPhone: lifting the limit cleared it and charging resumed within seconds;
    /// restoring the setting set it again, at the same charge level.
    public static let pausedBySystemChargingSettings = 0x0100_0000

    /// Plugged in, below full, not charging, because the device's own charging
    /// settings paused it.
    public var isChargingPausedBySettings: Bool {
        isExternalPowerConnected && !isCharging && !isFullyCharged
            && (notChargingReason ?? 0) & Self.pausedBySystemChargingSettings != 0
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
    ///
    /// `pack` is the `BatteryData` of the child `AppleSmartBatteryPack` entry. On
    /// Apple Silicon it holds temperature, raw capacities, failure flags,
    /// manufacture date and lifetime data that the parent omits.
    public init(registry r: [String: Any], pack: [String: Any]? = nil, smc: SMCReading?,
                powerSource: PowerSourceInfo?, date: Date = Date()) {
        let batteryData = r["BatteryData"] as? [String: Any] ?? [:]
        let pack = pack ?? [:]
        let topLevelIsPercent = Self.int(r["MaxCapacity"]).map { $0 <= 100 } ?? false

        self.date = date
        designCapacity = Self.int(batteryData["DesignCapacity"]) ?? Self.int(r["DesignCapacity"])
            ?? Self.int(pack["DesignCapacity"])
            ?? smc?.double(SMCKey.designCapacity).map { Int($0) }
        fullChargeCapacity = Self.int(r["AppleRawMaxCapacity"]) ?? Self.int(batteryData["FullChargeCapacity"])
            ?? Self.int(pack["AppleRawMaxCapacity"])
            ?? (topLevelIsPercent ? nil : Self.int(r["MaxCapacity"]))
            ?? smc?.double(SMCKey.fullChargeCapacity).map { Int($0) }
        currentCapacity = Self.int(r["AppleRawCurrentCapacity"]) ?? Self.int(batteryData["RemainingCapacity"])
            ?? Self.int(pack["AppleRawCurrentCapacity"])
            ?? (topLevelIsPercent ? nil : Self.int(r["CurrentCapacity"]))
            ?? smc?.double(firstOf: SMCKey.remainingCapacity).map { Int($0) }
        nominalChargeCapacity = Self.int(r["NominalChargeCapacity"]) ?? Self.int(batteryData["NominalChargeCapacity"])

        cycleCount = Self.int(r["CycleCount"]) ?? smc?.double(SMCKey.cycleCount).map { Int($0) }
        designCycleCount = Self.int(r["DesignCycleCount9C"]) ?? Self.int(r["DesignCycleCount70"])

        if let centi = Self.int(r["Temperature"]) ?? Self.int(r["VirtualTemperature"])
            ?? Self.int(pack["Temperature"]) ?? Self.int(pack["VirtualTemperature"]) {
            temperatureCelsius = Double(centi) / 100
        } else {
            temperatureCelsius = smc?.double(SMCKey.batteryTemperature)
        }

        voltageMillivolts = Self.int(r["Voltage"]) ?? Self.int(r["AppleRawBatteryVoltage"])
        // Prefer the SMC's live current: on Apple Silicon the registry's
        // InstantAmperage can sit at a placeholder (-1000 mA) while discharging.
        amperageMilliamps = smc?.double(SMCKey.batteryCurrent).map { Int($0) }
            ?? Self.int(r["InstantAmperage"]) ?? Self.int(r["Amperage"])

        isCharging = Self.bool(r["IsCharging"]) ?? false
        isExternalPowerConnected = Self.bool(r["ExternalConnected"]) ?? false
        isFullyCharged = Self.bool(r["FullyCharged"]) ?? false
        notChargingReason = Self.int((r["ChargerData"] as? [String: Any])?["NotChargingReason"])
        timeToEmptyMinutes = Self.minutes(r["AvgTimeToEmpty"])
        timeToFullMinutes = Self.minutes(r["AvgTimeToFull"])

        if let details = r["AdapterDetails"] as? [String: Any], !details.isEmpty {
            adapter = Self.adapter(details)
        }
        if isExternalPowerConnected,
           let milliwatts = Self.int((r["PowerTelemetryData"] as? [String: Any])?["SystemPowerIn"]), milliwatts > 0 {
            chargerInputMilliwatts = milliwatts
        }

        serialNumber = (r["Serial"] as? String) ?? (r["BatterySerialNumber"] as? String)
            ?? smc?.read(SMCKey.batterySerial)?.stringValue
        gasGaugeName = r["DeviceName"] as? String
        manufacturer = r["Manufacturer"] as? String ?? serialNumber.flatMap(BatteryOrigin.manufacturer(serial:))
        let lifetimeData = (r["LifetimeData"] ?? batteryData["LifetimeData"] ?? pack["LifetimeData"]) as? [String: Any]
        lifetime = lifetimeData.map(BatteryLifetime.init(dictionary:))

        // `ManufactureDate` is a packed Smart Battery date on Intel, but on Apple
        // Silicon it holds ASCII digits ("330802": week, month, weekday) with no year.
        let rawDate = Self.int(r["ManufactureDate"]) ?? Self.int(pack["ManufactureDate"])
        manufactureDate = rawDate.flatMap(Self.decodePackedDate)
        if manufactureDate == nil {
            let week = rawDate.flatMap(Self.asciiDigits).flatMap(BatteryOrigin.manufactureWeek(bmdt:))
                ?? smc?.read(SMCKey.batteryManufactureWeek)?.stringValue.flatMap(BatteryOrigin.manufactureWeek(bmdt:))
            manufactureWeek = week
            if let hours = lifetime?.totalOperatingHours {
                estimatedManufactureDate = BatteryOrigin.estimatedManufactureDate(
                    operatingHours: hours, week: week, now: date)
            }
            if let serialNumber {
                serialManufactureDate = BatteryOrigin.serialManufactureDate(
                    serial: serialNumber, estimate: estimatedManufactureDate, cycleCount: cycleCount, now: date)
            }
        }
        // Seconds since 2001 (Apple's reference date); 0 when not recorded.
        firstUseDate = (Self.int(batteryData["DateOfFirstUse"]) ?? Self.int(pack["DateOfFirstUse"]))
            .flatMap { $0 > 0 ? Date(timeIntervalSinceReferenceDate: TimeInterval($0)) : nil }

        failures = BatteryFailure(rawValue: Self.int(r["PermanentFailureStatus"])
            ?? Self.int(batteryData["PermanentFailureStatus"]) ?? Self.int(pack["PermanentFailureStatus"]) ?? 0)
        // Without macOS's power-source API (e.g. for iPhones), the top-level
        // percentage is the figure the device itself shows.
        self.powerSource = powerSource ?? (topLevelIsPercent
            ? Self.int(r["CurrentCapacity"]).map { PowerSourceInfo(chargePercent: $0) } : nil)
    }

    /// Reads `AdapterDetails`. `UsbHvcMenu` lists the profiles a USB-PD charger
    /// offers and `UsbHvcHvcIndex` names the one in use.
    static func adapter(_ details: [String: Any]) -> PowerAdapter {
        let menu = (details["UsbHvcMenu"] as? [[String: Any]] ?? []).compactMap { item
            -> (index: Int?, profile: PowerProfile)? in
            guard let volts = int(item["MaxVoltage"]), let amps = int(item["MaxCurrent"]), volts > 0, amps > 0
            else { return nil }
            return (int(item["Index"]), PowerProfile(voltageMillivolts: volts, maxCurrentMilliamps: amps))
        }
        let activeIndex = int(details["UsbHvcHvcIndex"])
        let name = [details["Name"], details["Description"]].compactMap { $0 as? String }
            .first { !$0.isEmpty }
        return PowerAdapter(
            watts: int(details["Watts"]),
            name: name,
            voltageMillivolts: int(details["AdapterVoltage"]),
            currentMilliamps: int(details["Current"]),
            manufacturer: (details["Manufacturer"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            isWireless: bool(details["IsWireless"]) ?? false,
            profiles: menu.map(\.profile).sorted { $0.voltageMillivolts < $1.voltageMillivolts },
            activeProfile: activeIndex.flatMap { index in menu.first { $0.index == index }?.profile }
        )
    }

    /// Decodes the Smart Battery Data packed date: `(year − 1980) << 9 | month << 5 | day`.
    public static func decodePackedDate(_ value: Int) -> DateComponents? {
        guard (0...0xFFFF).contains(value) else { return nil }
        let day = value & 0x1F
        let month = (value >> 5) & 0x0F
        let year = (value >> 9) + 1980
        guard (1...31).contains(day), (1...12).contains(month), year < 2100 else { return nil }
        return DateComponents(year: year, month: month, day: day)
    }

    /// An integer whose big-endian bytes are ASCII digits, e.g. 0x323038303333 → "208033"
    /// read backwards as "330802" (the gauge stores the string little-endian).
    static func asciiDigits(_ value: Int) -> String? {
        var bytes: [UInt8] = []
        var v = UInt64(bitPattern: Int64(value))
        while v != 0 {
            bytes.append(UInt8(v & 0xFF))
            v >>= 8
        }
        guard !bytes.isEmpty, bytes.allSatisfy({ (0x30...0x39).contains($0) }) else { return nil }
        return String(decoding: bytes, as: UTF8.self)
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
